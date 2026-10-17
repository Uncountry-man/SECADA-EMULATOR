import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/app_log.dart';

class GuestShellResult {
  GuestShellResult(this.exitCode, this.output);
  final int exitCode;
  final String output;
  bool get ok => exitCode == 0;
}

/// Shell root do Android pelo console serial da VM (ttyS0).
///
/// O Android-x86 abre um shell root no console desde o início do boot. O QEMU
/// expõe a serial num socket UNIX privado (0700), então este canal funciona
/// antes de existir rede — é usado para detectar o boot e provisionar o
/// sistema (Wi-Fi, idioma, bateria...). O ADB fica para instalação de APKs.
///
/// Protocolo: cada comando é cercado por marcadores. O terminal ecoa a linha
/// digitada antes de executá-la, então tudo antes do marcador de início
/// (`__SECADA_B<n>__`) é descartado; o marcador final traz o código de saída.
class GuestShell {
  GuestShell._(this.path);

  /// Caminho do socket da serial; a conexão é refeita sozinha se cair (por
  /// exemplo, se o QEMU resetar o chardev durante a inicialização).
  final String path;
  Socket? _socket;
  final StringBuffer _buffer = StringBuffer();
  Completer<void>? _wake;
  bool _closed = false;
  int _seq = 0;
  Future<void> _queue = Future<void>.value();

  bool get isClosed => _closed;

  static Future<GuestShell> connect(String path,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final shell = GuestShell._(path);
    if (!await shell._ensureConnected(timeout)) {
      throw StateError('Console serial indisponível em $path');
    }
    return shell;
  }

  Future<bool> _ensureConnected(Duration timeout) async {
    if (_socket != null) return true;
    final deadline = DateTime.now().add(timeout);
    while (!_closed && DateTime.now().isBefore(deadline)) {
      try {
        final s = await Socket.connect(
            InternetAddress(path, type: InternetAddressType.unix), 0);
        _attach(s);
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    return false;
  }

  void _attach(Socket s) {
    _socket = s;
    void drop() {
      if (identical(_socket, s)) _socket = null;
      _wake?.complete();
      _wake = null;
    }

    s.done.catchError((_) {}).whenComplete(drop);
    s
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((data) {
      _buffer.write(data);
      _wake?.complete();
      _wake = null;
    }, onDone: drop, onError: (_) => drop(), cancelOnError: true);
  }

  Future<void> _waitData(Duration d) async {
    if (_closed) return;
    _wake ??= Completer<void>();
    await _wake!.future.timeout(d, onTimeout: () {});
  }

  /// Aguarda até o shell do console responder (pode levar alguns segundos
  /// após o início do kernel).
  Future<bool> waitReady({Duration timeout = const Duration(seconds: 120)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!_closed && DateTime.now().isBefore(deadline)) {
      final r = await run('echo ok', timeout: const Duration(seconds: 3));
      if (r != null && r.output.contains('ok')) return true;
    }
    return false;
  }

  /// Executa [command] como root. Retorna null em timeout ou desconexão.
  Future<GuestShellResult?> run(String command,
      {Duration timeout = const Duration(seconds: 20)}) {
    final c = Completer<GuestShellResult?>();
    _queue = _queue.then((_) async {
      try {
        c.complete(await _run(command, timeout));
      } catch (e) {
        c.complete(null);
      }
    });
    return c.future;
  }

  Future<GuestShellResult?> _run(String command, Duration timeout) async {
    if (_closed) return null;
    if (!await _ensureConnected(const Duration(seconds: 3))) return null;
    final n = ++_seq;
    final begin = '__SECADA_B${n}__';
    final end = RegExp('__SECADA_E${n}_(\\d+)__');
    _buffer.clear();
    // O marcador de início é montado na execução ("B" "n") para que o eco da
    // própria linha não contenha o texto exato.
    try {
      _socket!.write('echo "__SECADA_""B${n}__"; $command; echo "__SECADA_E${n}_\$?__"\n');
    } catch (_) {
      _socket = null;
      return null;
    }
    final deadline = DateTime.now().add(timeout);
    while (!_closed && _socket != null && DateTime.now().isBefore(deadline)) {
      final text = _buffer.toString();
      final m = end.firstMatch(text);
      if (m != null) {
        var body = text.substring(0, m.start);
        final b = body.lastIndexOf(begin);
        body = b >= 0 ? body.substring(b + begin.length) : body;
        final out = body.replaceAll('\r', '').trim();
        return GuestShellResult(int.parse(m.group(1)!), out);
      }
      await _waitData(deadline.difference(DateTime.now()));
    }
    if (_closed) return null;
    log.warn('Console: tempo esgotado em "$command"');
    return null;
  }

  Future<String> getProp(String name) async =>
      (await run('getprop $name', timeout: const Duration(seconds: 5)))?.output.trim() ?? '';

  Future<void> close() async {
    _closed = true;
    _socket?.destroy();
    _socket = null;
  }
}
