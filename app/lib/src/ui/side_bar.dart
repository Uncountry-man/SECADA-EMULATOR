import 'package:flutter/material.dart';

import '../vm/vm_controller.dart';
import 'theme.dart';

/// Barra lateral direita com as ações do emulador.
class SideBar extends StatelessWidget {
  const SideBar({
    super.key,
    required this.vmState,
    required this.androidReady,
    required this.fullscreen,
    required this.rotated,
    required this.onInstall,
    required this.onApps,
    required this.onBack,
    required this.onHome,
    required this.onRecents,
    required this.onRotate,
    required this.onKeymap,
    required this.keymapOn,
    required this.onReboot,
    required this.onPower,
    required this.onSettings,
    required this.onFullscreen,
  });

  final VmState vmState;
  final bool androidReady;
  final bool fullscreen;
  final bool rotated;
  final VoidCallback onInstall;
  final VoidCallback onApps;
  final VoidCallback onBack;
  final VoidCallback onHome;
  final VoidCallback onRecents;
  final VoidCallback onRotate;
  final VoidCallback onKeymap;

  /// Mapeador de teclas ligado.
  final bool keymapOn;
  final VoidCallback onReboot;
  final VoidCallback onPower;
  final VoidCallback onSettings;
  final VoidCallback onFullscreen;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final active = vmState.isActive;
    final running = vmState == VmState.running;
    final transitioning = vmState == VmState.preparing || vmState == VmState.stopping;
    return Container(
      width: SecadaTheme.sideBarWidth,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(left: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4))),
      ),
      child: LayoutBuilder(builder: (context, box) {
        final items = <Widget>[
          _Btn(Icons.add_box_outlined, 'Instalar APK / XAPK', androidReady ? onInstall : null),
          _Btn(Icons.apps_rounded, 'Aplicativos instalados', androidReady ? onApps : null),
          const _Sep(),
          _Btn(Icons.arrow_back_rounded, 'Voltar (Esc)', running ? onBack : null),
          _Btn(Icons.circle_outlined, 'Início', androidReady ? onHome : null),
          _Btn(Icons.crop_square_rounded, 'Aplicativos recentes', androidReady ? onRecents : null),
          const _Sep(),
          _Btn(Icons.screen_rotation_rounded,
              rotated ? 'Voltar à orientação original' : 'Girar tela',
              androidReady ? onRotate : null,
              selected: rotated),
          _Btn(Icons.sports_esports_rounded,
              keymapOn ? 'Mapeador de teclas (ligado)' : 'Mapeador de teclas',
              running ? onKeymap : null,
              selected: keymapOn),
          _Btn(Icons.restart_alt_rounded, 'Reiniciar Android', running ? onReboot : null),
          _Btn(Icons.power_settings_new_rounded,
              active ? 'Desligar Android' : 'Iniciar Android',
              transitioning || vmState == VmState.stopping ? null : onPower,
              color: active ? cs.error : const Color(0xFF4CAF7D)),
        ];
        final bottom = <Widget>[
          _Btn(Icons.tune_rounded, 'Configurações', onSettings),
          _Btn(fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
              'Tela cheia (F11)', onFullscreen),
        ];
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight),
            child: IntrinsicHeight(
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  ...items,
                  const Spacer(),
                  ...bottom,
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _Btn extends StatelessWidget {
  const _Btn(this.icon, this.tooltip, this.onPressed, {this.selected = false, this.color});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Tooltip(
        message: tooltip,
        preferBelow: false,
        verticalOffset: 0,
        margin: const EdgeInsets.only(right: 64),
        child: IconButton(
          isSelected: selected,
          onPressed: onPressed,
          icon: Icon(icon, color: onPressed == null ? null : color),
          style: IconButton.styleFrom(
            fixedSize: const Size(42, 42),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
    );
  }
}

class _Sep extends StatelessWidget {
  const _Sep();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 14),
        child: Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
      );
}
