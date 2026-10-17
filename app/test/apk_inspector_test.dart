import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:secada/src/android/adb.dart';
import 'package:secada/src/android/apk_inspector.dart';
import 'package:secada/src/android/apk_installer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'zip_helpers.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('secada-apk'));
  tearDown(() => dir.delete(recursive: true));

  Future<String> write(String name, Uint8List bytes) async {
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes);
    return f.path;
  }

  test('lê pacote, versão e minSdk de um APK sem código nativo', () async {
    final path = await write('a.apk', buildZip({
      'AndroidManifest.xml': buildAxml('com.exemplo.app', version: '2.5', minSdk: 23),
      'classes.dex': [1, 2, 3],
    }));
    final info = await ApkInspector.inspect(path);
    expect(info.packageName, 'com.exemplo.app');
    expect(info.versionName, '2.5');
    expect(info.minSdk, 23);
    expect(info.nativeAbis, isEmpty);
    expect(info.armOnly, isFalse);
  });

  test('detecta APK somente ARM (incompatível)', () async {
    final path = await write('arm.apk', buildZip({
      'AndroidManifest.xml': buildAxml('com.exemplo.arm'),
      'lib/armeabi-v7a/libnativo.so': [0x7f, 0x45, 0x4c, 0x46],
      'lib/arm64-v8a/libnativo.so': [0x7f, 0x45, 0x4c, 0x46],
    }));
    final info = await ApkInspector.inspect(path);
    expect(info.nativeAbis, {'armeabi-v7a', 'arm64-v8a'});
    expect(info.armOnly, isTrue);
  });

  test('APK universal com x86_64 é compatível', () async {
    final path = await write('uni.apk', buildZip({
      'AndroidManifest.xml': buildAxml('com.exemplo.uni'),
      'lib/armeabi-v7a/libn.so': [0],
      'lib/x86_64/libn.so': [0],
    }));
    expect((await ApkInspector.inspect(path)).armOnly, isFalse);
  });

  test('arquivo que não é APK gera erro compreensível', () async {
    final path = await write('x.apk', Uint8List.fromList(utf8.encode('não sou um zip')));
    expect(() => ApkInspector.inspect(path), throwsA(isA<ApkFormatError>()));
    final noManifest = await write('y.apk', buildZip({'classes.dex': [1]}));
    expect(
      () => ApkInspector.inspect(noManifest),
      throwsA(isA<ApkFormatError>().having((e) => e.message, 'msg', contains('AndroidManifest'))),
    );
  });

  test('instalador recusa ARM-only e minSdk > 28 antes de enviar', () async {
    final arm = await write('arm.apk', buildZip({
      'AndroidManifest.xml': buildAxml('com.exemplo.arm'),
      'lib/armeabi-v7a/libn.so': [0],
    }));
    final newer = await write('new.apk', buildZip({
      'AndroidManifest.xml': buildAxml('com.exemplo.novo', minSdk: 33),
    }));
    // Adb inválido: se o instalador tentasse executar, o teste falharia.
    final installer = ApkInstaller(Adb('/nao/existe/adb', '127.0.0.1:1'));
    final a = await installer.install(arm).last;
    expect(a.phase, InstallPhase.failed);
    expect(a.message, contains('ARM'));
    final b = await installer.install(newer).last;
    expect(b.phase, InstallPhase.failed);
    expect(b.message, contains('API 33'));
  });

  test('mensagens de falha do PackageManager', () {
    expect(describeInstallFailure('Failure [INSTALL_FAILED_NO_MATCHING_ABIS: x]', 1),
        contains('x86-64'));
    expect(describeInstallFailure('Failure [INSTALL_FAILED_OLDER_SDK]', 1),
        contains('Android 9'));
    expect(describeInstallFailure('Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]', 1),
        contains('assinatura'));
    expect(describeInstallFailure('error: device offline', 1), contains('ADB'));
  });

  final realApk = '${Platform.environment['HOME']}/Downloads/secada-test-apks/opencamera.apk';
  test('APK real (Open Camera, F-Droid)', () async {
    final info = await ApkInspector.inspect(realApk);
    expect(info.packageName, 'net.sourceforge.opencamera');
    expect(info.armOnly, isFalse);
  }, skip: !File(realApk).existsSync() ? 'APK de teste não baixado' : false);
}

