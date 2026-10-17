import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_log.dart';
import '../core/paths.dart';

class ArmTranslationError implements Exception {
  ArmTranslationError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Tradução ARM do Android-x86 9 ("native bridge" com o libhoudini da Intel).
///
/// A imagem já traz o mecanismo: `ro.dalvik.vm.native.bridge=libnb.so`, o
/// `abilist` com `armeabi-v7a`, e o serviço `nativebridge`
/// (`/system/bin/enable_nativebridge`), que o init inicia quando
/// `persist.sys.nativebridge=1`. O serviço espera o arquivo `houdini9_y.sfs`
/// em `/data/arm/` (e o move para `/data/media/0/arm/`), monta-o em
/// `/system/lib/arm`, liga o `libhoudini.so` real e registra os executáveis
/// ARM no `binfmt_misc`. Falta só o arquivo: o Android-x86 não o embarca (é
/// software proprietário da Intel) e os encurtadores de URL do script não
/// funcionam mais. O SECADA Emulator o baixa do espelho oficial do Android-x86, confere
/// o SHA-256 e o entrega ao Android.
///
/// ARM64 fica com [Arm64Translation].
abstract final class ArmTranslation {
  static const variant = '9_y';
  static const fileName = 'houdini9_y.sfs';
  static const sizeBytes = 42778624;
  static const sha256 = 'b73d60265096acbeba374d45732f52ef9601577ae2093c950b5e0a61b575d375';

  /// O espelho só responde por HTTP; a integridade vem do SHA-256 fixo.
  static const urls = [
    'http://dl.android-x86.org/houdini/9_y/houdini.sfs',
    'http://dl.android-x86.org/houdini.php?v=9_y',
  ];

  /// Onde o SECADA Emulator guarda a cópia baixada (reaproveitada por todas as VMs).
  static String get localPath =>
      p.join(SecadaPaths.instance.dataDir, 'runtime', 'houdini', fileName);

  static Future<bool> isDownloaded([String? path]) async {
    final f = File(path ?? localPath);
    return await f.exists() && await f.length() == sizeBytes;
  }

  /// SHA-256 pelo `sha256sum` do sistema (coreutils); null se indisponível.
  static Future<String?> _sha256Of(String path) async {
    try {
      final r = await Process.run('sha256sum', [path]).timeout(const Duration(minutes: 2));
      if (r.exitCode != 0) return null;
      return (r.stdout as String).split(RegExp(r'\s+')).first.toLowerCase();
    } catch (_) {
      return null;
    }
  }

  /// Baixa o tradutor se ainda não estiver no computador. [onProgress]
  /// recebe a fração (0..1). Lança [ArmTranslationError] se nenhum endereço
  /// funcionar ou se o arquivo não conferir.
  static Future<String> ensureDownloaded({
    void Function(double fraction)? onProgress,
    List<String> sources = urls,
    String? dest,
    String expectedSha256 = sha256,
    int expectedSize = sizeBytes,
  }) async {
    final target = dest ?? localPath;
    final f = File(target);
    if (await f.exists() && await f.length() == expectedSize) return target;
    await f.parent.create(recursive: true);
    final part = File('$target.part');
    final errors = <String>[];
    for (final url in sources) {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
      try {
        log.info('Baixando o tradutor ARM: $url');
        final req = await client.getUrl(Uri.parse(url));
        final res = await req.close().timeout(const Duration(seconds: 60));
        if (res.statusCode != 200) {
          errors.add('$url: HTTP ${res.statusCode}');
          await res.drain<void>();
          continue;
        }
        final sink = part.openWrite();
        var got = 0;
        try {
          await for (final chunk in res.timeout(const Duration(seconds: 60))) {
            sink.add(chunk);
            got += chunk.length;
            onProgress?.call(expectedSize == 0 ? 0 : (got / expectedSize).clamp(0.0, 1.0));
          }
        } finally {
          await sink.close();
        }
        if (got != expectedSize) {
          errors.add('$url: tamanho $got, esperado $expectedSize');
          continue;
        }
        final sum = await _sha256Of(part.path);
        if (sum != null && sum != expectedSha256) {
          errors.add('$url: SHA-256 não confere');
          continue;
        }
        await part.rename(target);
        log.info('Tradutor ARM baixado e conferido (${sum ?? 'sem sha256sum, só tamanho'})');
        return target;
      } catch (e) {
        errors.add('$url: $e');
      } finally {
        client.close(force: true);
        if (await part.exists()) await part.delete().catchError((_) => part);
      }
    }
    throw ArmTranslationError(
        'não foi possível baixar o tradutor ARM (${errors.join('; ')})');
  }
}

/// Tradução ARM 64 bits (houdini64).
///
/// O Android-x86 9 já prevê o tradutor de 64 bits (`enable_nativebridge 64`
/// monta `houdini9_z.sfs` em `/system/lib64/arm64`), mas o projeto nunca o
/// publicou, então o SECADA Emulator não o baixa: ele precisa ser colocado em
/// [localPath] (squashfs com `libhoudini.so`, `houdini64` e as bibliotecas
/// ARM64 na raiz, o mesmo formato do `houdini9_y.sfs`).
///
/// Com o arquivo no computador, o SECADA Emulator:
/// * anexa ao initrd o script que põe `arm64-v8a` nas ABIs e cria o serviço
///   `nativebridge64` (ver `InitrdOverlay`);
/// * envia o arquivo ao Android, onde o serviço o monta a cada boot.
///
/// Sem ele, apps que têm versão ARM 32 bits continuam rodando por ela; é o
/// caso de jogos que travam na tradução de 32 bits e funcionam no celular,
/// que usa a versão ARM64.
abstract final class Arm64Translation {
  static const fileName = 'houdini9_z.sfs';

  static String get localPath =>
      p.join(SecadaPaths.instance.dataDir, 'runtime', 'houdini', fileName);

  /// Arquivo presente e com cabeçalho squashfs ("hsqs").
  static Future<bool> isAvailable([String? path]) async {
    final f = File(path ?? localPath);
    if (!await f.exists() || await f.length() < 1024 * 1024) return false;
    final raf = await f.open();
    try {
      return String.fromCharCodes(await raf.read(4)) == 'hsqs';
    } finally {
      await raf.close();
    }
  }

  static Future<int> size([String? path]) => File(path ?? localPath).length();
}
