import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../keymap/keymap_controller.dart';
import '../keymap/keymap_models.dart';

/// Camada sobre a tela do Android: emblemas das teclas (quando o mapeamento
/// está ligado) e o editor de posições (no modo de edição).
///
/// [rect] é a área onde o Android é desenhado, em coordenadas locais do
/// `DisplayView`; as posições dos botões são frações dela.
class KeymapOverlay extends StatelessWidget {
  const KeymapOverlay({super.key, required this.controller, required this.rect});

  final KeymapController controller;
  final Rect rect;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, controller.engine]),
      builder: (context, _) {
        if (!controller.enabled) return const SizedBox.shrink();
        final editing = controller.editing;
        final profile = editing ? controller.draft : controller.profile;
        final cs = Theme.of(context).colorScheme;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (editing && profile != null)
              _Editor(controller: controller, profile: profile, rect: rect)
            else if (controller.prefs.showHud && profile != null)
              IgnorePointer(child: _Hud(controller: controller, profile: profile, rect: rect)),
            if (!editing)
              Positioned(
                left: rect.left + 8,
                top: rect.top + 8,
                child: IgnorePointer(child: _StatusChips(controller: controller, cs: cs)),
              ),
            if (!editing && controller.engine.aiming)
              Positioned.fromRect(
                rect: Rect.fromCenter(center: rect.center, width: 28, height: 28),
                child: const IgnorePointer(child: _Crosshair()),
              ),
          ],
        );
      },
    );
  }
}

// ------------------------------------------------------------------ geometria
Offset _px(Rect r, double x, double y) => Offset(r.left + x * r.width, r.top + y * r.height);

class _Crosshair extends StatelessWidget {
  const _Crosshair();
  @override
  Widget build(BuildContext context) => CustomPaint(painter: _CrossPainter());
}

class _CrossPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final shadow = Paint()
      ..color = Colors.black54
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final line = Paint()
      ..color = Colors.white
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (final p in [shadow, line]) {
      canvas.drawLine(Offset(c.dx - 12, c.dy), Offset(c.dx - 4, c.dy), p);
      canvas.drawLine(Offset(c.dx + 4, c.dy), Offset(c.dx + 12, c.dy), p);
      canvas.drawLine(Offset(c.dx, c.dy - 12), Offset(c.dx, c.dy - 4), p);
      canvas.drawLine(Offset(c.dx, c.dy + 4), Offset(c.dx, c.dy + 12), p);
    }
  }

  @override
  bool shouldRepaint(_CrossPainter old) => false;
}

class _StatusChips extends StatelessWidget {
  const _StatusChips({required this.controller, required this.cs});
  final KeymapController controller;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    Widget chip(IconData icon, String text, {bool accent = false}) => Container(
          margin: const EdgeInsets.only(right: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: (accent ? cs.primary : Colors.black).withValues(alpha: .62),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 13, color: accent ? cs.onPrimary : Colors.white70),
            const SizedBox(width: 5),
            Text(text,
                style: TextStyle(
                    fontSize: 11.5, color: accent ? cs.onPrimary : Colors.white, height: 1)),
          ]),
        );
    final e = controller.engine;
    final name = controller.profile?.name;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      chip(Icons.sports_esports_rounded, name ?? 'Sem perfil neste app'),
      if (e.paused) chip(Icons.keyboard_rounded, 'Digitação (F8 retoma)', accent: true),
      if (e.aiming) chip(Icons.gps_fixed_rounded, 'Mira ligada', accent: true),
    ]);
  }
}

// ------------------------------------------------------------------- emblemas
class _Badge extends StatelessWidget {
  const _Badge(this.label,
      {this.held = false, this.selected = false, this.size = 38, this.faded = false});
  final String label;
  final bool held;
  final bool selected;
  final double size;
  final bool faded;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final empty = label == '—';
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: held
            ? cs.primary.withValues(alpha: .9)
            : Colors.black.withValues(alpha: faded ? .35 : .55),
        border: Border.all(
          color: selected
              ? cs.tertiary
              : empty
                  ? Colors.redAccent
                  : Colors.white.withValues(alpha: faded ? .45 : .85),
          width: selected ? 3 : 1.6,
        ),
      ),
      child: FittedBox(
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Text(
            label,
            style: TextStyle(
              color: held ? cs.onPrimary : Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 13,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------------ HUD
class _Hud extends StatelessWidget {
  const _Hud({required this.controller, required this.profile, required this.rect});
  final KeymapController controller;
  final KeymapProfile profile;
  final Rect rect;

  @override
  Widget build(BuildContext context) {
    final held = controller.engine.held;
    final paused = controller.engine.paused;
    return Opacity(
      opacity: paused ? .35 : 1,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final b in profile.bindings) ..._drawBinding(context, b, held, false),
        ],
      ),
    );
  }

  List<Widget> _drawBinding(BuildContext context, KeyBinding b, Set<String> held, bool _) {
    return _bindingWidgets(context, rect, b, held: held, selected: false, faded: true);
  }
}

/// Desenho de uma associação (compartilhado entre HUD e editor).
List<Widget> _bindingWidgets(BuildContext context, Rect rect, KeyBinding b,
    {required Set<String> held, required bool selected, required bool faded}) {
  switch (b) {
    case TapBinding():
      final c = _px(rect, b.x, b.y);
      return [
        Positioned(
          left: c.dx - 19,
          top: c.dy - 19,
          child: _Badge(Trigger.label(b.key),
              held: held.contains(b.key), selected: selected, faded: faded),
        ),
      ];
    case DpadBinding():
      final c = _px(rect, b.x, b.y);
      final r = b.radius * rect.height;
      Widget key(String t, Offset at) => Positioned(
            left: at.dx - 15,
            top: at.dy - 15,
            child: _Badge(Trigger.label(t),
                held: held.contains(t), selected: false, size: 30, faded: faded),
          );
      return [
        Positioned(
          left: c.dx - r,
          top: c.dy - r,
          width: r * 2,
          height: r * 2,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: faded ? .06 : .1),
              border: Border.all(
                  color: selected
                      ? Theme.of(context).colorScheme.tertiary
                      : Colors.white.withValues(alpha: faded ? .4 : .7),
                  width: selected ? 3 : 1.5),
            ),
          ),
        ),
        key(b.up, c + Offset(0, -r * .62)),
        key(b.down, c + Offset(0, r * .62)),
        key(b.left, c + Offset(-r * .62, 0)),
        key(b.right, c + Offset(r * .62, 0)),
      ];
    case SwipeBinding():
      final a = _px(rect, b.x, b.y), z = _px(rect, b.x2, b.y2);
      final cs = Theme.of(context).colorScheme;
      return [
        Positioned.fill(
          child: CustomPaint(
            painter: _ArrowPainter(a, z, selected ? cs.tertiary : Colors.white.withValues(alpha: faded ? .55 : .9)),
          ),
        ),
        Positioned(
          left: a.dx - 19,
          top: a.dy - 19,
          child: _Badge(Trigger.label(b.key),
              held: held.contains(b.key), selected: selected, faded: faded),
        ),
      ];
    case AimBinding():
      final tl = _px(rect, b.x, b.y);
      return [
        Positioned(
          left: tl.dx,
          top: tl.dy,
          width: b.w * rect.width,
          height: b.h * rect.height,
          child: CustomPaint(
            painter: _DashedRectPainter(
                selected ? Theme.of(context).colorScheme.tertiary : Colors.white.withValues(alpha: faded ? .35 : .7)),
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _Badge(Trigger.label(b.toggle),
                      held: held.contains(b.toggle), size: 30, faded: faded),
                  const SizedBox(width: 6),
                  Text('Câmera / mira',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: faded ? .6 : .95),
                          fontSize: 12,
                          shadows: const [Shadow(blurRadius: 3)])),
                ]),
              ),
            ),
          ),
        ),
      ];
  }
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter(this.a, this.b, this.color);
  final Offset a, b;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(a, b, p);
    final ang = math.atan2(b.dy - a.dy, b.dx - a.dx);
    for (final s in [-1, 1]) {
      canvas.drawLine(
          b, b - Offset(math.cos(ang + s * .5), math.sin(ang + s * .5)) * 12, p);
    }
    canvas.drawCircle(b, 5, p..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.a != a || old.b != b || old.color != color;
}

class _DashedRectPainter extends CustomPainter {
  _DashedRectPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    const dash = 8.0, gap = 6.0;
    void line(Offset a, Offset b) {
      final total = (b - a).distance;
      final dir = (b - a) / total;
      for (var d = 0.0; d < total; d += dash + gap) {
        canvas.drawLine(a + dir * d, a + dir * math.min(d + dash, total), p);
      }
    }

    line(Offset.zero, Offset(size.width, 0));
    line(Offset(size.width, 0), Offset(size.width, size.height));
    line(Offset(size.width, size.height), Offset(0, size.height));
    line(Offset(0, size.height), Offset.zero);
  }

  @override
  bool shouldRepaint(_DashedRectPainter old) => old.color != color;
}

// --------------------------------------------------------------------- editor
class _Editor extends StatelessWidget {
  const _Editor({required this.controller, required this.profile, required this.rect});
  final KeymapController controller;
  final KeymapProfile profile;
  final Rect rect;

  double _dx(Offset d) => d.dx / rect.width;
  double _dy(Offset d) => d.dy / rect.height;
  static double _c(double v) => v.clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final held = controller.engine.held;
    final children = <Widget>[
      // Fundo: clicar fora seleciona nada.
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            controller.selectedId = null;
            controller.notifyChanged();
          },
          child: ColoredBox(color: Colors.black.withValues(alpha: .35)),
        ),
      ),
    ];

    for (final b in profile.bindings) {
      final sel = b.id == controller.selectedId;
      children.addAll(_bindingWidgets(context, rect, b, held: held, selected: sel, faded: false)
          .map((w) => _interactive(w, b)));
      if (sel) children.addAll(_handles(context, b));
    }

    return Stack(fit: StackFit.expand, children: [
      ...children,
      Positioned(
        left: rect.left + 12,
        right: 12,
        top: rect.top + 10,
        child: Center(child: _Toolbar(controller: controller, profile: profile, cs: cs)),
      ),
      if (controller.selected != null)
        Positioned(
          left: rect.left + 12,
          right: 12,
          bottom: 12,
          child: Center(child: _Inspector(controller: controller, binding: controller.selected!)),
        ),
    ]);
  }

  /// Torna arrastável o widget de um botão (os elementos decorativos do
  /// direcional também: arrastar qualquer parte move o conjunto).
  Widget _interactive(Widget w, KeyBinding b) {
    if (w is! Positioned) return w;
    // Setas e a moldura de deslize só decoram.
    if (w.child is CustomPaint && b is SwipeBinding) return IgnorePointer(child: w);
    return Positioned(
      left: w.left,
      top: w.top,
      width: w.width,
      height: w.height,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (_) => _select(b),
        onPanStart: (_) => _select(b),
        onPanUpdate: (d) => _move(b, d.delta),
        child: w.child,
      ),
    );
  }

  void _select(KeyBinding b) {
    if (controller.selectedId == b.id) return;
    controller.selectedId = b.id;
    controller.notifyChanged();
  }

  void _move(KeyBinding b, Offset delta) {
    final dx = _dx(delta), dy = _dy(delta);
    switch (b) {
      case TapBinding():
        b.x = _c(b.x + dx);
        b.y = _c(b.y + dy);
      case DpadBinding():
        b.x = _c(b.x + dx);
        b.y = _c(b.y + dy);
      case SwipeBinding():
        // Arrastar o emblema desloca o gesto inteiro.
        final nx = b.x + dx, ny = b.y + dy;
        final mx = nx - b.x, my = ny - b.y;
        if (nx >= 0 && nx <= 1 && b.x2 + mx >= 0 && b.x2 + mx <= 1) {
          b.x += mx;
          b.x2 += mx;
        }
        if (ny >= 0 && ny <= 1 && b.y2 + my >= 0 && b.y2 + my <= 1) {
          b.y += my;
          b.y2 += my;
        }
      case AimBinding():
        b.x = (b.x + dx).clamp(0.0, 1.0 - b.w);
        b.y = (b.y + dy).clamp(0.0, 1.0 - b.h);
    }
    controller.notifyChanged();
  }

  /// Alças de redimensionamento do botão selecionado.
  List<Widget> _handles(BuildContext context, KeyBinding b) {
    Widget handle(Offset at, void Function(Offset) onDrag, {IconData? icon}) => Positioned(
          left: at.dx - 13,
          top: at.dy - 13,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (d) => onDrag(d.delta),
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.tertiary,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: icon == null ? null : Icon(icon, size: 14, color: Colors.black87),
            ),
          ),
        );

    switch (b) {
      case DpadBinding():
        final c = _px(rect, b.x, b.y);
        final r = b.radius * rect.height;
        return [
          handle(c + Offset(r, 0), (d) {
            b.radius = (b.radius + d.dx / rect.height).clamp(.04, .4);
            controller.notifyChanged();
          }, icon: Icons.open_in_full_rounded),
        ];
      case SwipeBinding():
        return [
          handle(_px(rect, b.x2, b.y2), (d) {
            b.x2 = _c(b.x2 + _dx(d));
            b.y2 = _c(b.y2 + _dy(d));
            controller.notifyChanged();
          }, icon: Icons.arrow_forward_rounded),
        ];
      case AimBinding():
        return [
          handle(_px(rect, b.x + b.w, b.y + b.h), (d) {
            b.w = (b.w + _dx(d)).clamp(.1, 1.0 - b.x);
            b.h = (b.h + _dy(d)).clamp(.1, 1.0 - b.y);
            controller.notifyChanged();
          }, icon: Icons.open_in_full_rounded),
        ];
      case TapBinding():
        return const [];
    }
  }
}

// -------------------------------------------------------------------- toolbar
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.controller, required this.profile, required this.cs});
  final KeymapController controller;
  final KeymapProfile profile;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    Widget add(IconData icon, String label, BindingKind kind) => TextButton.icon(
          onPressed: () => controller.addBinding(kind),
          icon: Icon(icon, size: 16),
          label: Text(label),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        );
    final pkg = controller.gamePackage;
    final attached = pkg != null && profile.packages.contains(pkg);
    return Material(
      color: cs.surfaceContainerHigh.withValues(alpha: .96),
      elevation: 6,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Wrap(
          spacing: 4,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.center,
          children: [
            const Icon(Icons.edit_rounded, size: 16),
            const SizedBox(width: 4),
            SizedBox(
              width: 190,
              child: TextFormField(
                key: ValueKey(profile),
                initialValue: profile.name,
                maxLength: 60,
                onChanged: (v) {
                  if (v.trim().isNotEmpty) profile.name = v.trim();
                },
                decoration: const InputDecoration(
                  isDense: true,
                  counterText: '',
                  labelText: 'Nome do perfil',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            add(Icons.touch_app_rounded, 'Toque', BindingKind.tap),
            add(Icons.gamepad_rounded, 'Direcional', BindingKind.dpad),
            add(Icons.swipe_rounded, 'Deslizar', BindingKind.swipe),
            add(Icons.gps_fixed_rounded, 'Mira', BindingKind.aim),
            if (pkg != null)
              FilterChip(
                visualDensity: VisualDensity.compact,
                label: Text('Usar em $pkg', style: const TextStyle(fontSize: 12)),
                selected: attached,
                onSelected: (v) {
                  if (v) {
                    profile.packages = {...profile.packages, pkg}.toList();
                  } else {
                    profile.packages = profile.packages.where((p) => p != pkg).toList();
                  }
                  controller.notifyChanged();
                },
              ),
            const SizedBox(width: 8),
            TextButton(onPressed: controller.cancelEdit, child: const Text('Cancelar')),
            FilledButton.icon(
              onPressed: controller.saveEdit,
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('Salvar'),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ inspetor
class _Inspector extends StatelessWidget {
  const _Inspector({required this.controller, required this.binding});
  final KeymapController controller;
  final KeyBinding binding;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final b = binding;

    Widget keyField(String label, String value, void Function(String) set) {
      final waiting = controller.capturing;
      return Column(mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 2),
        Row(mainAxisSize: MainAxisSize.min, children: [
          OutlinedButton(
            onPressed: waiting
                ? null
                : () => controller.captureTrigger((t) {
                      if (t != null) set(t);
                      controller.notifyChanged();
                    }),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(58, 32),
            ),
            child: Text(waiting ? '…' : Trigger.label(value)),
          ),
          PopupMenuButton<String>(
            tooltip: 'Botão do mouse',
            icon: const Icon(Icons.mouse_rounded, size: 17),
            padding: EdgeInsets.zero,
            onSelected: (t) {
              set(t);
              controller.notifyChanged();
            },
            itemBuilder: (_) => [
              for (final t in [
                Trigger.mouseLeft,
                Trigger.mouseRight,
                Trigger.mouseMiddle,
                Trigger.wheelUp,
                Trigger.wheelDown,
              ])
                PopupMenuItem(value: t, child: Text(Trigger.label(t))),
            ],
          ),
        ]),
      ]);
    }

    final fields = <Widget>[];
    String title;
    switch (b) {
      case TapBinding():
        title = 'Toque';
        fields.add(keyField('Tecla', b.key, (t) => b.key = t));
      case SwipeBinding():
        title = 'Deslizar';
        fields.add(keyField('Tecla', b.key, (t) => b.key = t));
      case DpadBinding():
        title = 'Direcional';
        fields.addAll([
          keyField('Cima', b.up, (t) => b.up = t),
          keyField('Baixo', b.down, (t) => b.down = t),
          keyField('Esquerda', b.left, (t) => b.left = t),
          keyField('Direita', b.right, (t) => b.right = t),
        ]);
      case AimBinding():
        title = 'Mira com o mouse';
        fields.add(keyField('Liga/desliga', b.toggle, (t) => b.toggle = t));
        fields.add(SizedBox(
          width: 190,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Sensibilidade ${b.sensitivity.toStringAsFixed(1)}',
                style: Theme.of(context).textTheme.labelSmall),
            Slider(
              min: .2,
              max: 3,
              value: b.sensitivity.clamp(.2, 3.0),
              onChanged: (v) {
                b.sensitivity = double.parse(v.toStringAsFixed(1));
                controller.notifyChanged();
              },
            ),
          ]),
        ));
    }

    return Material(
      color: cs.surfaceContainerHigh.withValues(alpha: .96),
      elevation: 6,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.center,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (controller.capturing)
              Text('Pressione a tecla… (Esc cancela)',
                  style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
            ...fields,
            IconButton(
              tooltip: 'Excluir',
              onPressed: controller.removeSelected,
              icon: Icon(Icons.delete_outline_rounded, color: cs.error),
            ),
          ],
        ),
      ),
    );
  }
}
