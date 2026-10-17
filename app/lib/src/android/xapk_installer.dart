import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_log.dart';
import '../core/paths.dart';
import 'adb.dart';
import 'apk_inspector.dart';
import 'apk_installer.dart';
import 'zip_reader.dart';

/// Arquivo extra (OBB ou dados) de um XAPK, copiado para o armazenamento
/// compartilhado do Android.
class XapkExtra {
  XapkExtra(this.entry, this.destination);
  final ZipEntry entry;

  /// Caminho relativo a /sdcard (sempre sob `Android/obb/` ou `Android/data/`).
  final String destination;
}

/// Conteúdo de um XAPK já analisado.
class XapkPlan {
  XapkPlan({
    required this.packageName,
    required this.apks,
    required this.extras,
    this.versionName,
    this.manifestMinSdk,
  });
  final String? packageName;
  final String? versionName;
  final int? manifestMinSdk;
  final List<ZipEntry> apks;
  final List<XapkExtra> extras;
}

/// Instala pacotes `.xapk`: um ZIP com o APK base, partes (split APKs) e,
/// opcionalmente, arquivos OBB/dados.
///
/// As partes são instaladas numa única sessão do PackageManager
/// (`pm install-create` → `install-write` por parte → `install-commit`),
/// transmitidas pelo stdin como no APK simples. Os OBB são transmitidos direto
/// do ZIP (`cat > /sdcard/Android/obb/...`), sem passar pelo disco do
/// computador: costumam ter gigabytes.
class XapkInstaller {
  XapkInstaller(this.adb, {this.workDir, this.armTranslation = false, this.arm64 = false});
  final Adb adb;

  /// Tradução ARM ligada: aceita apps só ARM 32 bits (ver [AbiPolicy]).
  final bool armTranslation;

  /// Tradutor ARM 64 bits ativo (ver [AbiPolicy]).
  final bool arm64;

  /// Pasta para os APKs extraídos (padrão: cache do SECADA Emulator).
  final String? workDir;

  static bool matches(String path) => path.toLowerCase().endsWith('.xapk');

  /// Caminho de destino seguro sob /sdcard, ou null se o do manifesto for
  /// suspeito (só são aceitos `Android/obb/...` e `Android/data/...`).
  static String? safeDestination(String path) {
    final norm = path.replaceAll('\\', '/');
    if (norm.contains(RegExp(r'''[\x00-\x1f'"`$;&|<>]'''))) return null;
    final parts = norm.split('/').where((e) => e.isNotEmpty).toList();
    if (parts.length < 3 || parts.any((e) => e == '..' || e == '.')) return null;
    if (parts[0] != 'Android' || (parts[1] != 'obb' && parts[1] != 'data')) return null;
    return parts.join('/');
  }

  /// Lê o manifesto do XAPK e decide o que instalar. Aceita o formato
  /// atual (`split_apks` + `expansions`) e o antigo (APK na raiz + pasta
  /// `Android/`).
  static Future<XapkPlan> plan(ZipReader zip) async {
    Map<String, Object?> manifest = const {};
    final mEntry = zip['manifest.json'];
    if (mEntry != null) {
      try {
        var text = utf8.decode(await zip.readAll(mEntry), allowMalformed: true);
        if (text.startsWith('\u{feff}')) text = text.substring(1);
        final j = jsonDecode(text);
        if (j is Map) manifest = Map<String, Object?>.from(j);
      } catch (_) {
        throw ZipFormatError('manifest.json do XAPK está corrompido.');
      }
    }

    final apks = <ZipEntry>[];
    final splits = manifest['split_apks'];
    if (splits is List) {
      for (final s in splits) {
        final file = s is Map ? s['file'] : null;
        if (file is! String) continue;
        final e = zip[file];
        if (e == null) throw ZipFormatError('O XAPK cita "$file", que não está no arquivo.');
        apks.add(e);
      }
    }
    if (apks.isEmpty) {
      apks.addAll(zip.entries.values.where((e) =>
          !e.isDirectory &&
          e.name.toLowerCase().endsWith('.apk') &&
          !e.name.startsWith('Android/')));
    }
    if (apks.isEmpty) throw ZipFormatError('Nenhum APK encontrado dentro do XAPK.');

    final extras = <XapkExtra>[];
    final exp = manifest['expansions'];
    if (exp is List && exp.isNotEmpty) {
      for (final x in exp) {
        if (x is! Map) continue;
        final file = x['file'];
        if (file is! String) continue;
        final e = zip[file];
        if (e == null) throw ZipFormatError('O XAPK cita "$file", que não está no arquivo.');
        final dest = safeDestination('${x['install_path'] ?? file}');
        if (dest == null) {
          throw ZipFormatError('Destino inseguro no XAPK: "${x['install_path'] ?? file}".');
        }
        extras.add(XapkExtra(e, dest));
      }
    } else {
      for (final e in zip.entries.values) {
        if (e.isDirectory || !e.name.startsWith('Android/')) continue;
        final dest = safeDestination(e.name);
        if (dest != null) extras.add(XapkExtra(e, dest));
      }
    }

    return XapkPlan(
      packageName: manifest['package_name'] is String ? manifest['package_name'] as String : null,
      versionName: manifest['version_name'] is String ? manifest['version_name'] as String : null,
      manifestMinSdk: int.tryParse('${manifest['min_sdk_version'] ?? ''}'),
      apks: apks,
      extras: extras,
    );
  }

  static String _splitName(int i, String entryName) =>
      '${i}_${p.basename(entryName).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}';

  static String _sh(String v) => "'${v.replaceAll("'", r"'\''")}'";

  /// Instala o XAPK; o progresso sai em tempo real durante a transferência.
  Stream<InstallProgress> install(String xapkPath) {
    final c = StreamController<InstallProgress>();
    () async {
      try {
        await _install(xapkPath, c.add);
      } catch (e, st) {
        log.error('Falha ao instalar o XAPK', e, st);
        c.add(InstallProgress(InstallPhase.failed, message: 'Falha ao instalar o XAPK: $e'));
      } finally {
        await c.close();
      }
    }();
    return c.stream;
  }

  Future<void> _install(String xapkPath, void Function(InstallProgress) emit) async {
    emit(InstallProgress(InstallPhase.inspecting, message: 'Analisando XAPK…'));
    final ZipReader zip;
    final XapkPlan plan;
    try {
      zip = await ZipReader.open(xapkPath);
    } on ZipFormatError catch (e) {
      emit(InstallProgress(InstallPhase.failed, message: e.message));
      return;
    }
    final base = workDir ?? SecadaPaths.instance.cacheDir;
    await Directory(base).create(recursive: true);
    final tmp = await Directory(base).createTemp('xapk-');
    try {
      try {
        plan = await XapkInstaller.plan(zip);
      } on ZipFormatError catch (e) {
        emit(InstallProgress(InstallPhase.failed, message: e.message));
        return;
      }

      // Extrai só os APKs (precisam ser inspecionados); os OBB vão em fluxo.
      emit(InstallProgress(InstallPhase.inspecting,
          message: 'Extraindo ${plan.apks.length} parte(s) do XAPK…'));
      final files = <File>[];
      final infos = <ApkInfo>[];
      try {
        for (var i = 0; i < plan.apks.length; i++) {
          final dest = p.join(tmp.path, _splitName(i, plan.apks[i].name));
          await zip.extractTo(plan.apks[i], dest);
          files.add(File(dest));
          infos.add(await ApkInspector.inspect(dest));
        }
      } on ZipFormatError catch (e) {
        emit(InstallProgress(InstallPhase.failed, message: e.message));
        return;
      } on ApkFormatError catch (e) {
        emit(InstallProgress(InstallPhase.failed, message: 'XAPK com APK inválido: ${e.message}'));
        return;
      }

      // O pacote é o do APK base (o primeiro que não é "config.*").
      final baseInfo = infos.firstWhere((i) => !p.basename(i.path).contains('config.'),
          orElse: () => infos.first);
      final pkg = plan.packageName ?? baseInfo.packageName;
      final abis = {for (final i in infos) ...i.nativeAbis};
      final hasX86 = AbiPolicy.hasX86(abis);
      final abiProblem =
          AbiPolicy.rejection(abis, armTranslation: armTranslation, arm64: arm64, what: 'O XAPK');
      if (abiProblem != null) {
        emit(InstallProgress(InstallPhase.failed, info: baseInfo, message: abiProblem));
        return;
      }
      final minSdk = [
        for (final i in infos) i.minSdk,
        plan.manifestMinSdk,
      ].whereType<int>().fold<int>(0, (a, b) => a > b ? a : b);
      if (minSdk > guestSdk) {
        emit(InstallProgress(InstallPhase.failed, info: baseInfo,
            message: 'O aplicativo exige Android API ${minSdk >= 10000 ? 'de prévia' : minSdk}; '
                'o sistema da VM é Android 9 (API $guestSdk).'));
        return;
      }

      // Partes de ABI que o Android não usaria ficam de fora: com código x86,
      // todas as partes só-ARM; sem ele (tradução ARM), as só-ARM64 quando
      // não há tradutor de 64 bits.
      final install = <File>[];
      for (var i = 0; i < files.length; i++) {
        final a = infos[i].nativeAbis;
        final armOnly = a.isNotEmpty && !AbiPolicy.hasX86(a);
        final usable = AbiPolicy.hasArm32(a) || (arm64 && AbiPolicy.hasArm64(a));
        final skip = armOnly && (hasX86 || !usable);
        if (skip) {
          log.info('XAPK: ignorando ${p.basename(files[i].path)} (${a.join(', ')})');
        } else {
          install.add(files[i]);
        }
      }

      final apkBytes = [for (final f in install) f.lengthSync()].fold<int>(0, (a, b) => a + b);
      final extraBytes = plan.extras.fold<int>(0, (a, e) => a + e.entry.size);
      final totalBytes = apkBytes + extraBytes;
      var sent = 0;
      var lastPct = -1;
      void bump(int n) {
        sent += n;
        final pct = totalBytes == 0 ? 100 : (sent * 100) ~/ totalBytes;
        if (pct != lastPct) {
          lastPct = pct;
          emit(InstallProgress(InstallPhase.transferring,
              fraction: totalBytes == 0 ? 1 : sent / totalBytes,
              info: baseInfo,
              message: 'Enviando $pkg… $pct%'));
        }
      }

      emit(InstallProgress(InstallPhase.transferring,
          fraction: 0, info: baseInfo, message: 'Enviando $pkg…'));

      // 1. Sessão de instalação.
      final created = await adb.shell('pm install-create -r -t -S $apkBytes',
          timeout: const Duration(seconds: 30));
      final sid = RegExp(r'\[(\d+)\]').firstMatch(created.text)?.group(1);
      if (sid == null) {
        emit(InstallProgress(InstallPhase.failed, info: baseInfo,
            message: describeInstallFailure('${created.text}\n${created.stderr}', created.exitCode)));
        return;
      }

      // 2. Cada parte pelo stdin.
      for (var i = 0; i < install.length; i++) {
        final f = install[i];
        final r = await _writeSplit(sid, f, bump);
        if (!r.text.contains('Success')) {
          await adb.shell('pm install-abandon $sid', timeout: const Duration(seconds: 15));
          emit(InstallProgress(InstallPhase.failed, info: baseInfo,
              message: describeInstallFailure('${r.text}\n${r.stderr}', r.exitCode)));
          return;
        }
      }

      // 3. Confirma.
      emit(InstallProgress(InstallPhase.installing, info: baseInfo, message: 'Instalando $pkg…'));
      final commit = await adb.shell('pm install-commit $sid', timeout: const Duration(minutes: 5));
      final commitOut = '${commit.text}\n${commit.stderr}'.trim();
      log.info('pm install-commit ($pkg) => ${commit.exitCode}: $commitOut');
      if (!commitOut.contains('Success')) {
        emit(InstallProgress(InstallPhase.failed, info: baseInfo,
            message: describeInstallFailure(commitOut, commit.exitCode)));
        return;
      }

      // 4. Arquivos extras (OBB/dados) direto do ZIP.
      for (final x in plan.extras) {
        emit(InstallProgress(InstallPhase.transferring,
            fraction: totalBytes == 0 ? 1 : sent / totalBytes,
            info: baseInfo,
            message: 'Copiando ${p.basename(x.destination)}…'));
        final dir = p.posix.dirname('/sdcard/${x.destination}');
        // Um único argumento: o `adb shell` junta os argumentos com espaços e
        // o Android executa o resultado com `sh -c`, então o script não pode
        // ser repartido nem embrulhado em outro `sh -c`.
        final r = await adb.shellStreaming(
          ['mkdir -p ${_sh(dir)} && cat > ${_sh('/sdcard/${x.destination}')}'],
          zip.openRead(x.entry),
          onBytes: bump,
        );
        if (r.exitCode != 0) {
          emit(InstallProgress(InstallPhase.failed, info: baseInfo,
              message: '$pkg foi instalado, mas não foi possível copiar '
                  '${p.basename(x.destination)} '
                  '(${'${r.text}\n${r.stderr}'.trim().split('\n').last}). '
                  'Sem esse arquivo o app pode não abrir.'));
          return;
        }
      }

      emit(InstallProgress(InstallPhase.done, info: baseInfo,
          message: '$pkg instalado com sucesso'
              '${install.length > 1 ? ' (${install.length} partes)' : ''}'
              '${plan.extras.isNotEmpty ? ' e ${plan.extras.length} arquivo(s) de dados copiados' : ''}.'));
    } finally {
      await zip.close();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<AdbResult> _writeSplit(String sid, File f, void Function(int) bump) {
    final size = f.lengthSync();
    return adb.shellStreaming([
      // O arquivo extraído já se chama "<índice>_<nome saneado>".
      'pm', 'install-write', '-S', '$size', sid, p.basename(f.path), '-',
    ], f.openRead(), onBytes: bump);
  }
}
