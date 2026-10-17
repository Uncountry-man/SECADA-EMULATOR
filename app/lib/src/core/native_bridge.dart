import 'dart:async';

import 'package:flutter/services.dart';

/// Evento emitido pelo backend nativo (C++).
class NativeEvent {
  NativeEvent(this.type, this.data);
  final String type;
  final Map<String, Object?> data;

  @override
  String toString() => 'NativeEvent($type, $data)';
}

/// Ponte para o backend nativo em `linux/secada_core`.
///
/// Concentra todas as chamadas do canal `dev.secada/core`, para que o restante
/// da aplicação nunca dependa de nomes de métodos em texto.
class NativeBridge {
  NativeBridge._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onEvent') {
        final map = Map<String, Object?>.from(call.arguments as Map);
        _events.add(NativeEvent(map['type'] as String, map));
      }
      return null;
    });
  }

  static final NativeBridge instance = NativeBridge._();

  static const MethodChannel _channel = MethodChannel('dev.secada/core');
  final StreamController<NativeEvent> _events =
      StreamController<NativeEvent>.broadcast();

  Stream<NativeEvent> get events => _events.stream;

  Stream<NativeEvent> eventsOf(String type) =>
      events.where((e) => e.type == type);

  /// Avisa o backend que a interface já escuta os eventos. Devolve os
  /// arquivos (APK/XAPK) recebidos pela linha de comando antes disso; os
  /// seguintes chegam como evento `openFiles`.
  Future<List<String>> appReady() async {
    final r = await _channel.invokeMethod<List<Object?>>('app.ready');
    return [for (final p in r ?? const <Object?>[]) '$p'];
  }

  // ------------------------------------------------------------ host / VM
  Future<Map<String, Object?>> probeHost() async {
    final r = await _channel.invokeMethod<Map>('host.probe');
    return Map<String, Object?>.from(r ?? const {});
  }

  /// Inicia o QEMU. Retorna o PID. Lança [PlatformException] em erro.
  Future<int> startVm({
    required List<String> argv,
    required Map<String, String> env,
    required String logPath,
  }) async {
    final pid = await _channel.invokeMethod<int>('vm.start', {
      'argv': argv,
      'env': env,
      'logPath': logPath,
    });
    return pid ?? -1;
  }

  Future<bool> signalVm(int signal) async =>
      await _channel.invokeMethod<bool>('vm.signal', {'signal': signal}) ??
      false;

  Future<bool> isVmRunning() async =>
      await _channel.invokeMethod<bool>('vm.isRunning') ?? false;

  // -------------------------------------------------------------- display
  /// Conecta o display: RFB em [socketPath] e, com VirGL, também o display
  /// D-Bus do QEMU ([dbusQmpSocket] + [renderNode]), que passa a fornecer a
  /// imagem e a receber a entrada assim que entrega o primeiro quadro.
  Future<int> connectDisplay(String socketPath,
      {int timeoutMs = 30000,
      bool swapRedBlue = false,
      String? dbusQmpSocket,
      String? renderNode}) async {
    final id = await _channel.invokeMethod<int>('display.connect', {
      'socketPath': socketPath,
      'timeoutMs': timeoutMs,
      'swapRedBlue': swapRedBlue,
      'dbusQmpSocket': ?dbusQmpSocket,
      'renderNode': ?renderNode,
    });
    return id ?? -1;
  }

  Future<void> disconnectDisplay() =>
      _channel.invokeMethod<void>('display.disconnect');

  Future<void> refreshDisplay() => _channel.invokeMethod<void>('display.refresh');

  // ---------------------------------------------------------------- input
  /// Move o cursor do sistema para ([x], [y]) em pixels lógicos da janela.
  Future<bool> warpPointer(int x, int y) async =>
      await _channel.invokeMethod<bool>('input.warpPointer', {'x': x, 'y': y}) ?? false;

  void sendPointer(int x, int y, int buttons) {
    _channel.invokeMethod<void>(
        'input.pointer', {'x': x, 'y': y, 'buttons': buttons});
  }

  void sendKey(int keysym, bool down) {
    _channel.invokeMethod<void>('input.key', {'keysym': keysym, 'down': down});
  }

  /// Envia um scancode XT (extensão QEMU Extended Key Event). Retorna false
  /// se o display não suporta (o chamador usa ADB como alternativa).
  Future<bool> sendScancode(int scancode, int keysym, bool down) async =>
      await _channel.invokeMethod<bool>('input.scancode',
          {'scancode': scancode, 'keysym': keysym, 'down': down}) ??
      false;

  /// Pressiona e solta uma tecla por scancode.
  Future<bool> tapScancode(int scancode, int keysym) async {
    if (!await sendScancode(scancode, keysym, true)) return false;
    return sendScancode(scancode, keysym, false);
  }

  // --------------------------------------------------------------- janela
  Future<void> minimizeWindow() => _channel.invokeMethod('window.minimize');
  Future<void> toggleMaximize() => _channel.invokeMethod('window.toggleMaximize');
  Future<void> setFullscreen(bool value) =>
      _channel.invokeMethod('window.setFullscreen', {'value': value});
  Future<void> startWindowDrag() => _channel.invokeMethod('window.startDrag');
  Future<void> startWindowResize(int gdkEdge) =>
      _channel.invokeMethod('window.startResize', {'edge': gdkEdge});
  /// Inicia o fluxo de fechamento (o mesmo do botão do gerenciador de
  /// janelas): a interface desliga a VM com segurança e depois fecha.
  void requestClose() => _events.add(NativeEvent('closeRequested', const {}));

  /// Trava a proporção da área de conteúdo (tela do Android) e, com
  /// [resize], ajusta o tamanho da janela ao monitor.
  Future<void> setContentAspect(double aspect,
          {required int chromeWidth,
          required int chromeHeight,
          int preferredWidth = 1280,
          bool resize = false}) =>
      _channel.invokeMethod('window.setContentAspect', {
        'aspect': aspect,
        'chromeWidth': chromeWidth,
        'chromeHeight': chromeHeight,
        'preferredWidth': preferredWidth,
        'resize': resize,
      });

  Future<void> resizeWindow(int width, int height) =>
      _channel.invokeMethod('window.resize', {'width': width, 'height': height});

  Future<void> closeWindow() => _channel.invokeMethod('window.close');
  Future<void> setWindowTitle(String title) =>
      _channel.invokeMethod('window.setTitle', {'title': title});
}
