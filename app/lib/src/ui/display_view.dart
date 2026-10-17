import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_log.dart';
import '../core/native_bridge.dart';
import '../input/keysym.dart';
import '../keymap/keymap_controller.dart';
import '../vm/vm_controller.dart';
import 'keymap_overlay.dart';

/// Exibe a tela real do Android (textura alimentada pelo cliente RFB nativo)
/// e encaminha mouse e teclado como eventos RFB.
///
/// A imagem é escalada mantendo a proporção; as coordenadas do ponteiro são
/// convertidas para o espaço do tablet virtual considerando escala,
/// deslocamento (letterbox) e a região ativa ([VmController.viewport]).
class DisplayView extends StatefulWidget {
  const DisplayView({
    super.key,
    required this.controller,
    required this.onHostShortcut,
    required this.onBack,
    this.keymap,
  });

  final VmController controller;

  /// Mapeador de teclas (opcional): quando ligado, teclado e mouse viram
  /// toques em vez de seguirem para o Android como entrada normal.
  final KeymapController? keymap;

  /// Atalhos tratados pelo host (não enviados ao Android). Retorna true se
  /// consumiu a tecla.
  final bool Function(KeyEvent event) onHostShortcut;

  /// Ação "Voltar" do Android (usada quando Esc = Voltar).
  final VoidCallback onBack;

  @override
  State<DisplayView> createState() => _DisplayViewState();
}

class _DisplayViewState extends State<DisplayView> with WidgetsBindingObserver {
  final FocusNode _focus = FocusNode(debugLabel: 'android-display');
  final NativeBridge _native = NativeBridge.instance;

  /// Teclas pressionadas: tecla física -> keysym enviado no "down", para que o
  /// "up" use o mesmo keysym mesmo se modificadores mudarem no meio.
  final Map<PhysicalKeyboardKey, int> _pressed = {};
  int _buttons = 0;
  int _lastX = 0, _lastY = 0;
  double _scrollAccum = 0;

  // Geometria corrente (atualizada em build): tamanho desenhado da área do
  // Android e seu deslocamento dentro do container (negativo no modo cover).
  Size _drawn = const Size(1, 1);
  Offset _offset = Offset.zero;
  DisplayViewport _vp = const DisplayViewport(0, 0, 1, 1);

  /// Diferença de proporção até a qual a imagem é ampliada para preencher o
  /// container (cortando no máximo ~4% das bordas) em vez de mostrar faixas.
  static const double _coverTolerance = 1.045;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _releaseAll();
      _syncLock();
    });
    widget.keymap?.addListener(_onKeymap);
    widget.keymap?.engine.addListener(_onEngine);
    widget.controller.addListener(_syncLock);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _windowActive = state == AppLifecycleState.resumed;
    _syncLock();
  }

  @override
  void didUpdateWidget(DisplayView old) {
    super.didUpdateWidget(old);
    if (old.keymap != widget.keymap) {
      old.keymap?.removeListener(_onKeymap);
      old.keymap?.engine.removeListener(_onEngine);
      widget.keymap?.addListener(_onKeymap);
      widget.keymap?.engine.addListener(_onEngine);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_syncLock);
    widget.keymap?.removeListener(_onKeymap);
    widget.keymap?.engine.removeListener(_onEngine);
    _releaseAll();
    _focus.dispose();
    super.dispose();
  }

  void _onKeymap() {
    if (mounted) setState(() {});
  }

  bool _wasAiming = false;
  void _onEngine() {
    final aiming = widget.keymap?.engine.aiming ?? false;
    if (aiming && !_wasAiming) {
      // Ao ligar a mira, leva o cursor ao centro para ter folga nos dois sentidos.
      _aimLast = null;
      _warpToCenter();
    }
    _wasAiming = aiming;
    if (mounted) setState(() {});
  }

  void _releaseAll() {
    final km = widget.keymap;
    if (km != null && km.enabled) km.engine.releaseAll();
    for (final keysym in _pressed.values) {
      _native.sendKey(keysym, false);
    }
    _pressed.clear();
    if (_buttons != 0) {
      _buttons = 0;
      _native.sendPointer(_lastX, _lastY, 0);
    }
  }

  // -------------------------------------------------------------- mapeador
  KeymapController? get _km => widget.keymap;
  bool get _kmOn => _km?.enabled ?? false;

  /// Posição local -> frações (0..1) da área do Android.
  (double, double) _uv(Offset local) => (
        ((local.dx - _offset.dx) / _drawn.width).clamp(0.0, 1.0),
        ((local.dy - _offset.dy) / _drawn.height).clamp(0.0, 1.0),
      );

  Offset? _aimLast;
  bool _awaitWarp = false;
  DateTime _warpAt = DateTime.fromMillisecondsSinceEpoch(0);

  Offset get _center => Offset(_offset.dx + _drawn.width / 2, _offset.dy + _drawn.height / 2);

  /// Leva o cursor do sistema ao centro da área do Android (mira).
  void _warpToCenter() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final g = box.localToGlobal(_center);
    _awaitWarp = true;
    _warpAt = DateTime.now();
    _native.warpPointer(g.dx.round(), g.dy.round()).then((ok) {
      // Wayland não deixa reposicionar o cursor: sem isso não há trava, volta ao ponteiro absoluto.
      if (!ok && _lockOn && mounted) {
        _lockUnsupported = true;
        _awaitWarp = false;
        _syncLock();
      }
    });
  }

  // ----------------------------------------------------- trava do ponteiro
  /// Um app pediu a trava do ponteiro (jogo com a câmera presa ao mouse): o cursor do computador fica
  /// preso no centro da janela e o movimento segue para o Android como deslocamento relativo (mouse PS/2),
  /// sem nunca bater na borda. Alt (no jogo), Ctrl+Alt+G ou trocar de janela soltam o cursor.
  bool _lockOn = false;
  bool _lockSuspended = false;
  bool _lockUnsupported = false;
  bool _windowActive = true;
  double _remX = 0, _remY = 0;

  bool get _wantLock =>
      widget.controller.guestPointerLock &&
      widget.controller.displayConnected &&
      !_lockSuspended &&
      !_lockUnsupported &&
      !_kmOn &&
      _windowActive &&
      _focus.hasFocus;

  String _lockWhy = '';

  void _syncLock() {
    final want = _wantLock;
    final why = 'guest=${widget.controller.guestPointerLock} conectado=${widget.controller.displayConnected} '
        'suspensa=$_lockSuspended naoSuportada=$_lockUnsupported mapeador=$_kmOn janela=$_windowActive foco=${_focus.hasFocus}';
    if (why != _lockWhy) {
      _lockWhy = why;
      log.info('Trava do ponteiro: querer=$want ($why)');
    }
    if (want == _lockOn) return;
    _lockOn = want;
    _aimLast = null;
    _remX = _remY = 0;
    if (want) {
      final c = _center;
      final (x, y) = _toGuest(c);
      _lastX = x;
      _lastY = y;
      _warpToCenter();
    } else {
      _awaitWarp = false;
    }
    if (mounted) setState(() {});
  }

  /// Movimento com a trava ligada: deslocamento desde o último evento, enviado como relativo.
  void _lockMove(Offset pos) {
    if (_awaitWarp) {
      // Descarta o movimento até chegar o evento do próprio salto do cursor.
      final stale = DateTime.now().difference(_warpAt).inMilliseconds > 60;
      if ((pos - _center).distance < 4 || stale) {
        _awaitWarp = false;
        _aimLast = pos;
      }
      return;
    }
    final last = _aimLast ?? pos;
    _aimLast = pos;
    final d = pos - last;
    if (d != Offset.zero) {
      // pixels da janela -> pixels do Android; a fração fica guardada para o movimento lento não se perder
      _remX += d.dx * widget.controller.fbWidth / _drawn.width;
      _remY += d.dy * widget.controller.fbHeight / _drawn.height;
      final ix = _remX.truncate(), iy = _remY.truncate();
      if (ix != 0 || iy != 0) {
        _remX -= ix;
        _remY -= iy;
        widget.controller.sendRelativeMouse(ix, iy);
      }
    }
    // Fora da faixa central: volta o cursor ao centro. A margem é grande (30% da menor lado) para que nem uma varrida
    // muito rápida do mouse saia da janela entre dois eventos.
    final m = _drawn.shortestSide * .30;
    final inner = Rect.fromLTWH(_offset.dx, _offset.dy, _drawn.width, _drawn.height).deflate(m);
    if (!inner.contains(pos)) _warpToCenter();
  }

  /// Botões com a trava ligada: só mudam o estado dos botões (a posição absoluta não importa para o app).
  void _lockButtons(int buttons) {
    final b = _rfbButtons(buttons);
    if (b == _buttons) return;
    _buttons = b;
    _native.sendPointer(_lastX, _lastY, b);
  }

  /// Entrada do mouse com o mapeador ligado. Retorna true (sempre consome).
  bool _kmPointer(PointerEvent e, int buttons) {
    final km = _km!;
    if (km.editing) return true;
    final (u, v) = _uv(e.localPosition);
    if (km.engine.aiming) _aimMove(e.localPosition);
    km.engine.pointer(u, v, buttons);
    return true;
  }

  void _aimMove(Offset pos) {
    if (_awaitWarp) {
      // Descarta o movimento até chegar o evento do próprio salto do cursor.
      final stale = DateTime.now().difference(_warpAt).inMilliseconds > 60;
      if ((pos - _center).distance < 4 || stale) {
        _awaitWarp = false;
        _aimLast = pos;
      }
      return;
    }
    final last = _aimLast ?? pos;
    _aimLast = pos;
    final d = pos - last;
    if (d != Offset.zero) {
      _km!.engine.aimDelta(d.dx / _drawn.width, d.dy / _drawn.height);
    }
    // Perto da borda: volta o cursor ao centro para nunca "bater na parede".
    final m = _drawn.shortestSide * .18;
    final inner = Rect.fromLTWH(_offset.dx, _offset.dy, _drawn.width, _drawn.height).deflate(m);
    if (!inner.contains(pos)) _warpToCenter();
  }

  // ------------------------------------------------------------------ mouse
  /// Converte posição local (pixels lógicos do container) em pixels da VM.
  ///
  /// O tablet USB é absoluto e o Android-x86 normaliza a faixa inteira do
  /// dispositivo para a geometria *lógica* da tela. Por isso o ponto enviado é
  /// a fração da área exibida aplicada ao framebuffer inteiro — correto tanto
  /// na orientação nativa quanto na rotação rápida (`wm size`).
  (int, int) _toGuest(Offset local) {
    final fw = widget.controller.fbWidth, fh = widget.controller.fbHeight;
    final u = ((local.dx - _offset.dx) / _drawn.width).clamp(0.0, 1.0);
    final v = ((local.dy - _offset.dy) / _drawn.height).clamp(0.0, 1.0);
    return ((u * (fw - 1)).round(), (v * (fh - 1)).round());
  }

  /// Botões Flutter -> máscara RFB (bit0 esquerdo, bit1 meio, bit2 direito).
  static int _rfbButtons(int flutterButtons) {
    var m = 0;
    if (flutterButtons & kPrimaryMouseButton != 0) m |= 1;
    if (flutterButtons & kMiddleMouseButton != 0) m |= 2;
    if (flutterButtons & kSecondaryMouseButton != 0) m |= 4;
    return m;
  }

  void _sendPointer(Offset local, int buttons) {
    final (x, y) = _toGuest(local);
    _lastX = x;
    _lastY = y;
    _buttons = buttons;
    _native.sendPointer(x, y, buttons);
  }

  void _wheel(double dy) {
    // Cada "clique" da roda = botão 4 (cima) ou 5 (baixo) pressionado e solto.
    _scrollAccum += dy;
    const step = 40.0;
    while (_scrollAccum.abs() >= step) {
      final up = _scrollAccum < 0;
      final bit = up ? 8 : 16;
      _native.sendPointer(_lastX, _lastY, _buttons | bit);
      _native.sendPointer(_lastX, _lastY, _buttons);
      _scrollAccum += up ? step : -step;
    }
  }

  // ---------------------------------------------------------------- teclado
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (widget.onHostShortcut(event)) return KeyEventResult.handled;
    // Ctrl+Alt+G: solta/recaptura o cursor do computador (trava do ponteiro).
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyG &&
        HardwareKeyboard.instance.isControlPressed &&
        HardwareKeyboard.instance.isAltPressed) {
      _lockSuspended = !_lockSuspended;
      _syncLock();
      return KeyEventResult.handled;
    }
    if (!widget.controller.displayConnected) return KeyEventResult.ignored;
    final km = _km;
    if (km != null && km.enabled) {
      // Edição: a próxima tecla pode ser a captura; o resto não vai ao Android.
      if (km.editing) {
        km.offerKey(event);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.f8) {
        if (event is KeyDownEvent) km.togglePaused();
        return KeyEventResult.handled;
      }
      if (km.engine.aiming && event.logicalKey == LogicalKeyboardKey.escape) {
        if (event is KeyDownEvent) km.engine.setAiming(false);
        return KeyEventResult.handled;
      }
      if (km.engine.handleKey(event)) return KeyEventResult.handled;
    }
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (event.logicalKey == LogicalKeyboardKey.escape &&
          widget.controller.settings.escAsBack) {
        // Esc = Voltar: toque único da tecla BACK por scancode.
        if (event is KeyDownEvent) widget.onBack();
        return KeyEventResult.handled;
      }
      final keysym = _pressed[event.physicalKey] ?? Keysym.forKeyDown(event);
      if (keysym == null) return KeyEventResult.ignored;
      _pressed[event.physicalKey] = keysym;
      _native.sendKey(keysym, true);
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      if (event.logicalKey == LogicalKeyboardKey.escape &&
          widget.controller.settings.escAsBack) {
        return KeyEventResult.handled;
      }
      final keysym = _pressed.remove(event.physicalKey);
      if (keysym == null) return KeyEventResult.ignored;
      _native.sendKey(keysym, false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final textureId = c.textureId;
    if (textureId == null || c.fbWidth <= 0) {
      return const SizedBox.expand();
    }
    _vp = c.viewport;
    return LayoutBuilder(builder: (context, box) {
      final bw = box.maxWidth, bh = box.maxHeight;
      final sx = bw / _vp.width, sy = bh / _vp.height;
      final contain = sx < sy ? sx : sy;
      final cover = sx > sy ? sx : sy;
      final scale = cover / contain <= _coverTolerance ? cover : contain;
      _drawn = Size(_vp.width * scale, _vp.height * scale);
      _offset = Offset((bw - _drawn.width) / 2, (bh - _drawn.height) / 2);
      return Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: MouseRegion(
          // O Android desenha o próprio ponteiro (dispositivo usb-tablet);
          // ocultar o do host evita dois cursores sobrepostos. Com o
          // mapeador ligado o mouse vira toque (o Android não desenha
          // ponteiro), então o cursor do sistema aparece, exceto na mira.
          cursor: !_kmOn
              ? SystemMouseCursors.none
              : (_km!.engine.aiming && !_km!.editing)
                  ? SystemMouseCursors.none
                  : _km!.editing
                      ? SystemMouseCursors.basic
                      : SystemMouseCursors.precise,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) {
              if (!_focus.hasFocus) _focus.requestFocus();
              if (_kmOn) {
                _kmPointer(e, e.buttons);
                return;
              }
              if (_lockOn) {
                _lockButtons(e.buttons);
                return;
              }
              _sendPointer(e.localPosition, _rfbButtons(e.buttons));
            },
            onPointerMove: (e) {
              if (_kmOn) {
                _kmPointer(e, e.buttons);
                return;
              }
              if (_lockOn) {
                _lockMove(e.localPosition);
                return;
              }
              _sendPointer(e.localPosition, _rfbButtons(e.buttons));
            },
            onPointerHover: (e) {
              if (_kmOn) {
                _kmPointer(e, 0);
                return;
              }
              if (_lockOn) {
                _lockMove(e.localPosition);
                return;
              }
              _sendPointer(e.localPosition, 0);
            },
            onPointerUp: (e) {
              if (_kmOn) {
                _kmPointer(e, e.buttons);
                return;
              }
              if (_lockOn) {
                _lockButtons(e.buttons);
                return;
              }
              _sendPointer(e.localPosition, _rfbButtons(e.buttons));
            },
            onPointerCancel: (e) {
              if (_kmOn) {
                _kmPointer(e, 0);
                return;
              }
              if (_lockOn) {
                _lockButtons(0);
                return;
              }
              _sendPointer(e.localPosition, 0);
            },
            onPointerSignal: (e) {
              if (e is! PointerScrollEvent) return;
              if (_kmOn) {
                if (!_km!.editing) {
                  final (u, v) = _uv(e.localPosition);
                  _km!.engine.wheel(u, v, e.scrollDelta.dy);
                }
                return;
              }
              final (x, y) = _toGuest(e.localPosition);
              _lastX = x;
              _lastY = y;
              _wheel(e.scrollDelta.dy);
            },
            onPointerPanZoomUpdate: (e) {
              if (_kmOn) {
                if (!_km!.editing) {
                  final (u, v) = _uv(e.localPosition);
                  _km!.engine.wheel(u, v, -e.panDelta.dy * 3);
                }
                return;
              }
              _wheel(-e.panDelta.dy);
            },
            child: ClipRect(
              child: Stack(
                children: [
                  Positioned(
                    left: _offset.dx - _vp.left * scale,
                    top: _offset.dy - _vp.top * scale,
                    width: c.fbWidth * scale,
                    height: c.fbHeight * scale,
                    child: Texture(
                      textureId: textureId,
                      filterQuality: scale == 1.0 ? FilterQuality.none : FilterQuality.medium,
                    ),
                  ),
                  if (widget.keymap != null)
                    Positioned.fill(
                      child: KeymapOverlay(
                        controller: widget.keymap!,
                        rect: Rect.fromLTWH(_offset.dx, _offset.dy, _drawn.width, _drawn.height),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}
