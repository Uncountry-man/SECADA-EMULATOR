import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/paths.dart';

/// Uma instalação utilizável do QEMU.
class QemuInstall {
  QemuInstall({
    required this.binary,
    required this.qemuImg,
    required this.firmwareDirs,
    required this.env,
    required this.source,
  });

  final String binary;
  final String qemuImg;

  /// Diretórios passados com `-L` (vazio = padrão do QEMU do sistema).
  final List<String> firmwareDirs;

  /// Variáveis extras (LD_LIBRARY_PATH/QEMU_MODULE_DIR para o runtime
  /// embarcado).
  final Map<String, String> env;
  final String source;

  @override
  String toString() => '$binary ($source)';
}

/// Procura o QEMU na seguinte ordem:
/// 1. caminho configurado pelo usuário;
/// 2. runtime embarcado no pacote (`<app>/runtime/qemu`);
/// 3. runtime do usuário (`~/.local/share/secada/runtime/qemu`), criado por
///    `scripts/fetch-qemu-runtime.sh`;
/// 4. QEMU do sistema (`qemu-system-x86_64` no PATH, pacote qemu-system-x86).
class QemuLocator {
  static Future<QemuInstall?> locate({String configuredPath = ''}) async {
    if (configuredPath.isNotEmpty) {
      final f = File(configuredPath);
      if (await f.exists()) {
        final runtimeRoot = p.dirname(p.dirname(configuredPath));
        final bundled = await _fromRuntime(runtimeRoot, 'configurado');
        if (bundled != null && bundled.binary == configuredPath) return bundled;
        return QemuInstall(
          binary: configuredPath,
          qemuImg: await _which('qemu-img') ??
              p.join(p.dirname(configuredPath), 'qemu-img'),
          firmwareDirs: const [],
          env: const {},
          source: 'configurado',
        );
      }
    }
    for (final root in [
      p.join(SecadaPaths.bundleDir, 'runtime', 'qemu'),
      SecadaPaths.instance.runtimeQemuDir,
    ]) {
      final r = await _fromRuntime(root, 'runtime embarcado');
      if (r != null) return r;
    }
    final sys = await _which('qemu-system-x86_64');
    if (sys != null) {
      return QemuInstall(
        binary: sys,
        qemuImg: await _which('qemu-img') ?? '/usr/bin/qemu-img',
        firmwareDirs: const [],
        env: const {},
        source: 'sistema',
      );
    }
    return null;
  }

  static Future<QemuInstall?> _fromRuntime(String root, String source) async {
    final bin = p.join(root, 'bin', 'qemu-system-x86_64');
    if (!await File(bin).exists()) return null;
    final lib = p.join(root, 'lib');
    final existingLd = Platform.environment['LD_LIBRARY_PATH'];
    return QemuInstall(
      binary: bin,
      qemuImg: p.join(root, 'bin', 'qemu-img'),
      firmwareDirs: [p.join(root, 'share', 'qemu')],
      env: {
        'LD_LIBRARY_PATH':
            existingLd == null || existingLd.isEmpty ? lib : '$lib:$existingLd',
        'QEMU_MODULE_DIR': p.join(lib, 'qemu'),
      },
      source: source,
    );
  }

  static Future<String?> _which(String name) async {
    final path = Platform.environment['PATH'] ?? '/usr/bin:/bin';
    for (final dir in path.split(':')) {
      if (dir.isEmpty) continue;
      final f = File(p.join(dir, name));
      if (await f.exists()) return f.absolute.path;
    }
    for (final dir in ['/usr/bin', '/usr/local/bin', '/usr/sbin', '/sbin']) {
      final f = File(p.join(dir, name));
      if (await f.exists()) return f.path;
    }
    return null;
  }

  static Future<String?> which(String name) => _which(name);
}
