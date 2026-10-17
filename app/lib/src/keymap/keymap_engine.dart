import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'keymap_models.dart';
import 'touch_injector.dart';

/// Converte teclado e mouse em toques, conforme o perfil ativo.
///
/// Pontos (slots) do multitoque:
/// * 0 e 1: direcionais; 2–6: toques e deslizes; 7: rolagem pela roda;
/// * 8: câmera (mira com o mouse); 9: o mouse como dedo.
///
/// Os eventos de entrada chegam do `DisplayView` já normalizados (frações
/// 0..1 da área visível do Android).
class KeymapEngine extends ChangeNotifier {
  KeymapEngine(this.injector, {double Function()? aspect}) : _aspect = aspect ?? (() => 16 / 9);

  final TouchInjector injector;
  final double Function() _aspect;

  static const _dpadSlots = [0, 1];
  static const _actionSlots = [2, 3, 4, 5, 6];
  static const _wheelSlot = 7;
  static const _aimSlot = 8;
  static const _mouseSlot = 9;

  KeymapProfile? _profile;
  KeymapProfile? get profile => _profile;

  /// Multiplicador global da sensibilidade da mira.
  double sensitivity = 1.0;

  /// Modo digitação: as teclas passam direto ao Android (o mouse continua
  /// funcionando como dedo).
  bool get paused => _paused;
  bool _paused = false;

  /// Modo de mira ligado (cursor oculto; o mouse move a câmera).
  bool get aiming => _aiming;
  bool _aiming = false;

  /// Região da câmera no modo de mira, se o perfil tiver uma.
  AimBinding? get aimBinding => _aim;
  AimBinding? _aim;

  final Map<String, List<_Act>> _byTrigger = {};
  final Set<String> _down = {};
  final Map<Object, int> _slotOf = {}; // binding/ação -> slot ocupado
  final Map<DpadBinding, Set<String>> _dpadHeld = {};
  final Map<SwipeBinding, _SwipeRun> _swipes = {};

  /// Teclas/botões atualmente pressionados (para realçar na tela).
  Set<String> get held => _down;

  void setProfile(KeymapProfile? p) {
    releaseAll();
    _profile = p;
    _byTrigger.clear();
    _aim = null;
    if (p != null) {
      for (final b in p.bindings) {
        switch (b) {
          case TapBinding():
            _add(b.key, _Act(b, 'main'));
          case SwipeBinding():
            _add(b.key, _Act(b, 'main'));
          case DpadBinding():
            _add(b.up, _Act(b, 'up'));
            _add(b.down, _Act(b, 'down'));
            _add(b.left, _Act(b, 'left'));
            _add(b.right, _Act(b, 'right'));
          case AimBinding():
            _aim ??= b;
            _add(b.toggle, _Act(b, 'toggle'));
        }
      }
    }
    notifyListeners();
  }

  void _add(String trigger, _Act a) {
    if (trigger.isEmpty) return;
    _byTrigger.putIfAbsent(trigger, () => []).add(a);
  }

  void setPaused(bool v) {
    if (_paused == v) return;
    // Soltar o que está pressionado antes de devolver as teclas ao Android.
    if (v) _releaseKeys();
    _paused = v;
    notifyListeners();
  }

  void setAiming(bool v) {
    if (_aiming == v) return;
    if (!v) _stopAim();
    _aiming = v;
    // Os botões do mouse mudam de papel: libera o dedo do mouse.
    if (v) _mouseFingerUp();
    notifyListeners();
  }

  // ---------------------------------------------------------------- teclado
  /// Trata uma tecla do host. Retorna true se ela é mapeada (consumida).
  bool handleKey(KeyEvent e) {
    final t = Trigger.key(e.logicalKey);
    final acts = _byTrigger[t];
    if (acts == null) return false;
    if (_paused) return false;
    if (e is KeyDownEvent) {
      if (_down.add(t)) {
        for (final a in acts) {
          _press(a);
        }
        notifyListeners();
      }
    } else if (e is KeyUpEvent) {
      if (_down.remove(t)) {
        for (final a in acts) {
          _release(a);
        }
        notifyListeners();
      }
    }
    return true; // repetições também são consumidas
  }

  void _press(_Act a) {
    switch (a.binding) {
      case TapBinding b:
        final s = _alloc(b);
        if (s != null) injector.down(s, b.x, b.y);
      case SwipeBinding b:
        _swipeStart(b);
      case DpadBinding b:
        (_dpadHeld[b] ??= {}).add(a.role);
        _dpadUpdate(b);
      case AimBinding():
        setAiming(!_aiming);
    }
  }

  void _release(_Act a) {
    switch (a.binding) {
      case TapBinding b:
        _free(b);
      case SwipeBinding b:
        _swipeEnd(b);
      case DpadBinding b:
        _dpadHeld[b]?.remove(a.role);
        _dpadUpdate(b);
      case AimBinding():
        break; // alterna só ao pressionar
    }
  }

  int? _alloc(Object owner) {
    final used = _slotOf.values.toSet();
    for (final s in _actionSlots) {
      if (!used.contains(s)) {
        _slotOf[owner] = s;
        return s;
      }
    }
    return null;
  }

  void _free(Object owner) {
    final s = _slotOf.remove(owner);
    if (s != null) injector.up(s);
  }

  // ----------------------------------------------------------- direcional
  void _dpadUpdate(DpadBinding b) {
    final held = _dpadHeld[b] ?? const {};
    var vx = (held.contains('right') ? 1.0 : 0.0) - (held.contains('left') ? 1.0 : 0.0);
    var vy = (held.contains('down') ? 1.0 : 0.0) - (held.contains('up') ? 1.0 : 0.0);
    var slot = _slotOf[b];
    if (vx == 0 && vy == 0) {
      if (slot != null) {
        _slotOf.remove(b);
        injector.up(slot);
      }
      return;
    }
    final len = math.sqrt(vx * vx + vy * vy);
    vx /= len;
    vy /= len;
    if (slot == null) {
      final used = _slotOf.values.toSet();
      slot = _dpadSlots.where((s) => !used.contains(s)).firstOrNull;
      if (slot == null) return;
      _slotOf[b] = slot;
      injector.down(slot, b.x, b.y); // começa no centro do direcional
    }
    // O raio é fração da altura; na horizontal compensa a proporção da tela.
    injector.move(slot, b.x + vx * b.radius / _aspect(), b.y + vy * b.radius);
  }

  // -------------------------------------------------------------- deslizes
  void _swipeStart(SwipeBinding b) {
    if (_swipes.containsKey(b)) return;
    final s = _alloc(b);
    if (s == null) return;
    _swipes[b]?.timer?.cancel();
    final run = _SwipeRun(s);
    _swipes[b] = run;
    injector.down(s, b.x, b.y);
    const steps = 6;
    run.timer = Timer.periodic(const Duration(milliseconds: 14), (t) {
      run.step++;
      final f = run.step / steps;
      injector.move(s, b.x + (b.x2 - b.x) * f, b.y + (b.y2 - b.y) * f);
      if (run.step >= steps) {
        t.cancel();
        run.timer = null;
        if (run.releasePending) _swipeFinish(b, run);
      }
    });
  }

  void _swipeEnd(SwipeBinding b) {
    final run = _swipes[b];
    if (run == null) return;
    if (run.timer != null) {
      // Soltou antes de terminar o gesto: conclui o deslize e então solta.
      run.releasePending = true;
    } else {
      _swipeFinish(b, run);
    }
  }

  void _swipeFinish(SwipeBinding b, _SwipeRun run) {
    _swipes.remove(b);
    _slotOf.remove(b);
    injector.up(run.slot);
  }

  // ------------------------------------------------------------------ mouse
  int _prevButtons = 0;

  /// Botões do mouse (máscara do Flutter) com a posição atual em frações da
  /// área do Android. Chamado em down/move/up do ponteiro.
  void pointer(double u, double v, int buttons) {
    final prev = _prevButtons;
    _prevButtons = buttons;
    final pressed = buttons & ~prev;
    final released = prev & ~buttons;
    if (_aiming) {
      for (final (mask, trig) in [
        (kPrimaryMouseButton, Trigger.mouseLeft),
        (kSecondaryMouseButton, Trigger.mouseRight),
        (kMiddleMouseButton, Trigger.mouseMiddle),
      ]) {
        if (pressed & mask != 0) _mouseTrigger(trig, true);
        if (released & mask != 0) _mouseTrigger(trig, false);
      }
      return;
    }
    final left = kPrimaryMouseButton;
    if (pressed & left != 0) {
      injector.down(_mouseSlot, u, v);
    } else if (buttons & left != 0) {
      injector.move(_mouseSlot, u, v);
    } else if (released & left != 0) {
      injector.up(_mouseSlot);
    }
  }

  void _mouseFingerUp() {
    if (injector.isDown(_mouseSlot)) injector.up(_mouseSlot);
  }

  void _mouseTrigger(String t, bool down) {
    final acts = _byTrigger[t];
    if (acts == null) return;
    if (down) {
      if (_down.add(t)) {
        for (final a in acts) {
          _press(a);
        }
      }
    } else if (_down.remove(t)) {
      for (final a in acts) {
        _release(a);
      }
    }
    notifyListeners();
  }

  /// Rolagem da roda do mouse. No modo de mira vira toque nos botões "roda ↑/↓"
  /// do perfil; fora dele, um deslize curto na posição do ponteiro.
  void wheel(double u, double v, double dy) {
    if (dy == 0) return;
    if (_aiming) {
      final t = dy < 0 ? Trigger.wheelUp : Trigger.wheelDown;
      if (_byTrigger.containsKey(t)) {
        _mouseTrigger(t, true);
        Timer(const Duration(milliseconds: 50), () => _mouseTrigger(t, false));
      }
      return;
    }
    if (injector.isDown(_wheelSlot)) return;
    // Roda para baixo = conteúdo sobe = dedo sobe.
    final travel = (dy.abs() / 120).clamp(.06, .3) * (dy > 0 ? -1 : 1);
    final y1 = (v + travel).clamp(.02, .98);
    injector.down(_wheelSlot, u, v);
    var step = 0;
    Timer.periodic(const Duration(milliseconds: 14), (t) {
      step++;
      injector.move(_wheelSlot, u, v + (y1 - v) * step / 4);
      if (step >= 4) {
        t.cancel();
        Timer(const Duration(milliseconds: 30), () => injector.up(_wheelSlot));
      }
    });
  }

  // ------------------------------------------------------------------- mira
  double _ax = 0, _ay = 0;
  Timer? _aimIdle;

  /// Deslocamento do mouse no modo de mira, em frações da área do Android.
  void aimDelta(double du, double dv) {
    final b = _aim;
    if (!_aiming || b == null) return;
    final k = b.sensitivity * sensitivity;
    final cx = b.x + b.w / 2, cy = b.y + b.h / 2;
    if (!injector.isDown(_aimSlot)) {
      _ax = cx;
      _ay = cy;
      injector.down(_aimSlot, _ax, _ay);
    }
    var nx = _ax + du * k, ny = _ay + dv * k;
    final inside = nx >= b.x && nx <= b.x + b.w && ny >= b.y && ny <= b.y + b.h;
    if (!inside) {
      // Chegou à borda da região: levanta e recomeça do centro (o jogo só
      // enxerga deslocamentos, então a câmera não dá salto).
      injector.up(_aimSlot);
      _ax = cx;
      _ay = cy;
      injector.down(_aimSlot, _ax, _ay);
      nx = (_ax + du * k).clamp(b.x, b.x + b.w);
      ny = (_ay + dv * k).clamp(b.y, b.y + b.h);
    }
    _ax = nx;
    _ay = ny;
    injector.move(_aimSlot, _ax, _ay);
    _aimIdle?.cancel();
    _aimIdle = Timer(const Duration(milliseconds: 110), _stopAim);
  }

  void _stopAim() {
    _aimIdle?.cancel();
    _aimIdle = null;
    if (injector.isDown(_aimSlot)) injector.up(_aimSlot);
  }

  // ---------------------------------------------------------------- limpeza
  void _releaseKeys() {
    for (final t in _down.toList()) {
      final acts = _byTrigger[t];
      if (acts == null) continue;
      for (final a in acts) {
        _release(a);
      }
    }
    _down.clear();
  }

  /// Solta tudo: teclas, dedos e modo de mira.
  void releaseAll() {
    _releaseKeys();
    for (final run in _swipes.values) {
      run.timer?.cancel();
    }
    _swipes.clear();
    _slotOf.clear();
    _dpadHeld.clear();
    _stopAim();
    _aiming = false;
    _prevButtons = 0;
    injector.upAll();
  }

  @override
  void dispose() {
    releaseAll();
    super.dispose();
  }

  /// Posição do centro e alcance de um direcional para o HUD.
  static Rect dpadBounds(DpadBinding b, double aspect) {
    final rx = b.radius / aspect, ry = b.radius;
    return Rect.fromLTRB(b.x - rx, b.y - ry, b.x + rx, b.y + ry);
  }
}

class _Act {
  _Act(this.binding, this.role);
  final KeyBinding binding;
  final String role;
}

class _SwipeRun {
  _SwipeRun(this.slot);
  final int slot;
  int step = 0;
  Timer? timer;
  bool releasePending = false;
}
