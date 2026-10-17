import 'package:secada/src/settings/vm_settings.dart';
import 'package:secada/src/vm/android_image.dart';
import 'package:secada/src/vm/qemu_command.dart';
import 'package:secada/src/vm/qemu_locator.dart';
import 'package:flutter_test/flutter_test.dart';

QemuLaunchSpec _spec(VmSettings s) => QemuLaunchSpec(
      qemu: QemuInstall(
        binary: '/opt/qemu/bin/qemu-system-x86_64',
        qemuImg: '/opt/qemu/bin/qemu-img',
        firmwareDirs: ['/opt/qemu/share/qemu'],
        env: const {},
        source: 'teste',
      ),
      image: AndroidImage(
        isoPath: '/imgs/android,x86.iso',
        kernelPath: '/vm/boot/kernel',
        initrdPath: '/vm/boot/initrd.img',
        volumeId: 'Android-x86',
      ),
      dataDisk: '/vm/data.qcow2',
      settings: s,
      vncSocket: '/run/user/1000/secada/default/vnc.sock',
      qmpSocket: '/run/user/1000/secada/default/qmp.sock',
      serialLog: '/logs/serial.log',
      serialSocket: '/run/user/1000/secada/default/serial.sock',
      pidFile: '/run/user/1000/secada/default/qemu.pid',
      adbPort: 6555,
    );

String _arg(List<String> argv, String flag) => argv[argv.indexOf(flag) + 1];

void main() {
  test('configuração padrão do MVP: 4 vCPUs, 4096 MB, 1280x720', () {
    final argv = buildQemuArgv(_spec(const VmSettings()));
    expect(argv.first, '/opt/qemu/bin/qemu-system-x86_64');
    expect(_arg(argv, '-smp'), '4');
    expect(_arg(argv, '-m'), '4096');
    expect(_arg(argv, '-machine'), 'pc,accel=kvm,vmport=off');
    expect(_arg(argv, '-cpu'), 'host');
    expect(_arg(argv, '-append'), contains('video=1280x720'));
    expect(_arg(argv, '-append'), contains('DATA=vda'));
    // Wi-Fi virtual ativo (o Android enxerga "VirtWifi").
    expect(_arg(argv, '-append'), isNot(contains('VIRT_WIFI=0')));
    expect(_arg(argv, '-append'), contains('console=ttyS0'));
    expect(_arg(argv, '-L'), '/opt/qemu/share/qemu');
  });

  test('display e controle somente por sockets UNIX; ADB só em 127.0.0.1', () {
    final argv = buildQemuArgv(_spec(const VmSettings()));
    expect(_arg(argv, '-vnc'), 'unix:/run/user/1000/secada/default/vnc.sock');
    expect(_arg(argv, '-qmp'), startsWith('unix:'));
    expect(_arg(argv, '-netdev'), contains('hostfwd=tcp:127.0.0.1:6555-:5555'));
    expect(argv.join(' '), isNot(contains('0.0.0.0')));
  });

  test('vírgulas em caminhos são escapadas para o QEMU', () {
    final argv = buildQemuArgv(_spec(const VmSettings()));
    final cdrom = argv.firstWhere((a) => a.contains('media=cdrom'));
    expect(cdrom, contains('file=/imgs/android,,x86.iso,'));
  });

  test('framebuffer sempre em paisagem', () {
    final cmd = buildKernelCmdline(const VmSettings(width: 720, height: 1280));
    expect(cmd, contains('video=1280x720'));
  });

  test('console serial em socket UNIX com log', () {
    final argv = buildQemuArgv(_spec(const VmSettings()));
    final chardev = argv.firstWhere((a) => a.startsWith('socket,id=serial0'));
    expect(chardev, contains('path=/run/user/1000/secada/default/serial.sock'));
    expect(chardev, contains('logfile=/logs/serial.log'));
  });

  test('modos gráficos', () {
    final std = buildQemuArgv(_spec(const VmSettings(graphics: GraphicsMode.standard)));
    expect(_arg(std, '-vga'), 'std');
    final virtio = buildQemuArgv(_spec(const VmSettings(graphics: GraphicsMode.virtio)));
    expect(virtio, contains('virtio-vga,id=vga0'));
    expect(_arg(virtio, '-append'), contains('HWACCEL=0'));
    final virgl = buildQemuArgv(_spec(const VmSettings(graphics: GraphicsMode.virgl)));
    expect(virgl, contains('virtio-vga-gl,id=vga0'));
    expect(_arg(virgl, '-display'), 'egl-headless');
  });

  test('VirGL usa o nó de renderização escolhido', () {
    final spec = _spec(const VmSettings(graphics: GraphicsMode.virgl));
    final argv = buildQemuArgv(QemuLaunchSpec(
      qemu: spec.qemu,
      image: spec.image,
      dataDisk: spec.dataDisk,
      settings: spec.settings,
      vncSocket: spec.vncSocket,
      qmpSocket: spec.qmpSocket,
      serialLog: spec.serialLog,
      serialSocket: spec.serialSocket,
      pidFile: spec.pidFile,
      adbPort: spec.adbPort,
      renderNode: '/dev/dri/renderD129',
    ));
    expect(_arg(argv, '-display'), 'egl-headless,rendernode=/dev/dri/renderD129');
  });

  test('VirGL com display D-Bus usa QMP dedicado e o nó escolhido', () {
    final spec = _spec(const VmSettings(graphics: GraphicsMode.virgl));
    final argv = buildQemuArgv(QemuLaunchSpec(
      qemu: spec.qemu,
      image: spec.image,
      dataDisk: spec.dataDisk,
      settings: spec.settings,
      vncSocket: spec.vncSocket,
      qmpSocket: spec.qmpSocket,
      serialLog: spec.serialLog,
      serialSocket: spec.serialSocket,
      pidFile: spec.pidFile,
      adbPort: spec.adbPort,
      renderNode: '/dev/dri/renderD128',
      dbusQmpSocket: '/run/user/1000/secada/default/dqmp.sock',
    ));
    expect(_arg(argv, '-display'), 'dbus,p2p=yes,gl=on,rendernode=/dev/dri/renderD128');
    expect(argv, contains('unix:/run/user/1000/secada/default/dqmp.sock,server=on,wait=off'));
    // O VNC continua disponível como reserva.
    expect(_arg(argv, '-vnc'), startsWith('unix:'));
  });

  test('identidade Intel para o tradutor ARM64 em host AMD', () {
    final spec = _spec(const VmSettings());
    expect(_arg(buildQemuArgv(spec), '-cpu'), 'host');
    expect(_arg(buildQemuArgv(spec), '-append'), isNot(contains('vdso32=0')));
    final intel = buildQemuArgv(QemuLaunchSpec(
      qemu: spec.qemu,
      image: spec.image,
      dataDisk: spec.dataDisk,
      settings: spec.settings,
      vncSocket: spec.vncSocket,
      qmpSocket: spec.qmpSocket,
      serialLog: spec.serialLog,
      serialSocket: spec.serialSocket,
      pidFile: spec.pidFile,
      adbPort: spec.adbPort,
      intelCpuIdentity: true,
    ));
    expect(_arg(intel, '-cpu'), 'host,vendor=GenuineIntel');
    // Sem o vDSO de 32 bits as chamadas de 32 bits usam int 0x80 (SYSENTER
    // seria emulado pelo KVM num AMD).
    expect(_arg(intel, '-append'), contains('vdso32=0'));
  });

  test('DPI vai para a linha de comando do kernel', () {
    expect(buildKernelCmdline(const VmSettings(dpi: 320)), contains('DPI=320'));
  });
}
