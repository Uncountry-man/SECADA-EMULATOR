import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/app_log.dart';

/// Cliente do QEMU Machine Protocol sobre socket UNIX local.
class QmpClient {
  QmpClient._(this._socket) {
    _sub = _socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: _onDone, onError: (_) => _onDone());
  }

  final Socket _socket;
  late final StreamSubscription<String> _sub;
  final _pending = <int, Completer<Object?>>{};
  final _events = StreamController<Map<String, Object?>>.broadcast();
  final _greeting = Completer<void>();
  int _nextId = 1;
  bool _closed = false;

  /// Eventos assíncronos (SHUTDOWN, RESET, STOP, POWERDOWN...).
  Stream<Map<String, Object?>> get events => _events.stream;
  bool get isClosed => _closed;

  /// Conecta, tentando novamente até [timeout] (o QEMU cria o socket alguns
  /// milissegundos após iniciar).
  static Future<QmpClient> connect(String path,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final deadline = DateTime.now().add(timeout);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final socket = await Socket.connect(
            InternetAddress(path, type: InternetAddressType.unix), 0);
        final client = QmpClient._(socket);
        await client._greeting.future.timeout(const Duration(seconds: 5));
        await client.execute('qmp_capabilities');
        return client;
      } catch (e) {
        lastError = e;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    throw StateError('QMP indisponível em $path: $lastError');
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    final Map<String, Object?> msg;
    try {
      msg = Map<String, Object?>.from(jsonDecode(line) as Map);
    } catch (_) {
      return;
    }
    if (msg.containsKey('QMP')) {
      if (!_greeting.isCompleted) _greeting.complete();
    } else if (msg.containsKey('event')) {
      _events.add(msg);
    } else {
      final id = msg['id'];
      final c = id is int ? _pending.remove(id) : null;
      if (c == null) {
        if (id == null && msg.containsKey('error') && _ignoredErrors++ < 3) {
          log.warn('QMP (sem resposta esperada): ${msg['error']}');
        }
        return;
      }
      if (msg.containsKey('error')) {
        final err = msg['error'] as Map;
        c.completeError(QmpError('${err['class']}', '${err['desc']}'));
      } else {
        c.complete(msg['return']);
      }
    }
  }

  void _onDone() {
    if (_closed) return;
    _closed = true;
    for (final c in _pending.values) {
      c.completeError(StateError('Conexão QMP encerrada'));
    }
    _pending.clear();
    _events.close();
  }

  Future<Object?> execute(String command,
      {Map<String, Object?>? arguments,
      Duration timeout = const Duration(seconds: 10)}) {
    if (_closed) return Future.error(StateError('QMP fechado'));
    final id = _nextId++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _socket.write('${jsonEncode({
          'execute': command,
          'arguments': ?arguments,
          'id': id,
        })}\n');
    return c.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw TimeoutException('QMP $command sem resposta', timeout);
    });
  }

  int _ignoredErrors = 0;

  /// Envia um comando sem esperar a resposta (entrada em tempo real, como os
  /// toques do mapeador). Erros do QEMU só são registrados nas primeiras vezes.
  void send(String command, Map<String, Object?> arguments) {
    if (_closed) return;
    _socket.write('${jsonEncode({'execute': command, 'arguments': arguments})}\n');
  }

  Future<void> close() async {
    await _sub.cancel();
    _socket.destroy();
    _onDone();
  }
}

class QmpError implements Exception {
  QmpError(this.errorClass, this.description);
  final String errorClass;
  final String description;
  @override
  String toString() => 'QMP $errorClass: $description';
}
