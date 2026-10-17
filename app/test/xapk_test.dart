import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:secada/src/android/adb.dart';
import 'package:secada/src/android/apk_installer.dart';
import 'package:secada/src/android/install_queue.dart';
import 'package:secada/src/android/xapk_installer.dart';
import 'package:secada/src/android/zip_reader.dart';
import 'package:secada/src/host/file_associations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'zip_helpers.dart';

/// Converte um ZIP comum em ZIP64 (tamanhos e deslocamento no campo extra,
/// registro e localizador ZIP64), para testar o leitor.
Uint8List toZip64(Uint8List zip) {
  final bd = ByteData.sublistView(zip);
  final eocd = zip.length - 22;
  final count = bd.getUint16(eocd + 10, Endian.little);
  final cdSize = bd.getUint32(eocd + 12, Endian.little);
  final cdOffset = bd.getUint32(eocd + 16, Endian.little);
  final cd = zip.sublist(cdOffset, cdOffset + cdSize);
  final cbd = ByteData.sublistView(cd);
  final newCd = BytesBuilder();
  var pos = 0;
  for (var i = 0; i < count; i++) {
    final nameLen = cbd.getUint16(pos + 28, Endian.little);
    final comp = cbd.getUint32(pos + 20, Endian.little);
    final size = cbd.getUint32(pos + 24, Endian.little);
    final off = cbd.getUint32(pos + 42, Endian.little);
    final head = Uint8List.fromList(cd.sublist(pos, pos + 46 + nameLen));
    ByteData.sublistView(head)
      ..setUint32(20, 0xffffffff, Endian.little)
      ..setUint32(24, 0xffffffff, Endian.little)
      ..setUint32(42, 0xffffffff, Endian.little)
      ..setUint16(30, 28, Endian.little); // tamanho do campo extra
    final extra = ByteData(28)
      ..setUint16(0, 1, Endian.little)
      ..setUint16(2, 24, Endian.little)
      ..setUint32(4, size, Endian.little)
      ..setUint32(12, comp, Endian.little)
      ..setUint32(20, off, Endian.little);
    newCd
      ..add(head)
      ..add(extra.buffer.asUint8List());
    pos += 46 + nameLen;
  }
  final out = BytesBuilder()..add(zip.sublist(0, cdOffset));
  final cdBytes = newCd.toBytes();
  final rec64Offset = out.length + cdBytes.length;
  out.add(cdBytes);
  final rec = ByteData(56)
    ..setUint32(0, 0x06064b50, Endian.little)
    ..setUint32(4, 44, Endian.little)
    ..setUint32(24, count, Endian.little)
    ..setUint32(32, count, Endian.little)
    ..setUint32(40, cdBytes.length, Endian.little)
    ..setUint32(48, cdOffset, Endian.little);
  final loc = ByteData(20)
    ..setUint32(0, 0x07064b50, Endian.little)
    ..setUint32(8, rec64Offset, Endian.little)
    ..setUint32(16, 1, Endian.little);
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, 0xffff, Endian.little)
    ..setUint16(10, 0xffff, Endian.little)
    ..setUint32(12, 0xffffffff, Endian.little)
    ..setUint32(16, 0xffffffff, Endian.little);
  out
    ..add(rec.buffer.asUint8List())
    ..add(loc.buffer.asUint8List())
    ..add(end.buffer.asUint8List());
  return out.toBytes();
}

List<int> pattern(int n, int seed) => List<int>.generate(n, (i) => (i * 31 + seed) & 0xff);

/// `adb` de mentira: registra os argumentos e os bytes recebidos pelo stdin e
/// responde como o PackageManager.
Future<String> writeFakeAdb(Directory dir) async {
  final f = File(p.join(dir.path, 'fake-adb.sh'));
  await f.writeAsString(r'''#!/bin/bash
shift 2   # -s serial
sub="$1"; shift
cmd="$*"
echo "$sub $cmd" >> "$FAKE_ADB_LOG"
[ "$sub" = shell ] || exit 0
case "$cmd" in
  "pm install -r"*)
    n=$(wc -c)
    echo "  bytes=$n" >> "$FAKE_ADB_LOG"
    echo "Success";;
  "pm install-create"*)
    [ -n "$FAKE_FAIL_CREATE" ] && { echo "Error: Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]"; exit 1; }
    echo "Success: created install session [4242]";;
  "pm install-write"*)
    n=$(wc -c)
    echo "  bytes=$n" >> "$FAKE_ADB_LOG"
    [ -n "$FAKE_FAIL_WRITE" ] && { echo "Failure [INSTALL_FAILED_INVALID_APK]"; exit 1; }
    echo "Success: streamed $n bytes";;
  "pm install-commit"*) echo "Success";;
  "pm install-abandon"*) echo "Success";;
  "mkdir -p"*)
    n=$(wc -c)
    echo "  bytes=$n" >> "$FAKE_ADB_LOG"
    [ -n "$FAKE_FAIL_SH" ] && { echo "cat: write error: No space left on device" >&2; exit 1; }
    ;;
esac
exit 0
''');
  await Process.run('chmod', ['+x', f.path]);
  return f.path;
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('secada-xapk'));
  tearDown(() => dir.delete(recursive: true));

  Future<String> write(String name, List<int> bytes) async {
    final f = File(p.join(dir.path, name));
    await f.writeAsBytes(bytes);
    return f.path;
  }

  group('ZipReader', () {
    test('lê entradas armazenadas e comprimidas, em blocos', () async {
      final big = pattern(700 * 1024, 7);
      final path = await write('a.zip', buildZip({
        'pequeno.txt': utf8.encode('olá'),
        'grande.bin': big,
        'cru.bin': pattern(1000, 3),
      }, stored: {'cru.bin'}));
      final zip = await ZipReader.open(path);
      addTearDown(zip.close);
      expect(zip.entries.keys, containsAll(['pequeno.txt', 'grande.bin', 'cru.bin']));
      expect(utf8.decode(await zip.readAll(zip['pequeno.txt']!)), 'olá');
      expect(await zip.readAll(zip['cru.bin']!), pattern(1000, 3));
      var chunks = 0;
      final got = BytesBuilder();
      await for (final c in zip.openRead(zip['grande.bin']!, chunkSize: 64 * 1024)) {
        chunks++;
        got.add(c);
      }
      expect(chunks, greaterThan(1));
      expect(got.takeBytes(), big);
      expect(zip['grande.bin']!.size, big.length);
    });

    test('suporta ZIP64', () async {
      final data = pattern(5000, 9);
      final path = await write('z64.zip', toZip64(buildZip({'x.bin': data, 'y.txt': [65]})));
      final zip = await ZipReader.open(path);
      addTearDown(zip.close);
      expect(await zip.readAll(zip['x.bin']!), data);
      expect(await zip.readAll(zip['y.txt']!), [65]);
    });

    test('arquivo que não é ZIP gera erro compreensível', () async {
      final path = await write('x.zip', utf8.encode('isto não é um zip, de jeito nenhum!'));
      expect(() => ZipReader.open(path), throwsA(isA<ZipFormatError>()));
      expect(() => ZipReader.open(p.join(dir.path, 'nao-existe.zip')),
          throwsA(isA<ZipFormatError>()));
    });
  });

  group('plano do XAPK', () {
    Future<ZipReader> open(Map<String, List<int>> files) async =>
        ZipReader.open(await write('t.xapk', buildZip(files)));

    test('formato atual: split_apks e expansions', () async {
      final zip = await open({
        'manifest.json': utf8.encode(jsonEncode({
          'package_name': 'com.jogo',
          'min_sdk_version': '21',
          'split_apks': [
            {'file': 'com.jogo.apk', 'id': 'base'},
            {'file': 'config.x86_64.apk', 'id': 'config.x86_64'},
          ],
          'expansions': [
            {
              'file': 'Android/obb/com.jogo/main.1.com.jogo.obb',
              'install_location': 'EXTERNAL_STORAGE',
              'install_path': 'Android/obb/com.jogo/main.1.com.jogo.obb',
            }
          ],
        })),
        'com.jogo.apk': [1],
        'config.x86_64.apk': [2],
        'Android/obb/com.jogo/main.1.com.jogo.obb': [3],
      });
      addTearDown(zip.close);
      final plan = await XapkInstaller.plan(zip);
      expect(plan.packageName, 'com.jogo');
      expect(plan.manifestMinSdk, 21);
      expect(plan.apks.map((e) => e.name), ['com.jogo.apk', 'config.x86_64.apk']);
      expect(plan.extras.single.destination, 'Android/obb/com.jogo/main.1.com.jogo.obb');
    });

    test('formato antigo: APK na raiz e pasta Android/', () async {
      final zip = await open({
        'com.velho.apk': [1],
        'Android/obb/com.velho/main.5.obb': [2],
        'icon.png': [3],
      });
      addTearDown(zip.close);
      final plan = await XapkInstaller.plan(zip);
      expect(plan.apks.single.name, 'com.velho.apk');
      expect(plan.extras.single.destination, 'Android/obb/com.velho/main.5.obb');
    });

    test('sem APK ou com referência quebrada é recusado', () async {
      final none = await open({'manifest.json': utf8.encode('{}'), 'x.txt': [1]});
      addTearDown(none.close);
      expect(() => XapkInstaller.plan(none), throwsA(isA<ZipFormatError>()));
      final broken = await open({
        'manifest.json': utf8.encode(jsonEncode({'split_apks': [{'file': 'sumiu.apk'}]})),
      });
      addTearDown(broken.close);
      expect(() => XapkInstaller.plan(broken), throwsA(isA<ZipFormatError>()));
    });

    test('destinos fora de Android/obb e Android/data são recusados', () {
      expect(XapkInstaller.safeDestination('Android/obb/com.a/main.obb'), 'Android/obb/com.a/main.obb');
      expect(XapkInstaller.safeDestination('Android/data/com.a/x.dat'), 'Android/data/com.a/x.dat');
      expect(XapkInstaller.safeDestination('Android/obb/../../etc/passwd'), isNull);
      expect(XapkInstaller.safeDestination('Android/obb/com.a/x\'; rm -rf /; \''), isNull);
      expect(XapkInstaller.safeDestination('../Android/obb/com.a/x'), isNull);
      expect(XapkInstaller.safeDestination('system/app/x.apk'), isNull);
      expect(XapkInstaller.safeDestination('Android/obb'), isNull);
      expect(XapkInstaller.safeDestination('Android/obb/com.a/\$(id)'), isNull);
    });
  });

  group('instalação com adb de mentira', () {
    late String fake, logPath;
    setUp(() async {
      fake = await writeFakeAdb(dir);
      logPath = p.join(dir.path, 'adb.log');
      await File(logPath).writeAsString('');
    });

    // O adb de mentira lê o caminho do log do ambiente do processo de teste.
    // Process.start herda o ambiente, então definimos via wrapper.
    Future<Adb> adbWithEnv(Map<String, String> env) async {
      final w = File(p.join(dir.path, 'wrap.sh'));
      final exports = env.entries.map((e) => 'export ${e.key}="${e.value}"').join('\n');
      await w.writeAsString('#!/bin/bash\nexport FAKE_ADB_LOG="$logPath"\n$exports\nexec "$fake" "\$@"\n');
      await Process.run('chmod', ['+x', w.path]);
      return Adb(w.path, 'fake:1');
    }

    Uint8List apk(String pkg, {int minSdk = 21, Map<String, List<int>> extra = const {}}) =>
        buildZip({'AndroidManifest.xml': buildAxml(pkg, minSdk: minSdk), 'classes.dex': [1, 2, 3], ...extra});

    Future<List<InstallProgress>> run(Adb a, String xapk) =>
        XapkInstaller(a, workDir: p.join(dir.path, 'work')).install(xapk).toList();

    test('base + partes + OBB: sessão única, bytes certos e progresso crescente', () async {
      final base = apk('com.jogo', extra: {'lib/x86_64/libjogo.so': pattern(2000, 1)});
      final cfg = apk('com.jogo', extra: {'res/idioma.arsc': pattern(500, 2)});
      final arm = apk('com.jogo', extra: {'lib/arm64-v8a/libjogo.so': pattern(900, 3)});
      final obb = pattern(300 * 1024, 4);
      final xapk = await write('jogo.xapk', buildZip({
        'manifest.json': utf8.encode(jsonEncode({
          'package_name': 'com.jogo',
          'split_apks': [
            {'file': 'com.jogo.apk'},
            {'file': 'config.pt.apk'},
            {'file': 'config.arm64_v8a.apk'},
          ],
          'expansions': [
            {'file': 'Android/obb/com.jogo/main.1.obb', 'install_path': 'Android/obb/com.jogo/main.1.obb'}
          ],
        })),
        'com.jogo.apk': base,
        'config.pt.apk': cfg,
        'config.arm64_v8a.apk': arm,
        'Android/obb/com.jogo/main.1.obb': obb,
      }));
      final a = await adbWithEnv({});
      final events = await run(a, xapk);

      expect(events.last.phase, InstallPhase.done, reason: events.last.message);
      final fractions = [for (final e in events) if (e.fraction != null) e.fraction!];
      expect(fractions, isNotEmpty);
      for (var i = 1; i < fractions.length; i++) {
        expect(fractions[i], greaterThanOrEqualTo(fractions[i - 1]));
      }
      expect(fractions.last, closeTo(1.0, 0.001));

      final log = await File(logPath).readAsString();
      // A parte só-ARM é ignorada (há código x86_64): dois APKs na sessão.
      final total = base.length + cfg.length;
      expect(log, contains('pm install-create -r -t -S $total'));
      expect(RegExp(r'pm install-write -S (\d+) 4242 (\S+) -').allMatches(log).length, 2);
      expect(log, contains('-S ${base.length} 4242 0_com.jogo.apk -'));
      expect(log, contains('-S ${cfg.length} 4242 1_config.pt.apk -'));
      expect(log, contains('bytes=${base.length}'));
      expect(log, contains('bytes=${cfg.length}'));
      expect(log, isNot(contains('arm64')));
      expect(log, contains('pm install-commit 4242'));
      // OBB: cópia direta do ZIP para o armazenamento compartilhado.
      expect(log, contains("mkdir -p '/sdcard/Android/obb/com.jogo' && cat > '/sdcard/Android/obb/com.jogo/main.1.obb'"));
      expect(log, contains('bytes=${obb.length}'));
      expect(Directory(p.join(dir.path, 'work')).listSync().whereType<Directory>(), isEmpty,
          reason: 'a pasta temporária deve ser removida');
    });

    test('XAPK somente ARM é recusado antes de qualquer chamada ao adb', () async {
      final xapk = await write('arm.xapk', buildZip({
        'com.arm.apk': apk('com.arm', extra: {'lib/arm64-v8a/liba.so': [0]}),
      }));
      final events = await run(await adbWithEnv({}), xapk);
      expect(events.last.phase, InstallPhase.failed);
      expect(events.last.message, contains('ARM'));
      expect(await File(logPath).readAsString(), isEmpty);
    });

    test('minSdk acima do Android 9 é recusado', () async {
      final xapk = await write('novo.xapk', buildZip({'a.apk': apk('com.novo', minSdk: 33)}));
      final events = await run(await adbWithEnv({}), xapk);
      expect(events.last.phase, InstallPhase.failed);
      expect(events.last.message, contains('33'));
    });

    test('falha ao criar a sessão e ao escrever (com abandono)', () async {
      final xapk = await write('ok.xapk', buildZip({'a.apk': apk('com.ok')}));
      var events = await run(await adbWithEnv({'FAKE_FAIL_CREATE': '1'}), xapk);
      expect(events.last.phase, InstallPhase.failed);
      expect(events.last.message, contains('INSTALL_FAILED_INSUFFICIENT_STORAGE'));

      await File(logPath).writeAsString('');
      events = await run(await adbWithEnv({'FAKE_FAIL_WRITE': '1'}), xapk);
      expect(events.last.phase, InstallPhase.failed);
      expect(await File(logPath).readAsString(), contains('pm install-abandon 4242'));
    });

    test('falha ao copiar o OBB avisa que o app foi instalado', () async {
      final xapk = await write('obb.xapk', buildZip({
        'a.apk': apk('com.obb'),
        'Android/obb/com.obb/main.obb': pattern(1000, 1),
      }));
      final events = await run(await adbWithEnv({'FAKE_FAIL_SH': '1'}), xapk);
      expect(events.last.phase, InstallPhase.failed);
      expect(events.last.message, contains('foi instalado'));
      expect(events.last.message, contains('No space left'));
    });

    test('XAPK corrompido ou com destino inseguro é recusado', () async {
      final bad = await write('x.xapk', utf8.encode('não é zip nenhum, de verdade mesmo'));
      var events = await run(await adbWithEnv({}), bad);
      expect(events.last.phase, InstallPhase.failed);

      final evil = await write('evil.xapk', buildZip({
        'manifest.json': utf8.encode(jsonEncode({
          'expansions': [{'file': 'a.obb', 'install_path': 'Android/obb/../../data/x'}],
        })),
        'a.apk': apk('com.evil'),
        'a.obb': [1],
      }));
      events = await run(await adbWithEnv({}), evil);
      expect(events.last.phase, InstallPhase.failed);
      expect(events.last.message, contains('inseguro'));
      expect(await File(logPath).readAsString(), isEmpty);
    });

    test('tradução ARM: XAPK com partes ARM32 e ARM64 instala só a ARM32', () async {
      final base = apk('com.armjogo');
      final v7 = apk('com.armjogo', extra: {'lib/armeabi-v7a/libj.so': pattern(800, 1)});
      final v8 = apk('com.armjogo', extra: {'lib/arm64-v8a/libj.so': pattern(900, 2)});
      final xapk = await write('armjogo.xapk', buildZip({
        'manifest.json': utf8.encode(jsonEncode({
          'split_apks': [
            {'file': 'base.apk'},
            {'file': 'config.armeabi_v7a.apk'},
            {'file': 'config.arm64_v8a.apk'},
          ],
        })),
        'base.apk': base,
        'config.armeabi_v7a.apk': v7,
        'config.arm64_v8a.apk': v8,
      }));
      final events = await XapkInstaller(await adbWithEnv({}),
              workDir: p.join(dir.path, 'work'), armTranslation: true)
          .install(xapk)
          .toList();
      expect(events.last.phase, InstallPhase.done, reason: events.last.message);
      final log = await File(logPath).readAsString();
      expect(log, contains('pm install-create -r -t -S ${base.length + v7.length}'));
      expect(log, contains('1_config.armeabi_v7a.apk'));
      expect(log, isNot(contains('arm64_v8a.apk -')));

      // Sem a tradução, o mesmo XAPK é recusado pedindo para ativá-la.
      final off = await run(await adbWithEnv({}), xapk);
      expect(off.last.phase, InstallPhase.failed);
      expect(off.last.message, contains('Tradução ARM'));
    });

    test('tradução ARM: XAPK só ARM64 é recusado mesmo com ela ligada', () async {
      final xapk = await write('a64.xapk', buildZip({
        'a.apk': apk('com.a64', extra: {'lib/arm64-v8a/liba.so': [0]}),
      }));
      final events = await XapkInstaller(await adbWithEnv({}),
              workDir: p.join(dir.path, 'work'), armTranslation: true)
          .install(xapk)
          .toList();
      expect(events.last.phase, InstallPhase.failed);
      expect(events.last.message, contains('ARM64'));
      expect(await File(logPath).readAsString(), isEmpty);
    });

    test('tradução ARM: APK só armeabi-v7a é aceito quando ligada', () async {
      final path = await write('v7.apk', apk('com.v7', extra: {'lib/armeabi-v7a/libv.so': [0]}));
      final on = await ApkInstaller(await adbWithEnv({}), armTranslation: true).install(path).toList();
      expect(on.last.phase, InstallPhase.done, reason: on.last.message);
      final off = await ApkInstaller(await adbWithEnv({})).install(path).toList();
      expect(off.last.phase, InstallPhase.failed);
      expect(off.last.message, contains('Tradução ARM'));
    });

    test('ApkInstaller despacha .xapk para o instalador de XAPK', () async {
      final xapk = await write('d.XAPK', buildZip({'a.apk': apk('com.disp')}));
      final events = await ApkInstaller(await adbWithEnv({})).install(xapk).toList();
      expect(events.last.phase, InstallPhase.done, reason: events.last.message);
    });
  });

  test('fila aceita .apk e .xapk em qualquer caixa', () {
    expect(InstallQueue.isInstallable('/a/b.apk'), isTrue);
    expect(InstallQueue.isInstallable('/a/B.XAPK'), isTrue);
    expect(InstallQueue.isInstallable('/a/b.zip'), isFalse);
    expect(InstallQueue.isInstallable('/a/b.apks'), isFalse);
  });

  group('associações de arquivo', () {
    test('execLine entre aspas e escapes da especificação', () {
      expect(FileAssociations.execLine('/opt/secada/secada'), '"/opt/secada/secada" %F');
      expect(FileAssociations.execLine('/home/x/Área de trabalho/secada'),
          '"/home/x/Área de trabalho/secada" %F');
      expect(FileAssociations.execLine(r'/a/b"c$d`e\f'), r'"/a/b\\"c\\$d\\`e\\\\f" %F');
      expect(FileAssociations.execLine('/a/100%/secada'), '"/a/100%%/secada" %F');
    });

    test('a entrada .desktop declara os tipos e recebe os arquivos (%F)', () {
      final d = FileAssociations.desktopEntry(exe: '/opt/secada/secada', icon: '/opt/secada/share/secada.png');
      expect(d, contains('MimeType=application/vnd.android.package-archive;application/x-xapk;'));
      expect(d, contains('Exec="/opt/secada/secada" %F'));
      expect(d, contains('StartupWMClass=dev.secada.secada'));
      expect(d, contains('Icon=/opt/secada/share/secada.png'));
    });

    test('mimeapps.list: acrescenta, preserva o resto e é idempotente', () {
      final merged = FileAssociations.mergeMimeApps('');
      expect(merged, contains('[Default Applications]\napplication/vnd.android.package-archive=secada.desktop;'));
      expect(merged, contains('application/x-xapk=secada.desktop;'));
      expect(merged, contains('[Added Associations]'));
      expect(FileAssociations.mergeMimeApps(merged), merged);

      const current = '''[Default Applications]
text/html=firefox.desktop;
application/vnd.android.package-archive=org.gnome.FileRoller.desktop;secada.desktop;

[Added Associations]
image/png=eog.desktop;

[Outra Secao]
a=b
''';
      final out = FileAssociations.mergeMimeApps(current);
      expect(out, contains('text/html=firefox.desktop;'));
      expect(out, contains('image/png=eog.desktop;'));
      expect(out, contains('[Outra Secao]\na=b'));
      // O SECADA Emulator passa à frente e o antigo continua como alternativa.
      expect(out, contains('application/vnd.android.package-archive=secada.desktop;org.gnome.FileRoller.desktop;'));
      expect(out.split('secada.desktop').length - 1, 4, reason: '2 tipos x 2 seções');
      expect(FileAssociations.mergeMimeApps(out), out);
    });

    test('ensure grava .desktop, MIME e padrão; o padrão só uma vez', () async {
      final data = p.join(dir.path, 'data'), cfg = p.join(dir.path, 'cfg'), marker = p.join(dir.path, 'm');
      Future<void> go() => FileAssociations.ensure(
          exe: '/home/u/.local/opt/secada/secada',
          dataHome: data,
          configHome: cfg,
          markerDir: marker,
          runTools: false);
      await go();
      final desktop = await File(p.join(data, 'applications', 'secada.desktop')).readAsString();
      expect(desktop, contains('Exec="/home/u/.local/opt/secada/secada" %F'));
      expect(await File(p.join(data, 'mime', 'packages', 'secada-xapk.xml')).readAsString(),
          FileAssociations.mimeXml);
      final list = File(p.join(cfg, 'mimeapps.list'));
      expect(await list.readAsString(), contains('application/x-xapk=secada.desktop;'));
      expect(File(p.join(marker, 'associations-v1')).existsSync(), isTrue);

      // O usuário escolhe outro programa depois: não é desfeito.
      await list.writeAsString('[Default Applications]\napplication/x-xapk=outro.desktop;\n');
      await go();
      expect(await list.readAsString(), '[Default Applications]\napplication/x-xapk=outro.desktop;\n');
    });

    test('instalação do sistema não escreve entradas do usuário, só o padrão', () async {
      final data = p.join(dir.path, 'data'), cfg = p.join(dir.path, 'cfg'), marker = p.join(dir.path, 'm');
      await FileAssociations.ensure(
          exe: '/opt/secada/secada', dataHome: data, configHome: cfg, markerDir: marker, runTools: false);
      expect(Directory(p.join(data, 'applications')).existsSync(), isFalse);
      expect(File(p.join(cfg, 'mimeapps.list')).existsSync(), isTrue);
    });

    test('o padrão antigo (Anux) passa ao SECADA sem mexer nas outras escolhas', () {
      const antigo = '''[Default Applications]
text/html=firefox.desktop;
application/vnd.android.package-archive=anux.desktop;
application/x-xapk=outro.desktop;anux.desktop;

[Added Associations]
application/vnd.android.package-archive=org.gnome.FileRoller.desktop;anux.desktop;
''';
      final out = FileAssociations.migrateLegacyMimeApps(antigo);
      expect(out, isNot(contains('anux.desktop')));
      expect(out, contains('application/vnd.android.package-archive=secada.desktop;\n'));
      expect(out, contains('application/x-xapk=secada.desktop;outro.desktop;'));
      expect(out, contains('=secada.desktop;org.gnome.FileRoller.desktop;'));
      expect(out, contains('text/html=firefox.desktop;'));
      expect(FileAssociations.migrateLegacyMimeApps(out), out);
      // Quem escolheu outro programa continua com ele.
      const outro = '[Default Applications]\napplication/x-xapk=outro.desktop;\n';
      expect(FileAssociations.migrateLegacyMimeApps(outro), outro);
    });

    test('ensure migra do Anux mesmo com o marcador antigo já gravado', () async {
      final data = p.join(dir.path, 'data'), cfg = p.join(dir.path, 'cfg'), marker = p.join(dir.path, 'm');
      await Directory(p.join(data, 'applications')).create(recursive: true);
      await Directory(p.join(data, 'mime', 'packages')).create(recursive: true);
      await Directory(marker).create(recursive: true);
      await Directory(cfg).create(recursive: true);
      await File(p.join(marker, 'associations-v1')).writeAsString('herdado do Anux');
      await File(p.join(data, 'applications', 'anux.desktop'))
          .writeAsString('[Desktop Entry]\nName=Anux\nMimeType=application/x-xapk;\n');
      await File(p.join(data, 'mime', 'packages', 'anux-xapk.xml')).writeAsString('<x/>');
      await File(p.join(cfg, 'mimeapps.list')).writeAsString(
          '[Default Applications]\napplication/vnd.android.package-archive=anux.desktop;\n');
      await FileAssociations.ensure(
          exe: '/home/u/secada/secada', dataHome: data, configHome: cfg, markerDir: marker, runTools: false);
      expect(await File(p.join(cfg, 'mimeapps.list')).readAsString(),
          contains('application/vnd.android.package-archive=secada.desktop;'));
      expect(await File(p.join(cfg, 'mimeapps.list')).readAsString(), isNot(contains('anux.desktop')));
      final legacy = await File(p.join(data, 'applications', 'anux.desktop')).readAsString();
      expect(legacy, contains('Name=Anux'));
      expect(legacy, isNot(contains('MimeType')));
      expect(File(p.join(data, 'mime', 'packages', 'anux-xapk.xml')).existsSync(), isFalse);
    });

    test('o XML do pacote é o mesmo que o app grava', () {
      expect(File('../packaging/secada-xapk.xml').readAsStringSync(), FileAssociations.mimeXml);
    });
  });
}
