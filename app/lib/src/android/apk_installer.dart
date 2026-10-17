import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/app_log.dart';
import 'adb.dart';
import 'apk_inspector.dart';
import 'xapk_installer.dart';

/// API do Android-x86 9.0.
const int guestSdk = 28;

enum InstallPhase { inspecting, transferring, installing, done, failed }

class InstallProgress {
  InstallProgress(this.phase, {this.fraction, this.message, this.info});
  final InstallPhase phase;

  /// 0..1 durante a transferência.
  final double? fraction;
  final String? message;
  final ApkInfo? info;
}

/// Instala APKs no Android via ADB, com progresso real.
///
/// O APK é transmitido pelo stdin de `pm install -S <tamanho>` através do
/// protocolo shell v2 do adbd (binário-seguro, com stdout/stderr e código de
/// saída). Como somos nós que escrevemos os bytes, o progresso exibido
/// corresponde exatamente ao que já foi enviado.
class ApkInstaller {
  ApkInstaller(this.adb, {this.armTranslation = false, this.arm64 = false});
  final Adb adb;

  /// Tradução ARM ligada: aceita apps só ARM 32 bits (ver [AbiPolicy]).
  final bool armTranslation;

  /// Tradutor ARM 64 bits ativo: aceita apps só ARM64.
  final bool arm64;

  /// Instala um `.apk` ou um `.xapk` (APK base + partes + OBB).
  Stream<InstallProgress> install(String apkPath) {
    if (XapkInstaller.matches(apkPath)) {
      return XapkInstaller(adb, armTranslation: armTranslation, arm64: arm64).install(apkPath);
    }
    return _installApk(apkPath);
  }

  Stream<InstallProgress> _installApk(String apkPath) async* {
    yield InstallProgress(InstallPhase.inspecting, message: 'Analisando APK…');
    final ApkInfo info;
    try {
      info = await ApkInspector.inspect(apkPath);
    } on ApkFormatError catch (e) {
      yield InstallProgress(InstallPhase.failed, message: e.message);
      return;
    }
    log.info('APK ${info.packageName} ${info.versionName ?? ''} '
        'abis=${info.nativeAbis} minSdk=${info.minSdk}');
    final abiProblem = AbiPolicy.rejection(info.nativeAbis, armTranslation: armTranslation, arm64: arm64);
    if (abiProblem != null) {
      yield InstallProgress(InstallPhase.failed, info: info, message: abiProblem);
      return;
    }
    if (AbiPolicy.needsTranslation(info.nativeAbis)) {
      log.info('${info.packageName}: só ARM 32 bits, vai rodar pela tradução ARM');
    }
    if (info.minSdk != null && info.minSdk! > guestSdk) {
      yield InstallProgress(InstallPhase.failed, info: info,
          message: 'O aplicativo exige Android API ${info.minSdk! >= 10000 ? 'de prévia' : info.minSdk}; '
              'o sistema da VM é Android 9 (API $guestSdk).');
      return;
    }

    yield InstallProgress(InstallPhase.transferring, fraction: 0, info: info,
        message: 'Enviando ${info.packageName}…');
    final proc = await Process.start(adb.adbPath, [
      '-s', adb.serial, 'shell', 'pm', 'install', '-r', '-t', '-S', '${info.size}',
    ]);
    final out = proc.stdout.transform(utf8.decoder).join();
    final err = proc.stderr.transform(utf8.decoder).join();
    var sent = 0;
    var lastReported = -1;
    final progress = StreamController<InstallProgress>();
    final pump = () async {
      try {
        await for (final chunk in File(apkPath).openRead()) {
          proc.stdin.add(chunk);
          await proc.stdin.flush();
          sent += chunk.length;
          final pct = (sent * 100) ~/ info.size;
          if (pct != lastReported) {
            lastReported = pct;
            progress.add(InstallProgress(InstallPhase.transferring,
                fraction: sent / info.size, info: info,
                message: 'Enviando ${info.packageName}… $pct%'));
          }
        }
        await proc.stdin.close();
      } catch (e) {
        progress.addError(e);
      } finally {
        await progress.close();
      }
    }();
    try {
      yield* progress.stream;
      await pump;
    } catch (e) {
      proc.kill();
      yield InstallProgress(InstallPhase.failed, info: info,
          message: 'Falha ao transferir o APK: $e');
      return;
    }

    yield InstallProgress(InstallPhase.installing, info: info,
        message: 'Instalando ${info.packageName}…');
    final code = await proc.exitCode.timeout(const Duration(minutes: 5),
        onTimeout: () {
      proc.kill();
      return -1;
    });
    final output = '${await out}\n${await err}'.trim();
    log.info('pm install (${info.packageName}) => $code: $output');
    if (output.contains('Success')) {
      yield InstallProgress(InstallPhase.done, info: info,
          message: '${info.packageName} instalado com sucesso.');
    } else {
      yield InstallProgress(InstallPhase.failed, info: info,
          message: describeInstallFailure(output, code));
    }
  }
}

/// Traduz códigos de erro do PackageManager em mensagens compreensíveis.
String describeInstallFailure(String output, int exitCode) {
  final m = RegExp(r'(INSTALL_[A-Z_]+)').firstMatch(output);
  final code = m?.group(1);
  const messages = {
    'INSTALL_FAILED_NO_MATCHING_ABIS':
        'Incompatível com x86-64: o APK não contém bibliotecas para esta '
            'arquitetura nem para ARM 32 bits (a tradução ARM não cobre ARM64).',
    'INSTALL_FAILED_OLDER_SDK':
        'O aplicativo exige uma versão do Android mais nova que a da VM (Android 9).',
    'INSTALL_FAILED_INSUFFICIENT_STORAGE':
        'Armazenamento insuficiente na VM. Aumente o disco virtual nas configurações.',
    'INSTALL_FAILED_UPDATE_INCOMPATIBLE':
        'Já existe uma versão do app com assinatura diferente. Desinstale-a primeiro.',
    'INSTALL_FAILED_VERSION_DOWNGRADE':
        'Uma versão mais nova deste app já está instalada.',
    'INSTALL_PARSE_FAILED_NO_CERTIFICATES':
        'APK sem assinatura válida.',
    'INSTALL_PARSE_FAILED_NOT_APK': 'O arquivo não é um APK válido.',
    'INSTALL_FAILED_INVALID_APK': 'APK inválido ou corrompido.',
    'INSTALL_PARSE_FAILED_MANIFEST_MALFORMED': 'Manifesto do APK malformado.',
    'INSTALL_FAILED_DUPLICATE_PERMISSION':
        'O app declara uma permissão que já pertence a outro app instalado.',
    'INSTALL_FAILED_MISSING_SPLIT':
        'Este app foi distribuído em partes (split APK); instale o conjunto completo.',
    'INSTALL_FAILED_MISSING_SHARED_LIBRARY':
        'O app depende de uma biblioteca do sistema ausente (por exemplo, '
            'serviços do Google).',
  };
  if (code != null) {
    return '${messages[code] ?? 'A instalação falhou.'} ($code)';
  }
  if (output.contains('device offline') || output.contains('not found')) {
    return 'O Android não está acessível via ADB. Aguarde o boot terminar.';
  }
  return 'A instalação falhou (código $exitCode): '
      '${output.isEmpty ? 'sem resposta do Android' : output}';
}
