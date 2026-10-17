import '../settings/vm_settings.dart';
import 'android_image.dart';
import 'qemu_locator.dart';

/// Tudo o que é necessário para montar a linha de comando do QEMU.
class QemuLaunchSpec {
  QemuLaunchSpec({
    required this.qemu,
    required this.image,
    required this.dataDisk,
    required this.settings,
    required this.vncSocket,
    required this.qmpSocket,
    required this.serialLog,
    required this.serialSocket,
    required this.pidFile,
    required this.adbPort,
    this.renderNode = '',
    this.dbusQmpSocket,
    this.pulseSocket,
    this.intelCpuIdentity = false,
  });

  final QemuInstall qemu;
  final AndroidImage image;
  final String dataDisk;
  final VmSettings settings;
  final String vncSocket;
  final String qmpSocket;
  final String serialLog;
  final String serialSocket;
  final String pidFile;
  final int adbPort;

  /// Nó DRM da GPU usada pelo VirGL (ver `Gpu.select`); vazio = o QEMU
  /// escolhe.
  final String renderNode;

  /// VirGL com display D-Bus (quadros entregues direto da GPU, até 60/s):
  /// socket do QMP dedicado pelo qual o SECADA Emulator entrega a conexão D-Bus. Null =
  /// VirGL pelo caminho egl-headless + VNC (limitado a ~26 quadros/s).
  final String? dbusQmpSocket;

  /// Socket do PulseAudio/PipeWire do host; null = sem áudio.
  final String? pulseSocket;

  /// Apresenta a CPU ao Android como "GenuineIntel" (ver [buildKernelCmdline]).
  final bool intelCpuIdentity;
}

/// Linha de comando do kernel do Android-x86.
///
/// * `DATA=vda`: o primeiro disco virtio (QCOW2 persistente) vira `/data`.
/// * `SRC=`: sistema (`system.sfs`) e ramdisk são lidos do CD-ROM (a ISO).
/// * `video=`/`DPI=`: resolução do framebuffer (sempre paisagem) e densidade.
/// * O Wi-Fi virtual do Android-x86 (virt_wifi sobre a placa virtio) fica
///   ativo: o Android enxerga uma rede Wi-Fi real ("VirtWifi").
/// * `SETUPWIZARD=0`: pula o assistente inicial.
/// * `console=ttyS0`: shell root no console serial, usado pelo SECADA Emulator para
///   detectar o boot e configurar o sistema antes de existir rede.
/// * `vdso32=0` com [intelCpuIdentity]: o tradutor ARM64 da Intel
///   (houdini64) só inicializa com fabricante "GenuineIntel"; num host AMD a
///   VM se apresenta assim. Com fabricante Intel o kernel faria as chamadas
///   de sistema de 32 bits por `SYSENTER`, que o AMD não tem em modo 64 bits
///   e o KVM emula a cada chamada (boot ~20x mais lento, medido). Sem o vDSO
///   de 32 bits, a bionic usa `int 0x80`, que roda direto.
String buildKernelCmdline(VmSettings s, {bool intelCpuIdentity = false}) {
  final w = s.width >= s.height ? s.width : s.height;
  final h = s.width >= s.height ? s.height : s.width;
  return [
    'root=/dev/ram0',
    'SRC=',
    'DATA=vda',
    'video=${w}x$h',
    'DPI=${s.dpi}',
    'SETUPWIZARD=0',
    if (s.graphics == GraphicsMode.virtio) 'HWACCEL=0',
    if (intelCpuIdentity) 'vdso32=0',
    'quiet',
    'console=ttyS0',
  ].join(' ');
}

/// Identificador da placa de vídeo na linha de comando. O dispositivo de
/// toque do mapeador é vinculado a ele para que o QEMU o escolha sem
/// depender da ordem de ativação dos dispositivos de entrada. O modo VGA
/// padrão (`-vga std`) não tem identificador.
String? displayDeviceIdFor(GraphicsMode mode) =>
    mode == GraphicsMode.standard ? null : 'vga0';

List<String> buildQemuArgv(QemuLaunchSpec spec) {
  final s = spec.settings;
  final args = <String>[
    spec.qemu.binary,
    '-name', 'secada,process=secada-vm',
    for (final d in spec.qemu.firmwareDirs) ...['-L', d],
    '-nodefaults',
    '-machine', 'pc,accel=kvm,vmport=off',
    '-cpu', spec.intelCpuIdentity ? 'host,vendor=GenuineIntel' : 'host',
    '-smp', '${s.cpus}',
    '-m', '${s.memoryMb}',
    '-rtc', 'base=utc',
    // Endurecimento: o QEMU não pode criar processos nem elevar privilégios.
    '-sandbox', 'on,obsolete=deny,elevateprivileges=deny,spawn=deny,'
        'resourcecontrol=deny',
    '-kernel', spec.image.kernelPath,
    '-initrd', spec.image.initrdPath,
    '-append', buildKernelCmdline(s, intelCpuIdentity: spec.intelCpuIdentity),
    '-drive', 'file=${_escape(spec.dataDisk)},if=virtio,format=qcow2,'
        'cache=writeback,discard=unmap',
    '-drive', 'file=${_escape(spec.image.isoPath)},media=cdrom,readonly=on,'
        'if=ide',
    ..._graphicsArgs(spec),
    // Display exportado apenas por socket UNIX privado (sem porta TCP).
    '-vnc', 'unix:${spec.vncSocket}',
    '-qmp', 'unix:${spec.qmpSocket},server=on,wait=off',
    '-monitor', 'none',
    '-chardev', 'socket,id=serial0,path=${spec.serialSocket},server=on,'
        'wait=off,logfile=${spec.serialLog}',
    '-serial', 'chardev:serial0',
    if (spec.pulseSocket != null) ...[
      '-audiodev', 'pa,id=snd0,server=unix:${spec.pulseSocket}',
      '-device', 'intel-hda',
      '-device', 'hda-duplex,audiodev=snd0',
    ],
    // Mouse absoluto (usb-tablet) para coordenadas exatas; o teclado PS/2
    // embutido na máquina "pc" recebe as teclas.
    '-device', 'qemu-xhci,id=xhci',
    '-device', 'usb-tablet,bus=xhci.0',
    // Rede NAT do usuário; o ADB é encaminhado só para 127.0.0.1.
    '-netdev', 'user,id=net0,hostfwd=tcp:127.0.0.1:${spec.adbPort}-:5555',
    '-device', 'virtio-net-pci,netdev=net0',
    '-device', 'virtio-rng-pci',
    '-pidfile', spec.pidFile,
  ];
  return args;
}

List<String> _graphicsArgs(QemuLaunchSpec spec) {
  switch (spec.settings.graphics) {
    case GraphicsMode.standard:
      return ['-vga', 'std', '-global', 'VGA.vgamem_mb=64', '-display', 'none'];
    case GraphicsMode.virtio:
      return ['-vga', 'none', '-device', 'virtio-vga,id=vga0', '-display', 'none'];
    case GraphicsMode.virgl:
      final node = spec.renderNode.isEmpty
          ? ''
          : ',rendernode=${_escape(spec.renderNode)}';
      final dbusQmp = spec.dbusQmpSocket;
      if (dbusQmp != null) {
        return [
          '-vga', 'none',
          '-device', 'virtio-vga-gl,id=vga0',
          '-display', 'dbus,p2p=yes,gl=on$node',
          '-qmp', 'unix:$dbusQmp,server=on,wait=off',
        ];
      }
      return [
        '-vga', 'none',
        '-device', 'virtio-vga-gl,id=vga0',
        '-display', 'egl-headless$node',
      ];
  }
}

/// Vírgulas em valores de opções do QEMU precisam ser duplicadas.
String _escape(String v) => v.replaceAll(',', ',,');
