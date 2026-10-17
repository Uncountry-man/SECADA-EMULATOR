import 'dart:io';

import 'package:secada/src/android/apk_inspector.dart';
import 'package:secada/src/android/arm_translation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('AbiPolicy', () {
    test('sem código nativo ou com x86 roda direto', () {
      expect(AbiPolicy.rejection({}, armTranslation: false), isNull);
      expect(AbiPolicy.rejection({'x86_64', 'arm64-v8a'}, armTranslation: false), isNull);
      expect(AbiPolicy.rejection({'x86'}, armTranslation: false), isNull);
      expect(AbiPolicy.needsTranslation({'x86', 'armeabi-v7a'}), isFalse);
    });

    test('ARM 32 bits precisa da tradução', () {
      expect(AbiPolicy.needsTranslation({'armeabi-v7a', 'arm64-v8a'}), isTrue);
      expect(AbiPolicy.rejection({'armeabi-v7a', 'arm64-v8a'}, armTranslation: true), isNull);
      expect(AbiPolicy.rejection({'armeabi'}, armTranslation: true), isNull);
      expect(AbiPolicy.rejection({'armeabi-v7a'}, armTranslation: false), contains('Tradução ARM'));
    });

    test('só ARM64 precisa do tradutor de 64 bits; ABIs estranhas são recusadas', () {
      expect(AbiPolicy.rejection({'arm64-v8a'}, armTranslation: true), contains('ARM64'));
      expect(AbiPolicy.rejection({'arm64-v8a'}, armTranslation: true, arm64: true), isNull);
      expect(AbiPolicy.rejection({'arm64-v8a'}, armTranslation: false, arm64: true),
          contains('Tradução ARM'));
      expect(AbiPolicy.rejection({'mips'}, armTranslation: true), contains('não suportadas'));
    });

    test('tradutor ARM64 exige squashfs no caminho indicado', () async {
      final dir = await Directory.systemTemp.createTemp('secada-arm64');
      addTearDown(() => dir.delete(recursive: true));
      final f = File(p.join(dir.path, Arm64Translation.fileName));
      expect(await Arm64Translation.isAvailable(f.path), isFalse);
      f.writeAsBytesSync([...'hsqs'.codeUnits, ...List.filled(2 * 1024 * 1024, 0)]);
      expect(await Arm64Translation.isAvailable(f.path), isTrue);
      f.writeAsBytesSync(List.filled(2 * 1024 * 1024, 0));
      expect(await Arm64Translation.isAvailable(f.path), isFalse);
    });
  });

  group('download do tradutor', () {
    late Directory dir;
    late HttpServer server;
    late List<int> body;
    late String sha;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('secada-arm');
      body = List<int>.generate(300 * 1024, (i) => (i * 13 + 5) & 0xff);
      final f = File(p.join(dir.path, 'ref.bin'))..writeAsBytesSync(body);
      sha = ((await Process.run('sha256sum', [f.path])).stdout as String).split(' ').first;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        switch (req.uri.path) {
          case '/ok':
            req.response.add(body);
          case '/redir':
            req.response
              ..statusCode = 302
              ..headers.set('location', '/ok');
          case '/curto':
            req.response.add(body.sublist(0, 1000));
          default:
            req.response.statusCode = 404;
        }
        await req.response.close();
      });
    });
    tearDown(() async {
      await server.close(force: true);
      await dir.delete(recursive: true);
    });

    String url(String path) => 'http://127.0.0.1:${server.port}$path';

    test('baixa, segue redirecionamento, confere e reaproveita', () async {
      final dest = p.join(dir.path, 'out', 'h.sfs');
      final progress = <double>[];
      final got = await ArmTranslation.ensureDownloaded(
        sources: [url('/nao-existe'), url('/redir')],
        dest: dest,
        expectedSha256: sha,
        expectedSize: body.length,
        onProgress: progress.add,
      );
      expect(got, dest);
      expect(await File(dest).readAsBytes(), body);
      expect(progress.last, 1.0);
      expect(File('$dest.part').existsSync(), isFalse);
      // Já baixado: não acessa a rede.
      final okUrl = url('/ok');
      await server.close(force: true);
      expect(await ArmTranslation.ensureDownloaded(
          sources: [okUrl], dest: dest, expectedSha256: sha, expectedSize: body.length), dest);
    });

    test('tamanho ou SHA-256 errado é recusado e nada fica no disco', () async {
      final dest = p.join(dir.path, 'h.sfs');
      await expectLater(
        ArmTranslation.ensureDownloaded(
            sources: [url('/curto')], dest: dest, expectedSha256: sha, expectedSize: body.length),
        throwsA(isA<ArmTranslationError>()),
      );
      await expectLater(
        ArmTranslation.ensureDownloaded(
            sources: [url('/ok')], dest: dest, expectedSha256: '0' * 64, expectedSize: body.length),
        throwsA(isA<ArmTranslationError>().having((e) => e.message, 'msg', contains('SHA-256'))),
      );
      expect(File(dest).existsSync(), isFalse);
      expect(File('$dest.part').existsSync(), isFalse);
    });
  });
}
