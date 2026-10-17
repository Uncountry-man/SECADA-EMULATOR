import 'package:flutter/material.dart';

import '../core/native_bridge.dart';
import '../vm/vm_controller.dart';
import 'theme.dart';

/// Barra superior própria: nome, estado da VM e botões da janela.
/// Arrastar move a janela; duplo clique maximiza/restaura.
class TitleBar extends StatelessWidget {
  const TitleBar({super.key, required this.controller, required this.maximized});
  final VmController controller;
  final bool maximized;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final native = NativeBridge.instance;
    return Container(
      height: SecadaTheme.titleBarHeight,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4))),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => native.startWindowDrag(),
              onDoubleTap: native.toggleMaximize,
              child: Padding(
                padding: const EdgeInsets.only(left: 14),
                child: Row(
                  children: [
                    const _Logo(),
                    const SizedBox(width: 16),
                    ListenableBuilder(
                      listenable: controller,
                      builder: (context, _) => _StateChip(controller: controller),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _WindowButton(
            icon: Icons.remove,
            tooltip: 'Minimizar',
            onPressed: native.minimizeWindow,
          ),
          _WindowButton(
            icon: maximized ? Icons.filter_none : Icons.crop_square,
            iconSize: maximized ? 14 : 16,
            tooltip: maximized ? 'Restaurar' : 'Maximizar',
            onPressed: native.toggleMaximize,
          ),
          _WindowButton(
            icon: Icons.close,
            tooltip: 'Fechar',
            danger: true,
            onPressed: native.requestClose,
          ),
        ],
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();
  @override
  Widget build(BuildContext context) {
    return Image.asset('assets/secada-logo-transparente.png',
        height: 24, filterQuality: FilterQuality.high);
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.controller});
  final VmController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = SecadaTheme.stateColor(cs, controller.state.name);
    final busy = controller.state == VmState.preparing ||
        controller.state == VmState.booting ||
        controller.state == VmState.stopping;
    final detail = controller.status != controller.state.label ? controller.status : null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          else
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          const SizedBox(width: 8),
          Text(controller.state.label,
              style: Theme.of(context).textTheme.labelMedium),
          if (detail != null) ...[
            Text('  ·  ', style: TextStyle(color: cs.outline)),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(detail,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: cs.onSurfaceVariant)),
            ),
          ],
        ],
      ),
    );
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.iconSize = 16,
    this.danger = false,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double iconSize;
  final bool danger;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = _hover
        ? (widget.danger ? const Color(0xFFC42B1C) : cs.surfaceContainerHighest)
        : Colors.transparent;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 46,
            height: SecadaTheme.titleBarHeight,
            color: bg,
            alignment: Alignment.center,
            child: Icon(widget.icon,
                size: widget.iconSize,
                color: _hover && widget.danger ? Colors.white : cs.onSurface),
          ),
        ),
      ),
    );
  }
}
