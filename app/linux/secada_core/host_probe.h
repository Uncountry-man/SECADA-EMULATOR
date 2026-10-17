// Diagnóstico do host: KVM, CPU e memória.
#pragma once

#include <cstdint>
#include <string>

namespace secada {

struct HostInfo {
  bool kvm_present = false;     // /dev/kvm existe
  bool kvm_accessible = false;  // abrir O_RDWR funcionou
  int kvm_api_version = -1;
  std::string kvm_error;
  std::string cpu_model;
  std::string cpu_vendor;
  bool cpu_virt_flag = false;  // vmx/svm em /proc/cpuinfo
  int logical_cpus = 0;
  int64_t mem_total_mb = 0;
  int64_t mem_available_mb = 0;
};

HostInfo ProbeHost();

}  // namespace secada
