import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/app_log.dart';
import 'adb.dart';

/// Descobre quando um app do Android pede a trava do ponteiro (jogo com a câmera
/// seguindo o mouse, como `View.requestPointerCapture`) para que a janela do
/// emulador prenda o cursor do computador dentro dela.
///
/// O protocolo é só texto no logcat, na etiqueta [tag]: o app escreve `lock <n>` **pelo
/// menos a cada segundo** (n muda a cada linha) enquanto estiver com o mouse preso e `unlock`
/// ao soltar (`Log.i("SecadaPointerLock", "lock 17")`). Se o `lock` para de chegar por
/// [expiry] (app fechado, travado, Android reiniciado, linha perdida) o estado volta a
/// "solto" sozinho: o emulador nunca fica com estado velho e o cursor nunca fica
/// preso por engano.
class PointerLockWatcher {
  PointerLockWatcher({this.onChanged});

  static const tag = 'SecadaPointerLock';

  /// Tempo sem um `lock` novo até considerar o mouse solto.
  static const expiry = Duration(milliseconds: 3500);

  /// Chamado quando o estado muda.
  void Function(bool locked)? onChanged;

  bool _locked = false;
  bool get locked => _locked;

  Process? _proc;
  StreamSubscription<String>? _sub;
  Timer? _expiryTimer;
  DateTime _lastLock = DateTime.fromMillisecondsSinceEpoch(0);
  Adb? _adb;

  /// O `logcat -T 1` repete a última linha antiga ao conectar: um `lock` velho não vale.
  DateTime _ignoreLockUntil = DateTime.fromMillisecondsSinceEpoch(0);

  bool get running => _proc != null;

  /// `lock` ou `lock <n>` -> true, `unlock` -> false, qualquer outra linha -> null.
  ///
  /// O número é do batimento: o logd do Android suprime linhas **idênticas** repetidas
  /// ("chatty: identical N lines"), então um batimento sempre igual some depois das primeiras
  /// repetições e o emulador soltaria o cursor sozinho. Cada batimento deve ter texto único.
  static bool? parseLine(String line) {
    final t = line.replaceAll('\r', '').trim();
    if (t == 'lock' || t.startsWith('lock ')) return true;
    if (t == 'unlock') return false;
    return null;
  }

  void _set(bool v) {
    if (_locked == v) return;
    _locked = v;
    onChanged?.call(v);
  }

  /// Começa a escutar (se ainda não estiver escutando este [adb]).
  Future<void> ensureRunning(Adb adb) async {
    if (_proc != null && identical(_adb, adb)) return;
    stop();
    _adb = adb;
    try {
      final proc = await Process.start(adb.adbPath, [
        '-s', adb.serial, 'logcat', '-T', '1', '-v', 'raw', '$tag:I', '*:S', //
      ]);
      _proc = proc;
      _ignoreLockUntil = DateTime.now().add(const Duration(milliseconds: 600));
      _sub = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onLine);
      proc.stderr.drain<void>();
      proc.exitCode.then((_) {
        if (!identical(_proc, proc)) return;
        _proc = null;
        _sub?.cancel();
        _sub = null;
        _expiryTimer?.cancel();
        _expiryTimer = null;
        _set(false);
      });
      _expiryTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _expire());
    } catch (e) {
      log.warn('Trava do ponteiro: não foi possível ler o logcat: $e');
      stop();
    }
  }

  void _onLine(String line) => feed(line, DateTime.now());

  void _expire() => tick(DateTime.now());

  /// Processa uma linha do logcat (separado para teste).
  @visibleForTesting
  void feed(String line, DateTime now) {
    final v = parseLine(line);
    if (v == null) return;
    if (v) {
      if (now.isBefore(_ignoreLockUntil)) return;
      _lastLock = now;
    }
    _set(v);
  }

  /// Expira o `lock` que parou de ser repetido (separado para teste).
  @visibleForTesting
  void tick(DateTime now) {
    if (_locked && now.difference(_lastLock) > expiry) _set(false);
  }

  void stop() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _sub?.cancel();
    _sub = null;
    _proc?.kill();
    _proc = null;
    _adb = null;
    _set(false);
  }
}
