import 'package:flutter/services.dart';

/// Disparadores: teclado (`k:` + código da tecla) ou mouse (`m:left`,
/// `m:right`, `m:middle`, `w:up`, `w:down`).
abstract final class Trigger {
  static const mouseLeft = 'm:left';
  static const mouseRight = 'm:right';
  static const mouseMiddle = 'm:middle';
  static const wheelUp = 'w:up';
  static const wheelDown = 'w:down';
  static const none = '';

  static String key(LogicalKeyboardKey k) => 'k:${k.keyId}';

  static bool isKey(String t) => t.startsWith('k:');
  static bool isMouse(String t) => t.startsWith('m:') || t.startsWith('w:');

  static LogicalKeyboardKey? logicalKey(String t) {
    if (!isKey(t)) return null;
    final id = int.tryParse(t.substring(2));
    return id == null ? null : LogicalKeyboardKey.findKeyByKeyId(id);
  }

  static const _short = <String, String>{
    'Arrow Left': '←',
    'Arrow Right': '→',
    'Arrow Up': '↑',
    'Arrow Down': '↓',
    'Space': 'Espaço',
    'Enter': 'Enter',
    'Shift Left': 'Shift',
    'Shift Right': 'Shift',
    'Control Left': 'Ctrl',
    'Control Right': 'Ctrl',
    'Alt Left': 'Alt',
    'Alt Right': 'Alt',
    'Tab': 'Tab',
    'Escape': 'Esc',
    'Backspace': '⌫',
    'Caps Lock': 'Caps',
    'Page Up': 'PgUp',
    'Page Down': 'PgDn',
  };

  /// Texto curto para o emblema na tela.
  static String label(String t) {
    switch (t) {
      case mouseLeft:
        return 'Mouse E';
      case mouseRight:
        return 'Mouse D';
      case mouseMiddle:
        return 'Mouse M';
      case wheelUp:
        return 'Roda ↑';
      case wheelDown:
        return 'Roda ↓';
      case none:
        return '—';
    }
    final k = logicalKey(t);
    if (k == null) return '?';
    if (k == LogicalKeyboardKey.space) return 'Espaço';
    final l = k.keyLabel;
    if (l.trim().isEmpty) return k.debugName ?? '?';
    return _short[l] ?? (l.length == 1 ? l.toUpperCase() : l);
  }
}

enum BindingKind { tap, dpad, swipe, aim }

/// Uma associação entre teclas/mouse e toques na tela do Android. Todas as
/// coordenadas são frações (0..1) da área visível do Android, na orientação
/// atual da tela.
sealed class KeyBinding {
  KeyBinding(this.id);
  final String id;
  BindingKind get kind;

  Iterable<String> get triggers;
  Map<String, Object?> toJson();
  KeyBinding copyWithId(String newId);

  static KeyBinding? fromJson(Map<String, Object?> j) {
    final id = j['id'] is String ? j['id'] as String : '';
    double d(String k, double fallback) {
      final v = j[k];
      return v is num ? v.toDouble().clamp(0.0, 1.0) : fallback;
    }

    String s(String k) => j[k] is String ? j[k] as String : Trigger.none;
    switch (j['type']) {
      case 'tap':
        return TapBinding(id, s('key'), d('x', .5), d('y', .5));
      case 'dpad':
        return DpadBinding(
          id,
          up: s('up'),
          down: s('down'),
          left: s('left'),
          right: s('right'),
          x: d('x', .15),
          y: d('y', .7),
          radius: (j['radius'] is num ? (j['radius'] as num).toDouble() : .12).clamp(.03, .5),
        );
      case 'swipe':
        return SwipeBinding(id, s('key'), d('x', .5), d('y', .5), d('x2', .3), d('y2', .5));
      case 'aim':
        return AimBinding(
          id,
          s('toggle'),
          d('x', .5),
          d('y', .1),
          d('w', .45),
          d('h', .7),
          (j['sensitivity'] is num ? (j['sensitivity'] as num).toDouble() : 1.0).clamp(.1, 5.0),
        );
    }
    return null;
  }
}

/// Toque na posição enquanto a tecla estiver pressionada (soltar a tecla
/// solta o dedo).
class TapBinding extends KeyBinding {
  TapBinding(super.id, this.key, this.x, this.y);
  String key;
  double x, y;
  @override
  BindingKind get kind => BindingKind.tap;
  @override
  Iterable<String> get triggers => [key];
  @override
  KeyBinding copyWithId(String newId) => TapBinding(newId, key, x, y);
  @override
  Map<String, Object?> toJson() => {'id': id, 'type': 'tap', 'key': key, 'x': _r(x), 'y': _r(y)};
}

/// Direcional virtual: quatro teclas movem um "joystick" cujo centro é
/// ([x], [y]) e o alcance [radius] (fração da altura da tela).
class DpadBinding extends KeyBinding {
  DpadBinding(super.id,
      {this.up = Trigger.none,
      this.down = Trigger.none,
      this.left = Trigger.none,
      this.right = Trigger.none,
      required this.x,
      required this.y,
      this.radius = .12});
  String up, down, left, right;
  double x, y, radius;
  @override
  BindingKind get kind => BindingKind.dpad;
  @override
  Iterable<String> get triggers => [up, down, left, right];
  @override
  KeyBinding copyWithId(String newId) => DpadBinding(newId,
      up: up, down: down, left: left, right: right, x: x, y: y, radius: radius);
  @override
  Map<String, Object?> toJson() => {
        'id': id,
        'type': 'dpad',
        'up': up,
        'down': down,
        'left': left,
        'right': right,
        'x': _r(x),
        'y': _r(y),
        'radius': _r(radius),
      };
}

/// Ao pressionar a tecla, arrasta de ([x], [y]) até ([x2], [y2]) e mantém o
/// dedo lá até soltar a tecla.
class SwipeBinding extends KeyBinding {
  SwipeBinding(super.id, this.key, this.x, this.y, this.x2, this.y2);
  String key;
  double x, y, x2, y2;
  @override
  BindingKind get kind => BindingKind.swipe;
  @override
  Iterable<String> get triggers => [key];
  @override
  KeyBinding copyWithId(String newId) => SwipeBinding(newId, key, x, y, x2, y2);
  @override
  Map<String, Object?> toJson() =>
      {'id': id, 'type': 'swipe', 'key': key, 'x': _r(x), 'y': _r(y), 'x2': _r(x2), 'y2': _r(y2)};
}

/// Mira com o mouse: a tecla [toggle] liga/desliga o modo de mira; nele o
/// cursor some e os movimentos do mouse arrastam a região da câmera.
class AimBinding extends KeyBinding {
  AimBinding(super.id, this.toggle, this.x, this.y, this.w, this.h, this.sensitivity);
  String toggle;

  /// Região (canto superior esquerdo e tamanho) onde o dedo da câmera arrasta.
  double x, y, w, h;
  double sensitivity;
  @override
  BindingKind get kind => BindingKind.aim;
  @override
  Iterable<String> get triggers => [toggle];
  @override
  KeyBinding copyWithId(String newId) => AimBinding(newId, toggle, x, y, w, h, sensitivity);
  @override
  Map<String, Object?> toJson() => {
        'id': id,
        'type': 'aim',
        'toggle': toggle,
        'x': _r(x),
        'y': _r(y),
        'w': _r(w),
        'h': _r(h),
        'sensitivity': _r(sensitivity),
      };
}

double _r(double v) => (v * 10000).roundToDouble() / 10000;

/// Conjunto de associações para um jogo/app (ou um modelo genérico).
class KeymapProfile {
  KeymapProfile({
    required this.name,
    this.packages = const [],
    List<KeyBinding>? bindings,
    this.builtin = false,
    this.note = '',
  }) : bindings = bindings ?? [];

  String name;

  /// Pacotes Android que ativam este perfil automaticamente.
  List<String> packages;
  List<KeyBinding> bindings;

  /// Modelo que acompanha o SECADA Emulator (não editável no lugar; editar cria uma
  /// cópia do usuário).
  final bool builtin;
  String note;

  KeymapProfile copy({String? name}) => KeymapProfile(
        name: name ?? this.name,
        packages: [...packages],
        bindings: [for (final b in bindings) b.copyWithId(b.id)],
        note: note,
      );

  String nextId() {
    var n = bindings.length + 1;
    final used = bindings.map((b) => b.id).toSet();
    while (used.contains('b$n')) {
      n++;
    }
    return 'b$n';
  }

  Map<String, Object?> toJson() => {
        'version': 1,
        'name': name,
        'packages': packages,
        'note': note,
        'bindings': [for (final b in bindings) b.toJson()],
      };

  static KeymapProfile? fromJson(Object? json) {
    if (json is! Map) return null;
    final j = Map<String, Object?>.from(json);
    final name = j['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final bindings = <KeyBinding>[];
    final ids = <String>{};
    for (final raw in (j['bindings'] is List ? j['bindings'] as List : const [])) {
      if (raw is! Map) continue;
      final b = KeyBinding.fromJson(Map<String, Object?>.from(raw));
      if (b == null) continue;
      // Garante ids únicos mesmo em arquivos editados à mão.
      var id = b.id;
      var n = bindings.length + 1;
      while (id.isEmpty || ids.contains(id)) {
        id = 'b${n++}';
      }
      ids.add(id);
      bindings.add(id == b.id ? b : b.copyWithId(id));
    }
    return KeymapProfile(
      name: name.trim(),
      packages: [
        for (final p in (j['packages'] is List ? j['packages'] as List : const []))
          if (p is String && p.isNotEmpty) p,
      ],
      bindings: bindings,
      note: j['note'] is String ? j['note'] as String : '',
    );
  }
}
