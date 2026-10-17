import 'dart:io';

import 'package:secada/src/vm/android_image.dart';
import 'package:secada/src/vm/iso9660.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final iso = '${Platform.environment['HOME']}/.local/share/secada/images/android-x86_64-9.0-r2.iso';
  final skip = File(iso).existsSync() ? false : 'ISO do Android-x86 não encontrada';

  test('lista a raiz da ISO do Android-x86', () async {
    final img = await Iso9660.open(iso);
    addTearDown(img.close);
    for (final f in AndroidImageManager.requiredFiles) {
      expect(img.find(f), isNotNull, reason: f);
    }
    expect(img.volumeId, contains('Android-x86'));
  }, skip: skip);

  test('extrai kernel/initrd e valida kernel x86-64', () async {
    final dir = await Directory.systemTemp.createTemp('secada-iso');
    addTearDown(() => dir.delete(recursive: true));
    final image = await AndroidImageManager.prepare(iso, dir.path);
    final kernel = await File(image.kernelPath).readAsBytes();
    expect(String.fromCharCodes(kernel.sublist(0x202, 0x206)), 'HdrS');
    expect(await File(image.initrdPath).length(), greaterThan(100000));
  }, skip: skip);

  test('arquivo que não é ISO gera ImageError', () async {
    final f = File('${Directory.systemTemp.path}/secada-nao-iso.iso');
    await f.writeAsBytes(List.filled(40000, 7));
    addTearDown(f.delete);
    expect(() => AndroidImageManager.prepare(f.path, Directory.systemTemp.path),
        throwsA(isA<ImageError>()));
  });
}
