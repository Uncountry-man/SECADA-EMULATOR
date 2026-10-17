import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/paths.dart';
import '../vm/qemu_locator.dart';

class AdbError implements Exception {
  AdbError(this.message);
  final String message;
  @override
  String toString() => message;
}

class AdbResult {
  AdbResult(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final String stdout;
  final String stderr;
  bool get ok => exitCode == 0;
  String get text => stdout.replaceAll('\r', '').trim();
}

/// Cliente do Android Debug Bridge para um dispositivo TCP local.
class Adb {
  Adb(this.adbPath, this.serial);

  final String adbPath;

  /// `127.0.0.1:<porta>` — nunca exposto fora do host.
  final String serial;

  static Future<String?> locate(String configured) async {
    if (configured.isNotEmpty && await File(configured).exists()) {
      return configured;
    }
    for (final c in [
      p.join(SecadaPaths.bundleDir, 'runtime', 'platform-tools', 'adb'),
      p.join(SecadaPaths.instance.dataDir, 'runtime', 'platform-tools', 'adb'),
    ]) {
      if (await File(c).exists()) return c;
    }
    return QemuLocator.which('adb');
  }

  Future<AdbResult> run(List<String> args,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final proc = await Process.start(adbPath, args);
    final out = proc.stdout.transform(utf8.decoder).join();
    final err = proc.stderr.transform(utf8.decoder).join();
    final code = await proc.exitCode.timeout(timeout, onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      return -1;
    });
    return AdbResult(code, await out, await err);
  }

  Future<AdbResult> runOnDevice(List<String> args,
          {Duration timeout = const Duration(seconds: 20)}) =>
      run(['-s', serial, ...args], timeout: timeout);

  Future<AdbResult> shell(String command,
          {Duration timeout = const Duration(seconds: 20)}) =>
      runOnDevice(['shell', command], timeout: timeout);

  /// Executa `adb shell <args>` enviando [data] pelo stdin (protocolo shell v2
  /// do adbd: binário-seguro). [onBytes] recebe o tamanho de cada bloco já
  /// entregue ao adb, para exibir progresso real. Falhas de transporte
  /// (adb encerrado no meio) viram um resultado com código -1.
  Future<AdbResult> shellStreaming(List<String> args, Stream<List<int>> data,
      {void Function(int bytes)? onBytes,
      Duration timeout = const Duration(minutes: 30)}) async {
    final proc = await Process.start(adbPath, ['-s', serial, 'shell', ...args]);
    final out = proc.stdout.transform(utf8.decoder).join();
    final err = proc.stderr.transform(utf8.decoder).join();
    var transportError = '';
    try {
      await for (final chunk in data) {
        proc.stdin.add(chunk);
        await proc.stdin.flush();
        onBytes?.call(chunk.length);
      }
    } on SocketException catch (e) {
      transportError = 'conexão com o adb encerrada: ${e.message}';
    } on IOException catch (e) {
      transportError = '$e';
    } catch (_) {
      proc.kill();
      rethrow;
    }
    try {
      await proc.stdin.close();
    } catch (_) {}
    final code = await proc.exitCode.timeout(timeout, onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      return -1;
    });
    final stderrText = await err;
    return AdbResult(transportError.isEmpty ? code : -1, await out,
        transportError.isEmpty ? stderrText : '$transportError\n$stderrText');
  }

  Future<void> startServer() async {
    await run(['start-server'], timeout: const Duration(seconds: 15));
  }

  Future<bool> connect() async {
    final r = await run(['connect', serial], timeout: const Duration(seconds: 5));
    return r.stdout.contains('connected to');
  }

  Future<void> disconnect() async {
    await run(['disconnect', serial], timeout: const Duration(seconds: 5));
  }

  /// Estado do dispositivo segundo o servidor ADB: "device", "offline"...
  Future<String> state() async {
    final r = await run(['devices'], timeout: const Duration(seconds: 5));
    for (final line in const LineSplitter().convert(r.stdout)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2 && parts[0] == serial) return parts[1];
    }
    return 'absent';
  }

  Future<String> getProp(String name) async {
    final r = await shell('getprop $name', timeout: const Duration(seconds: 5));
    return r.ok ? r.text : '';
  }

  Future<void> keyEvent(int keycode) async {
    await shell('input keyevent $keycode', timeout: const Duration(seconds: 8));
  }
}
