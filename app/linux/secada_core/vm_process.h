// Gerenciamento do processo QEMU.
//
// O processo é criado com fork/execve para que possamos configurar
// PR_SET_PDEATHSIG no filho: se o SECADA Emulator morrer inesperadamente (crash, SIGKILL),
// o kernel envia SIGTERM ao QEMU, que encerra de forma ordenada e grava os
// discos QCOW2. Assim nunca ficam processos órfãos.
#pragma once

#include <glib.h>
#include <sys/types.h>

#include <functional>
#include <string>
#include <utility>
#include <vector>

namespace secada {

class VmProcess {
 public:
  // exit_code é válido quando signaled == false; caso contrário, signal_number.
  using ExitCallback =
      std::function<void(int exit_code, bool signaled, int signal_number)>;

  VmProcess() = default;
  ~VmProcess();
  VmProcess(const VmProcess&) = delete;
  VmProcess& operator=(const VmProcess&) = delete;

  // argv[0] deve ser um caminho absoluto para o executável.
  bool Start(const std::vector<std::string>& argv,
             const std::vector<std::pair<std::string, std::string>>& extra_env,
             const std::string& log_path, std::string* error);

  bool IsRunning() const { return pid_ > 0; }
  pid_t pid() const { return pid_; }

  bool Signal(int sig);

  // SIGTERM, espera até |timeout_ms| e então SIGKILL. Bloqueante; usado no
  // encerramento do aplicativo quando não há mais loop de eventos.
  void TerminateBlocking(int timeout_ms);

  void set_exit_callback(ExitCallback cb) { exit_cb_ = std::move(cb); }

 private:
  static void OnChildExit(GPid pid, gint status, gpointer user_data);

  pid_t pid_ = -1;
  guint watch_id_ = 0;
  ExitCallback exit_cb_;
};

}  // namespace secada
