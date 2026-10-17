import 'dart:io';

import 'package:path/path.dart' as p;

/// Diretórios do SECADA Emulator seguindo a especificação XDG.
///
/// * configuração: `$XDG_CONFIG_HOME/secada` (`~/.config/secada`)
/// * dados (imagens, discos, logs): `$XDG_DATA_HOME/secada`
/// * temporários grandes: `$XDG_CACHE_HOME/secada`
/// * sockets de runtime: `$XDG_RUNTIME_DIR/secada` (permissão 0700)
class SecadaPaths {
  SecadaPaths._(this.configDir, this.dataDir, this.runtimeDir, this.cacheDir);

  static SecadaPaths? _instance;
  static SecadaPaths get instance => _instance ??= _resolve();

  final String configDir;
  final String dataDir;
  final String runtimeDir;

  /// Arquivos temporários grandes (ex.: partes de um XAPK em instalação).
  final String cacheDir;

  String get settingsFile => p.join(configDir, 'settings.json');
  String get imagesDir => p.join(dataDir, 'images');
  String get logsDir => p.join(dataDir, 'logs');
  String get runtimeQemuDir => p.join(dataDir, 'runtime', 'qemu');

  /// Diretório da instância de VM (disco de dados, kernel extraído, etc.).
  String vmDir(String name) => p.join(dataDir, 'vms', name);
  String vmSocketDir(String name) => p.join(runtimeDir, name);

  /// Diretório do pacote (onde está o executável) — usado para localizar o
  /// QEMU embarcado na versão distribuível.
  static String get bundleDir => p.dirname(Platform.resolvedExecutable);

  static SecadaPaths _resolve() {
    final env = Platform.environment;
    final home = env['HOME'] ?? '/tmp';
    final config = env['XDG_CONFIG_HOME']?.isNotEmpty == true
        ? env['XDG_CONFIG_HOME']!
        : p.join(home, '.config');
    final data = env['XDG_DATA_HOME']?.isNotEmpty == true
        ? env['XDG_DATA_HOME']!
        : p.join(home, '.local', 'share');
    var runtime = env['XDG_RUNTIME_DIR'];
    if (runtime == null || runtime.isEmpty || !Directory(runtime).existsSync()) {
      runtime = p.join(Directory.systemTemp.path, 'secada-${env['USER'] ?? 'user'}');
    }
    final cache = env['XDG_CACHE_HOME']?.isNotEmpty == true
        ? env['XDG_CACHE_HOME']!
        : p.join(home, '.cache');
    return SecadaPaths._(
      p.join(config, 'secada'),
      p.join(data, 'secada'),
      p.join(runtime, 'secada'),
      p.join(cache, 'secada'),
    );
  }

  /// Cria um diretório privado (0700). Sockets de VNC/QMP ficam aqui, de modo
  /// que somente o usuário atual consegue conectar.
  static Future<Directory> ensurePrivateDir(String path) async {
    final dir = Directory(path);
    await dir.create(recursive: true);
    await Process.run('chmod', ['700', path]);
    return dir;
  }
}
