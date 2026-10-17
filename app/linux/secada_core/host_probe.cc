#include "host_probe.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <cstdio>
#include <fstream>
#include <sstream>

namespace secada {

HostInfo ProbeHost() {
  HostInfo info;

  info.kvm_present = access("/dev/kvm", F_OK) == 0;
  if (info.kvm_present) {
    int fd = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (fd >= 0) {
      info.kvm_accessible = true;
      info.kvm_api_version = ioctl(fd, KVM_GET_API_VERSION, 0);
      if (info.kvm_api_version != KVM_API_VERSION) {
        info.kvm_error = "Versão da API KVM inesperada: " +
                         std::to_string(info.kvm_api_version);
      }
      close(fd);
    } else if (errno == EACCES || errno == EPERM) {
      info.kvm_error =
          "Sem permissão para /dev/kvm. Adicione o usuário ao grupo 'kvm' "
          "(sudo usermod -aG kvm $USER) e reinicie a sessão.";
    } else {
      info.kvm_error = std::string("Falha ao abrir /dev/kvm: ") + strerror(errno);
    }
  } else {
    info.kvm_error =
        "/dev/kvm não existe. Ative a virtualização (AMD-V/VT-x) na BIOS/UEFI "
        "e verifique se os módulos kvm_amd/kvm_intel estão carregados.";
  }

  std::ifstream cpuinfo("/proc/cpuinfo");
  std::string line;
  while (std::getline(cpuinfo, line)) {
    auto colon = line.find(':');
    if (colon == std::string::npos) continue;
    std::string key = line.substr(0, line.find_last_not_of(" \t", colon - 1) + 1);
    std::string value =
        colon + 2 <= line.size() ? line.substr(colon + 2) : std::string();
    if (key == "model name" && info.cpu_model.empty()) info.cpu_model = value;
    if (key == "vendor_id" && info.cpu_vendor.empty()) info.cpu_vendor = value;
    if (key == "flags" && !info.cpu_virt_flag) {
      std::istringstream flags(value);
      std::string f;
      while (flags >> f) {
        if (f == "vmx" || f == "svm") info.cpu_virt_flag = true;
      }
    }
  }
  info.logical_cpus = int(sysconf(_SC_NPROCESSORS_ONLN));

  std::ifstream meminfo("/proc/meminfo");
  while (std::getline(meminfo, line)) {
    long long kb = 0;
    if (sscanf(line.c_str(), "MemTotal: %lld kB", &kb) == 1) {
      info.mem_total_mb = kb / 1024;
    } else if (sscanf(line.c_str(), "MemAvailable: %lld kB", &kb) == 1) {
      info.mem_available_mb = kb / 1024;
    }
  }
  return info;
}

}  // namespace secada
