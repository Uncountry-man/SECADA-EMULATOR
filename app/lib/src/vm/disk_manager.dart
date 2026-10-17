import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../android/guest_setup.dart';
import '../core/app_log.dart';
import 'qemu_locator.dart';

class DiskError implements Exception {
  DiskError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Resultado de [DiskManager.ensureDataDisk].
class DataDisk {
  DataDisk(this.path, {required this.created, required this.grown});
  final String path;

  /// Disco recém-criado: o Android fará o primeiro boot (mais lento) e o
  /// SECADA Emulator aplica o provisionamento inicial.
  final bool created;

  /// O disco virtual foi ampliado; o sistema de arquivos precisa ser
  /// expandido dentro do Android (resize2fs online).
  final bool grown;
}

/// Gerencia o disco persistente `/data` do Android (QCOW2).
///
/// O disco é criado assim: arquivo raw esparso -> `mke2fs -t ext4` ->
/// propriedades iniciais gravadas com `debugfs` -> `qemu-img convert` para
/// QCOW2. Nada disso exige root.
///
/// A propriedade `persist.adb.tcp.port=5555` é semeada em
/// `/data/property/` (formato legado que o Android 9 importa no primeiro
/// boot), fazendo o adbd escutar em TCP para o encaminhamento local do QEMU.
/// Também é criado `/data/local.prop` com `qemu.hw.mainkeys=1` (sem barra de
/// navegação desde o primeiro boot; ver `GuestSetup.localProp`).
class DiskManager {
  static const fileName = 'data.qcow2';

  static Future<DataDisk> ensureDataDisk({
    required String vmDir,
    required int sizeGb,
    required QemuInstall qemu,
  }) async {
    final path = p.join(vmDir, fileName);
    if (await File(path).exists()) {
      final current = await virtualSizeBytes(path, qemu);
      final wanted = sizeGb * 1024 * 1024 * 1024;
      if (wanted > current) {
        log.info('Ampliando $path de ${current >> 30} GB para $sizeGb GB');
        await _run(qemu.qemuImg, ['resize', path, '${sizeGb}G'], qemu.env);
        return DataDisk(path, created: false, grown: true);
      }
      return DataDisk(path, created: false, grown: false);
    }
    await Directory(vmDir).create(recursive: true);
    final mke2fs = await _tool('mke2fs');
    final debugfs = await _tool('debugfs');
    final raw = p.join(vmDir, 'data.raw.tmp');
    final seed = p.join(vmDir, 'adb-port.tmp');
    final localProp = p.join(vmDir, 'local-prop.tmp');
    try {
      final f = await File(raw).open(mode: FileMode.write);
      await f.truncate(sizeGb * 1024 * 1024 * 1024); // esparso
      await f.close();
      await _run(mke2fs, [
        '-q', '-F', '-t', 'ext4', '-L', 'data',
        '-E', 'lazy_itable_init=1,lazy_journal_init=1', raw,
      ], const {});
      await File(seed).writeAsString('5555');
      await File(localProp).writeAsString('${GuestSetup.localProp}\n');
      // Arquivo de propriedade legado: precisa ser root:root 0600.
      final cmds = [
        'mkdir property',
        'sif property mode 040700',
        'sif property uid 0',
        'sif property gid 0',
        'write $seed property/persist.adb.tcp.port',
        'sif property/persist.adb.tcp.port mode 0100600',
        'sif property/persist.adb.tcp.port uid 0',
        'sif property/persist.adb.tcp.port gid 0',
        'write $localProp local.prop',
        'sif local.prop mode 0100644',
        'sif local.prop uid 0',
        'sif local.prop gid 0',
      ];
      final proc = await Process.start(debugfs, ['-w', '-f', '-', raw]);
      proc.stdin.writeln(cmds.join('\n'));
      await proc.stdin.close();
      final err = await proc.stderr.transform(utf8.decoder).join();
      await proc.stdout.drain<void>();
      if (await proc.exitCode != 0) {
        throw DiskError('debugfs falhou: $err');
      }
      await _run(qemu.qemuImg,
          ['convert', '-f', 'raw', '-O', 'qcow2', raw, path], qemu.env);
      log.info('Disco de dados criado: $path ($sizeGb GB)');
      return DataDisk(path, created: true, grown: false);
    } finally {
      for (final t in [raw, seed, localProp]) {
        final f = File(t);
        if (await f.exists()) await f.delete();
      }
    }
  }

  static Future<int> virtualSizeBytes(String path, QemuInstall qemu) async {
    final out = await _run(qemu.qemuImg,
        ['info', '--output=json', '-U', path], qemu.env);
    final j = jsonDecode(out) as Map;
    return (j['virtual-size'] as num).toInt();
  }

  static Future<String> _tool(String name) async {
    for (final d in ['/usr/sbin', '/sbin', '/usr/bin', '/bin']) {
      final f = File(p.join(d, name));
      if (await f.exists()) return f.path;
    }
    final w = await QemuLocator.which(name);
    if (w != null) return w;
    throw DiskError('Ferramenta "$name" não encontrada. Instale o pacote '
        'e2fsprogs.');
  }

  static Future<String> _run(
      String exe, List<String> args, Map<String, String> env) async {
    final r = await Process.run(exe, args, environment: env);
    if (r.exitCode != 0) {
      throw DiskError('${p.basename(exe)} ${args.join(' ')} falhou '
          '(${r.exitCode}): ${r.stderr}');
    }
    return r.stdout as String;
  }
}
