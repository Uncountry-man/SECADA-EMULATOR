import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_log.dart';
import '../core/paths.dart';

/// Registra o SECADA Emulator como programa que abre `.apk` e `.xapk` (duplo clique no
/// gerenciador de arquivos), em qualquer distribuição Linux com o padrão
/// freedesktop.org.
///
/// Três peças:
/// * **entrada `.desktop`** com `MimeType=` e `Exec=... %F` (o `%F` entrega os
///   arquivos selecionados na linha de comando);
/// * **tipo MIME do XAPK** (`application/x-xapk`, `*.xapk`): o APK já existe no
///   shared-mime-info, o XAPK não;
/// * **aplicativo padrão** em `mimeapps.list`, feito uma única vez para o
///   usuário: sem isso, o gerenciador de arquivos continua abrindo o APK no
///   gerenciador de arquivos compactados.
///
/// Instalações do sistema (`.deb`, em /opt ou /usr) já trazem as duas
/// primeiras peças; o resto serve ao pacote portátil. Tudo é idempotente e
/// falhas só são registradas no log.
abstract final class FileAssociations {
  static const desktopFileName = 'secada.desktop';

  /// Nome antigo do programa (Anux). Quem usava o Anux tem `anux.desktop` como
  /// padrão de .apk/.xapk e o duplo clique continuaria abrindo o programa
  /// antigo; o SECADA assume o lugar dele (ver [migrateLegacyMimeApps]).
  static const apkMime = 'application/vnd.android.package-archive';
  static const xapkMime = 'application/x-xapk';
  static const mimeTypes = [apkMime, xapkMime];
  static const _markerName = 'associations-v1';

  /// Mesmo conteúdo de `packaging/secada-xapk.xml` (há um teste que confere).
  static const mimeXml = '''<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-xapk">
    <comment>Android application package with extra data (XAPK)</comment>
    <comment xml:lang="pt_BR">Pacote de aplicativo Android com dados extras (XAPK)</comment>
    <sub-class-of type="application/zip"/>
    <glob pattern="*.xapk"/>
  </mime-type>
</mime-info>
''';

  /// Valor do campo `Exec=`: o executável entre aspas (a especificação exige
  /// escapar `"`, `` ` ``, `$` e `\`, e depois dobrar as barras do valor).
  static String execLine(String exe) {
    final q = exe
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('`', r'\`')
        .replaceAll(r'$', r'\$')
        .replaceAll('%', '%%');
    return '"${q.replaceAll(r'\', r'\\')}" %F';
  }

  static String desktopEntry({required String exe, String? icon}) => '''[Desktop Entry]
Type=Application
Name=SECADA Emulator
GenericName=Emulador Android
GenericName[en]=Android emulator
Comment=Android 9 em máquina virtual QEMU/KVM
Exec=${execLine(exe)}
Icon=${icon ?? 'secada'}
Terminal=false
Categories=Utility;Emulator;
MimeType=${mimeTypes.join(';')};
StartupWMClass=dev.secada.secada
StartupNotify=true
''';

  /// Instalação do sistema (pacote .deb): os arquivos de registro vêm do
  /// próprio pacote.
  static bool isSystemInstall(String exe) => exe.startsWith('/opt/') || exe.startsWith('/usr/');

  /// Devolve [text] (conteúdo de um `mimeapps.list`) com `secada.desktop` como
  /// primeiro aplicativo de cada tipo em `[Default Applications]` e
  /// `[Added Associations]`, preservando todo o resto.
  static String mergeMimeApps(String text, {List<String> types = mimeTypes}) {
    var lines = text.isEmpty ? <String>[] : text.split('\n');
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();

    List<String> section(List<String> ls, String header) {
      var start = ls.indexWhere((l) => l.trim() == header);
      if (start < 0) {
        if (ls.isNotEmpty && ls.last.trim().isNotEmpty) ls = [...ls, ''];
        ls = [...ls, header];
        start = ls.length - 1;
      }
      var end = ls.length;
      for (var i = start + 1; i < ls.length; i++) {
        if (ls[i].trim().startsWith('[')) {
          end = i;
          break;
        }
      }
      for (final t in types) {
        final idx = ls.indexWhere((l) => l.startsWith('$t='), start + 1);
        if (idx >= 0 && idx < end) {
          final apps = ls[idx]
              .substring(t.length + 1)
              .split(';')
              .where((a) => a.isNotEmpty && a != desktopFileName)
              .toList();
          ls[idx] = '$t=${[desktopFileName, ...apps].join(';')};';
        } else {
          ls.insert(end, '$t=$desktopFileName;');
          end++;
        }
      }
      return ls;
    }

    lines = section(lines, '[Default Applications]');
    lines = section(lines, '[Added Associations]');
    return '${lines.join('\n')}\n';
  }

  static const legacyDesktopFileName = 'anux.desktop';

  /// Troca `anux.desktop` por `secada.desktop` nas linhas de .apk/.xapk de um
  /// `mimeapps.list`, em qualquer seção, colocando o SECADA à frente e
  /// mantendo os demais programas. Linhas sem o programa antigo (inclusive a
  /// escolha de outro programa) não mudam.
  static String migrateLegacyMimeApps(String text, {List<String> types = mimeTypes}) {
    final lines = text.split('\n');
    var changed = false;
    for (var i = 0; i < lines.length; i++) {
      for (final t in types) {
        if (!lines[i].startsWith('$t=')) continue;
        final apps = lines[i].substring(t.length + 1).split(';').where((a) => a.isNotEmpty).toList();
        if (!apps.contains(legacyDesktopFileName)) continue;
        final rest = apps.where((a) => a != legacyDesktopFileName && a != desktopFileName);
        lines[i] = '$t=${[desktopFileName, ...rest].join(';')};';
        changed = true;
      }
    }
    return changed ? lines.join('\n') : text;
  }

  /// Tira do Anux antigo a posse dos tipos de arquivo: remove `MimeType=` do
  /// `anux.desktop` do usuário (o atalho no menu continua) e apaga a
  /// definição duplicada do tipo XAPK. Retorna se algo mudou.
  static Future<bool> _retireLegacyEntries(String dataHome) async {
    var changed = false;
    final desktop = File(p.join(dataHome, 'applications', legacyDesktopFileName));
    if (await desktop.exists()) {
      final text = await desktop.readAsString();
      final stripped =
          text.split('\n').where((l) => !l.startsWith('MimeType=')).join('\n');
      if (stripped != text) {
        await desktop.writeAsString(stripped);
        changed = true;
      }
    }
    final mime = File(p.join(dataHome, 'mime', 'packages', 'anux-xapk.xml'));
    if (await mime.exists()) {
      await mime.delete();
      changed = true;
    }
    return changed;
  }

  /// Executa o registro. Os parâmetros existem para os testes; no uso normal
  /// vêm do ambiente.
  static Future<void> ensure({
    String? exe,
    String? dataHome,
    String? configHome,
    String? markerDir,
    bool runTools = true,
  }) async {
    try {
      final env = Platform.environment;
      final home = env['HOME'] ?? '';
      if (home.isEmpty && dataHome == null) return;
      exe ??= Platform.resolvedExecutable;
      dataHome ??= (env['XDG_DATA_HOME']?.isNotEmpty ?? false)
          ? env['XDG_DATA_HOME']!
          : p.join(home, '.local', 'share');
      configHome ??= (env['XDG_CONFIG_HOME']?.isNotEmpty ?? false)
          ? env['XDG_CONFIG_HOME']!
          : p.join(home, '.config');

      if (!isSystemInstall(exe)) {
        final iconFile = p.join(p.dirname(exe), 'share', 'secada.png');
        final desktopChanged = await _writeIfChanged(
          p.join(dataHome, 'applications', desktopFileName),
          desktopEntry(exe: exe, icon: File(iconFile).existsSync() ? iconFile : null),
        );
        final mimeChanged =
            await _writeIfChanged(p.join(dataHome, 'mime', 'packages', 'secada-xapk.xml'), mimeXml);
        if (runTools) {
          if (mimeChanged) await _run('update-mime-database', [p.join(dataHome, 'mime')]);
          if (desktopChanged) {
            await _run('update-desktop-database', [p.join(dataHome, 'applications')]);
          }
        }
        final legacyChanged = await _retireLegacyEntries(dataHome);
        if (runTools && legacyChanged) {
          await _run('update-mime-database', [p.join(dataHome, 'mime')]);
          await _run('update-desktop-database', [p.join(dataHome, 'applications')]);
        }
        if (desktopChanged || mimeChanged || legacyChanged) {
          log.info('SECADA Emulator registrado como programa para .apk/.xapk ($dataHome)');
        }
      }

      // Migração do Anux: o padrão antigo passa ao SECADA em toda abertura
      // (não depende do marcador abaixo, que o Anux já tinha gravado).
      final mimeapps = File(p.join(configHome, 'mimeapps.list'));
      if (await mimeapps.exists()) {
        final cur = await mimeapps.readAsString();
        final migrated = migrateLegacyMimeApps(cur);
        if (migrated != cur) {
          final tmp = File('${mimeapps.path}.secada-tmp');
          await tmp.writeAsString(migrated);
          await tmp.rename(mimeapps.path);
          log.info('Padrão de .apk/.xapk passou do Anux para o SECADA Emulator');
        }
      }

      // Aplicativo padrão: uma única vez; depois disso respeita a escolha do
      // usuário no gerenciador de arquivos.
      final marker = File(p.join(markerDir ?? SecadaPaths.instance.configDir, _markerName));
      if (!await marker.exists()) {
        final list = File(p.join(configHome, 'mimeapps.list'));
        final current = await list.exists() ? await list.readAsString() : '';
        final merged = mergeMimeApps(current);
        if (merged != current) {
          await list.parent.create(recursive: true);
          final tmp = File('${list.path}.secada-tmp');
          await tmp.writeAsString(merged);
          await tmp.rename(list.path);
        }
        await marker.parent.create(recursive: true);
        await marker.writeAsString(DateTime.now().toIso8601String());
        log.info('SECADA Emulator definido como programa padrão para .apk/.xapk');
      }
    } catch (e) {
      log.warn('Não foi possível registrar os tipos de arquivo APK/XAPK: $e');
    }
  }

  static Future<bool> _writeIfChanged(String path, String content) async {
    final f = File(path);
    if (await f.exists() && await f.readAsString() == content) return false;
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
    return true;
  }

  static Future<void> _run(String tool, List<String> args) async {
    try {
      await Process.run(tool, args).timeout(const Duration(seconds: 20));
    } catch (_) {
      // Ferramenta ausente: o desktop atualiza as bases na próxima sessão.
    }
  }
}
