import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'paths.dart';

/// Log de diagnóstico do aplicativo, gravado em `~/.local/share/secada/logs`.
///
/// Mantém também as últimas linhas em memória para exibição na interface.
class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  IOSink? _sink;
  final List<String> recent = <String>[];
  String? path;

  Future<void> init() async {
    final dir = Directory(SecadaPaths.instance.logsDir);
    await dir.create(recursive: true);
    path = p.join(dir.path, 'secada.log');
    final file = File(path!);
    // Rotação simples: mantém o log anterior como secada.log.1.
    if (await file.exists() && await file.length() > 2 * 1024 * 1024) {
      await file.rename('${path!}.1');
    }
    _sink = File(path!).openWrite(mode: FileMode.append);
    info('==== SECADA Emulator iniciado (pid $pid) ====');
  }

  void info(String message) => _write('INFO', message);
  void warn(String message) => _write('WARN', message);
  void error(String message, [Object? error, StackTrace? stack]) {
    _write('ERRO', error == null ? message : '$message: $error');
    if (stack != null) _write('ERRO', stack.toString());
  }

  void _write(String level, String message) {
    final line = '${DateTime.now().toIso8601String()} [$level] $message';
    recent.add(line);
    if (recent.length > 500) recent.removeRange(0, recent.length - 500);
    _sink?.writeln(line);
    if (kDebugMode) debugPrint(line);
  }

  Future<void> close() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
  }
}

final log = AppLog.instance;
