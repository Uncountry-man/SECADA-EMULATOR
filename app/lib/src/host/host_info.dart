import '../core/native_bridge.dart';

/// Recursos do computador host, obtidos pelo backend nativo.
class HostInfo {
  const HostInfo({
    this.kvmPresent = false,
    this.kvmAccessible = false,
    this.kvmApiVersion = -1,
    this.kvmError = '',
    this.cpuModel = '',
    this.cpuVendor = '',
    this.cpuVirtFlag = false,
    this.logicalCpus = 0,
    this.memTotalMb = 0,
    this.memAvailableMb = 0,
  });

  final bool kvmPresent;
  final bool kvmAccessible;
  final int kvmApiVersion;
  final String kvmError;
  final String cpuModel;
  final String cpuVendor;
  final bool cpuVirtFlag;
  final int logicalCpus;
  final int memTotalMb;
  final int memAvailableMb;

  bool get kvmUsable => kvmAccessible && kvmApiVersion == 12;

  static Future<HostInfo> probe() async {
    final m = await NativeBridge.instance.probeHost();
    return HostInfo(
      kvmPresent: m['kvmPresent'] as bool? ?? false,
      kvmAccessible: m['kvmAccessible'] as bool? ?? false,
      kvmApiVersion: m['kvmApiVersion'] as int? ?? -1,
      kvmError: m['kvmError'] as String? ?? '',
      cpuModel: m['cpuModel'] as String? ?? '',
      cpuVendor: m['cpuVendor'] as String? ?? '',
      cpuVirtFlag: m['cpuVirtFlag'] as bool? ?? false,
      logicalCpus: m['logicalCpus'] as int? ?? 0,
      memTotalMb: m['memTotalMb'] as int? ?? 0,
      memAvailableMb: m['memAvailableMb'] as int? ?? 0,
    );
  }

  @override
  String toString() => 'CPU: $cpuModel ($logicalCpus threads, virt=$cpuVirtFlag) '
      'RAM: $memTotalMb MB (livre $memAvailableMb MB) '
      'KVM: presente=$kvmPresent acessível=$kvmAccessible api=$kvmApiVersion';
}
