#include "vm_process.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <map>

extern char** environ;

namespace secada {

VmProcess::~VmProcess() {
  if (IsRunning()) TerminateBlocking(15000);
}

bool VmProcess::Start(
    const std::vector<std::string>& argv,
    const std::vector<std::pair<std::string, std::string>>& extra_env,
    const std::string& log_path, std::string* error) {
  if (IsRunning()) {
    *error = "A máquina virtual já está em execução.";
    return false;
  }
  if (argv.empty() || argv[0].empty() || argv[0][0] != '/') {
    *error = "Caminho do QEMU inválido.";
    return false;
  }
  if (access(argv[0].c_str(), X_OK) != 0) {
    *error = "QEMU não encontrado ou sem permissão de execução: " + argv[0];
    return false;
  }

  // Tudo que o filho precisa é preparado antes do fork: entre fork e exec só
  // chamadas async-signal-safe são permitidas (o processo é multithread).
  std::map<std::string, std::string> env;
  for (char** e = environ; e && *e; ++e) {
    const char* eq = strchr(*e, '=');
    if (!eq) continue;
    env[std::string(*e, eq - *e)] = eq + 1;
  }
  for (const auto& kv : extra_env) env[kv.first] = kv.second;
  std::vector<std::string> env_strings;
  env_strings.reserve(env.size());
  for (const auto& kv : env) env_strings.push_back(kv.first + "=" + kv.second);
  std::vector<char*> envp;
  for (auto& s : env_strings) envp.push_back(s.data());
  envp.push_back(nullptr);

  std::vector<std::string> argv_copy = argv;
  std::vector<char*> c_argv;
  for (auto& s : argv_copy) c_argv.push_back(s.data());
  c_argv.push_back(nullptr);

  int log_fd = open(log_path.c_str(), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                    0600);
  if (log_fd < 0) {
    *error = "Não foi possível abrir o log da VM: " + log_path + " (" +
             strerror(errno) + ")";
    return false;
  }
  int null_fd = open("/dev/null", O_RDONLY | O_CLOEXEC);

  const pid_t parent = getpid();
  pid_t pid = fork();
  if (pid < 0) {
    *error = std::string("fork() falhou: ") + strerror(errno);
    close(log_fd);
    if (null_fd >= 0) close(null_fd);
    return false;
  }
  if (pid == 0) {
    // Filho.
    prctl(PR_SET_PDEATHSIG, SIGTERM);
    if (getppid() != parent) _exit(1);  // O pai morreu antes do prctl.
    setpgid(0, 0);  // Ctrl+C no terminal não atinge o QEMU diretamente.
    // Restaura sinais padrão (GLib/Flutter podem ter alterado máscaras).
    sigset_t set;
    sigemptyset(&set);
    sigprocmask(SIG_SETMASK, &set, nullptr);
    signal(SIGPIPE, SIG_DFL);
    if (null_fd >= 0) dup2(null_fd, STDIN_FILENO);
    dup2(log_fd, STDOUT_FILENO);
    dup2(log_fd, STDERR_FILENO);
    // Não herdar sockets/descritores do processo Flutter.
    syscall(SYS_close_range, 3U, ~0U, 0U);
    execve(c_argv[0], c_argv.data(), envp.data());
    const char msg[] = "secada: execve do QEMU falhou\n";
    ssize_t ignored = write(STDERR_FILENO, msg, sizeof(msg) - 1);
    (void)ignored;
    _exit(127);
  }

  close(log_fd);
  if (null_fd >= 0) close(null_fd);
  pid_ = pid;
  watch_id_ = g_child_watch_add(pid, &VmProcess::OnChildExit, this);
  return true;
}

void VmProcess::OnChildExit(GPid pid, gint status, gpointer user_data) {
  auto* self = static_cast<VmProcess*>(user_data);
  g_spawn_close_pid(pid);
  if (self->pid_ != pid) return;
  self->pid_ = -1;
  self->watch_id_ = 0;
  if (self->exit_cb_) {
    if (WIFSIGNALED(status)) {
      self->exit_cb_(-1, true, WTERMSIG(status));
    } else {
      self->exit_cb_(WEXITSTATUS(status), false, 0);
    }
  }
}

bool VmProcess::Signal(int sig) {
  if (!IsRunning()) return false;
  return kill(pid_, sig) == 0;
}

void VmProcess::TerminateBlocking(int timeout_ms) {
  if (!IsRunning()) return;
  if (watch_id_) {
    g_source_remove(watch_id_);
    watch_id_ = 0;
  }
  kill(pid_, SIGTERM);
  const int step_ms = 50;
  for (int waited = 0; waited < timeout_ms; waited += step_ms) {
    int status = 0;
    pid_t r = waitpid(pid_, &status, WNOHANG);
    if (r == pid_ || (r < 0 && errno == ECHILD)) {
      pid_ = -1;
      return;
    }
    struct timespec ts = {0, step_ms * 1000000L};
    nanosleep(&ts, nullptr);
  }
  kill(pid_, SIGKILL);
  int status = 0;
  waitpid(pid_, &status, 0);
  pid_ = -1;
}

}  // namespace secada
