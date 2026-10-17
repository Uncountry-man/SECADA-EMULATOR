import 'dart:io';

import 'package:secada/src/vm/initrd_overlay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('cpio newc legível pelo cpio do sistema', () async {
    final dir = await Directory.systemTemp.createTemp('secada-cpio');
    addTearDown(() => dir.delete(recursive: true));
    final archive = File(p.join(dir.path, 'a.cpio'))
      ..writeAsBytesSync(buildNewcCpio(const [OverlayFile('scripts/99-x', 'echo oi\n')]));
    expect(archive.lengthSync() % 4, 0);
    final out = Directory(p.join(dir.path, 'out'))..createSync();
    final r = await Process.run('sh', ['-c', 'cpio -idm --quiet < ${archive.path}'],
        workingDirectory: out.path);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final f = File(p.join(out.path, 'scripts', '99-x'));
    expect(f.readAsStringSync(), 'echo oi\n');
    expect(f.statSync().modeString(), 'rwxr-xr-x');
  });

  test('sem ARM64 usa o initrd original; com ARM64 anexa o script', () async {
    final dir = await Directory.systemTemp.createTemp('secada-initrd');
    addTearDown(() => dir.delete(recursive: true));
    final orig = File(p.join(dir.path, 'initrd.img'))
      ..writeAsBytesSync(gzip.encode(buildNewcCpio(const [OverlayFile('init', '#!/bin/sh\n')])) +
          [0]); // tamanho não múltiplo de 4
    expect(await InitrdOverlay.prepare(orig.path, arm64: false), orig.path);

    final path = await InitrdOverlay.prepare(orig.path, arm64: true);
    expect(path, isNot(orig.path));
    final bytes = File(path).readAsBytesSync();
    final origLen = orig.lengthSync();
    expect(bytes.sublist(0, origLen), orig.readAsBytesSync());
    final start = (origLen + 3) & ~3;
    expect(bytes.sublist(origLen, start).every((b) => b == 0), isTrue);
    final cpio = gzip.decode(bytes.sublist(start));
    final listing = File(p.join(dir.path, 'o.cpio'))..writeAsBytesSync(cpio);
    final r = await Process.run('sh', ['-c', 'cpio -it --quiet < ${listing.path}']);
    expect((r.stdout as String).split('\n'), containsAll(['scripts', 'scripts/99-secada-arm64']));
  });

  test('script ARM64 declara as ABIs e o serviço de 64 bits', () {
    const s = InitrdOverlay.arm64Script;
    expect(s, contains('ro.product.cpu.abilist64=x86_64,arm64-v8a'));
    expect(s, contains('ro.product.cpu.abilist=x86_64,x86,arm64-v8a,armeabi-v7a,armeabi'));
    expect(s, contains('service nativebridge64 /system/bin/enable_nativebridge 64'));
    expect(s, contains('/android/default.prop'));
  });
}
