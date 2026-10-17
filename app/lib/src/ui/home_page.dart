import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../android/android_controller.dart';
import '../android/apk_installer.dart';
import '../android/install_queue.dart';
import '../core/app_log.dart';
import '../core/native_bridge.dart';
import '../core/paths.dart';
import '../host/host_info.dart';
import '../input/keysym.dart';
import '../keymap/keymap_controller.dart';
import '../vm/vm_controller.dart';
import 'apps_dialog.dart';
import 'boot_screen.dart';
import 'display_view.dart';
import 'keymap_panel.dart';
import 'settings_dialog.dart';
import 'side_bar.dart';
import 'theme.dart';
import 'title_bar.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});
  final VmController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  VmController get vm => widget.controller;
  final NativeBridge _native = NativeBridge.instance;
  late final InstallQueue _installs = InstallQueue(vm);
  late final KeymapController _keymap = KeymapController(vm);
  StreamSubscription<NativeEvent>? _sub;
  bool _maximized = false;
  bool _fullscreen = false;
  bool _dragOver = false;
  bool _closing = false;

  AndroidController? get _android =>
      vm.adb != null && vm.adbReady ? AndroidController(vm.adb!) : null;

  @override
  void initState() {
    super.initState();
    _sub = _native.events.listen((e) {
      switch (e.type) {
        case 'window':
          setState(() {
            _maximized = e.data['maximized'] == true;
            _fullscreen = e.data['fullscreen'] == true;
          });
        case 'closeRequested':
          _handleClose(fromSignal: e.data['fromSignal'] == true);
        case 'dragOver':
          if (!_dragOver) setState(() => _dragOver = true);
        case 'dragLeave':
          if (_dragOver) setState(() => _dragOver = false);
        case 'openFiles':
          final paths = (e.data['paths'] as List?)?.cast<String>() ?? const [];
          log.info('Arquivos abertos de fora: $paths');
          if (paths.isNotEmpty) _installs.enqueue(paths, fromOutside: true);
        case 'dragDrop':
          setState(() => _dragOver = false);
          final paths = (e.data['paths'] as List?)?.cast<String>() ?? const [];
          log.info('Arquivos soltos: $paths');
          if (paths.isNotEmpty && _requireAndroid()) _installs.enqueue(paths);
      }
    });
    vm.addListener(_onVmChanged);
    _keymap.init();
    // Arquivos passados na linha de comando (duplo clique num .apk/.xapk).
    _native.appReady().then((paths) {
      if (paths.isNotEmpty && mounted) {
        log.info('Arquivos da linha de comando: $paths');
        _installs.enqueue(paths, fromOutside: true);
      }
    }).catchError((Object e) => log.warn('app.ready falhou: $e'));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncWindowAspect(resize: true);
      vm.autoStartIfEnabled();
    });
  }

  double? _lockedAspect;
  Timer? _snapTimer;
  Size? _lastWindowSize;

  /// Ao terminar um redimensionamento manual, ajusta a altura da janela para
  /// que a área do Android tenha exatamente a proporção da tela (sem faixas).
  void _scheduleSnap(Size size) {
    if (_lastWindowSize == size) return;
    _lastWindowSize = size;
    _snapTimer?.cancel();
    if (_maximized || _fullscreen) return;
    _snapTimer = Timer(const Duration(milliseconds: 400), () {
      if (_maximized || _fullscreen || !mounted) return;
      final cw = size.width - SecadaTheme.sideBarWidth;
      final ch = size.height - SecadaTheme.titleBarHeight;
      final wantH = cw / vm.displayAspect;
      if ((wantH - ch).abs() > 2) {
        _native.resizeWindow(size.width.round(),
            (wantH + SecadaTheme.titleBarHeight).round());
      }
    });
  }

  /// Mantém a janela com a mesma proporção da tela do Android, para que a
  /// imagem preencha todo o espaço sem faixas.
  void _syncWindowAspect({bool resize = false}) {
    final aspect = vm.displayAspect;
    if (!resize && _lockedAspect != null && (aspect - _lockedAspect!).abs() < 0.01) {
      return;
    }
    final changed = _lockedAspect != null && (aspect - _lockedAspect!).abs() >= 0.01;
    _lockedAspect = aspect;
    _native.setContentAspect(
      aspect,
      chromeWidth: SecadaTheme.sideBarWidth.round(),
      chromeHeight: SecadaTheme.titleBarHeight.round(),
      preferredWidth: vm.settings.width,
      resize: resize || changed,
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _snapTimer?.cancel();
    vm.removeListener(_onVmChanged);
    _keymap.dispose();
    super.dispose();
  }

  VmState? _lastState;
  void _onVmChanged() {
    _syncWindowAspect();
    if (_lastState != vm.state) {
      _lastState = vm.state;
      _native.setWindowTitle('SECADA Emulator — ${vm.state.label}');
      if (vm.state == VmState.running && vm.warnings.isNotEmpty) {
        _toast(vm.warnings.join('\n'));
      }
    }
  }

  // ----------------------------------------------------------------- ações
  Future<void> _handleClose({bool fromSignal = false}) async {
    if (_closing) return;
    if (vm.state.isActive || vm.state == VmState.preparing) {
      if (!fromSignal) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Fechar o SECADA Emulator?'),
            content: const Text(
              'O Android será desligado com segurança antes de fechar. '
              'Seus aplicativos e dados são preservados.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Desligar e fechar'),
              ),
            ],
          ),
        );
        if (ok != true) return;
      }
      setState(() => _closing = true);
      await _keymap.shutDown();
      await vm.stop();
    }
    _closing = true;
    log.info('Fechando aplicativo');
    await log.close();
    await _native.closeWindow();
  }

  Future<void> _pickApk() async {
    if (!_requireAndroid()) return;
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Aplicativos Android (APK, XAPK)', extensions: ['apk', 'xapk']),
      ],
    );
    if (files.isNotEmpty) _installs.enqueue(files.map((f) => f.path));
  }

  bool _requireAndroid() {
    if (_android != null) return true;
    _toast(
      vm.state == VmState.booting
          ? 'Aguarde o Android terminar de inicializar.'
          : 'Inicie o Android primeiro.',
    );
    return false;
  }

  Future<void> _key(int keycode) async {
    final a = _android;
    if (a == null) return;
    try {
      await a.pressKey(keycode);
    } catch (e) {
      _toast('$e');
    }
  }

  /// Voltar/Início são enviados como teclas nativas pelo RFB (instantâneo,
  /// sem iniciar um processo `input` no Android); ADB é o fallback.
  Future<void> _navKey(int scancode, int keysym, int androidKeycode) async {
    if (vm.displayConnected && await _native.tapScancode(scancode, keysym)) {
      return;
    }
    await _key(androidKeycode);
  }

  void _back() => _navKey(XtScancode.back, Keysym.xf86Back, AndroidKey.back);
  void _home() =>
      _navKey(XtScancode.homePage, Keysym.xf86HomePage, AndroidKey.home);

  Future<void> _rotate() async {
    if (!_requireAndroid()) return;
    await vm.toggleQuickRotation();
  }

  Future<void> _togglePower() async {
    if (vm.state.isActive) {
      await vm.stop();
    } else {
      await vm.start();
    }
  }

  Future<void> _reboot() async {
    if (!vm.state.isActive) return;
    await vm.rebootAndroid();
  }

  Future<void> _toggleFullscreen() => _native.setFullscreen(!_fullscreen);

  Future<void> _openSettings() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => SettingsDialog(controller: vm),
    );
    if (saved == true && vm.state.isActive && mounted) {
      _toast(
        'Configurações salvas. Elas serão aplicadas na próxima '
        'inicialização da VM.',
      );
    }
  }

  Future<void> _openKeymap() async {
    if (!_requireAndroid()) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black26,
      builder: (_) => KeymapPanel(controller: _keymap),
    );
  }

  Future<void> _openApps() async {
    final a = _android;
    if (a == null) {
      _requireAndroid();
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => AppsDialog(android: a, onInstall: _pickApk),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
      );
  }

  /// Atalhos do host: F11 alterna tela cheia; Esc sai da tela cheia quando
  /// "Esc = Voltar" estiver desativado.
  bool _hostShortcut(KeyEvent e) {
    if (e is! KeyDownEvent) {
      return e.logicalKey == LogicalKeyboardKey.f11 ||
          (e.logicalKey == LogicalKeyboardKey.escape && !vm.settings.escAsBack);
    }
    if (e.logicalKey == LogicalKeyboardKey.f11) {
      _toggleFullscreen();
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape && !vm.settings.escAsBack) {
      if (_fullscreen) _native.setFullscreen(false);
      return true;
    }
    return false;
  }

  // -------------------------------------------------------------- interface
  @override
  Widget build(BuildContext context) {
    _scheduleSnap(MediaQuery.sizeOf(context));
    final body = Column(
      children: [
        if (!_fullscreen) TitleBar(controller: vm, maximized: _maximized),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildStage(context)),
              if (!_fullscreen)
                ListenableBuilder(
                  listenable: Listenable.merge([vm, _keymap]),
                  builder: (context, _) => SideBar(
                    vmState: vm.state,
                    androidReady: vm.adbReady,
                    fullscreen: _fullscreen,
                    rotated: vm.quickRotated,
                    onInstall: _pickApk,
                    onApps: _openApps,
                    onBack: _back,
                    onHome: _home,
                    onRecents: () => _key(AndroidKey.appSwitch),
                    onRotate: _rotate,
                    onKeymap: _openKeymap,
                    keymapOn: _keymap.enabled,
                    onReboot: _reboot,
                    onPower: _togglePower,
                    onSettings: _openSettings,
                    onFullscreen: _toggleFullscreen,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
    final rounded = !_maximized && !_fullscreen;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ClipRRect(
        borderRadius: BorderRadius.circular(rounded ? 12 : 0),
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: SecadaTheme.surfaceDeep, child: body)),
            if (rounded) const _ResizeEdges(),
            if (_closing)
              const Positioned.fill(
                child: _BlockingOverlay(text: 'Desligando o Android…'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStage(BuildContext context) {
    // Arrastar e soltar é tratado pelo backend nativo (eventos dragOver /
    // dragLeave / dragDrop), para toda a janela.
    return Container(
      color: SecadaTheme.surfaceDeep,
      child: Stack(
        children: [
          Positioned.fill(
            child: ListenableBuilder(
              listenable: vm,
              builder: (context, _) {
                if (vm.state == VmState.error) {
                  return _ErrorView(controller: vm);
                }
                final booting = vm.state == VmState.preparing ||
                    vm.state == VmState.booting ||
                    vm.state == VmState.stopping;
                if (vm.textureId == null && !booting) {
                  return _IdleView(controller: vm, onSettings: _openSettings);
                }
                // A tela do Android fica montada por baixo durante o boot (o
                // primeiro quadro já está pronto quando a cortina some).
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    if (vm.textureId != null)
                      DisplayView(
                        controller: vm,
                        keymap: _keymap,
                        onHostShortcut: _hostShortcut,
                        onBack: _back,
                      ),
                    IgnorePointer(
                      ignoring: !booting,
                      child: AnimatedOpacity(
                        opacity: booting ? 1 : 0,
                        duration: const Duration(milliseconds: 450),
                        curve: Curves.easeOut,
                        child: BootScreen(controller: vm),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          if (_dragOver) const Positioned.fill(child: _DropHint()),
          Positioned(
            right: 16,
            bottom: 16,
            child: ListenableBuilder(
              listenable: _installs,
              builder: (context, _) => _InstallPanel(
                queue: _installs,
                onLaunch: (pkg) async {
                  try {
                    await _android?.launch(pkg);
                    _installs.dismiss();
                  } catch (e) {
                    _toast('$e');
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ widgets

class _IdleView extends StatelessWidget {
  const _IdleView({required this.controller, required this.onSettings});
  final VmController controller;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final s = controller.settings;
    final h = controller.host;
    final busy =
        controller.state == VmState.preparing ||
        controller.state == VmState.booting ||
        controller.state == VmState.stopping;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.android_rounded, size: 72, color: cs.primary),
              const SizedBox(height: 12),
              Text('Android 9 · x86-64', style: tt.headlineSmall),
              const SizedBox(height: 6),
              Text(
                '${s.cpus} vCPUs · ${s.memoryMb} MB · '
                '${s.width}×${s.height} · ${s.dpi} dpi · ${s.diskGb} GB',
                style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 28),
              SizedBox(
                height: 48,
                child: FilledButton.icon(
                  onPressed: busy ? null : controller.start,
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_rounded),
                  label: Text(busy ? controller.status : 'Iniciar Android'),
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: busy ? null : onSettings,
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Configurações'),
              ),
              const SizedBox(height: 28),
              _HostSummary(host: h),
            ],
          ),
        ),
      ),
    );
  }
}

class _HostSummary extends StatelessWidget {
  const _HostSummary({required this.host});
  final HostInfo host;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    Widget row(IconData icon, String text, {Color? color}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color ?? cs.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
    final ok = host.kvmUsable;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          row(
            ok ? Icons.check_circle : Icons.error,
            ok
                ? 'Aceleração KVM disponível'
                : 'KVM indisponível: ${host.kvmError}',
            color: ok ? const Color(0xFF4CAF7D) : cs.error,
          ),
          row(Icons.memory, '${host.cpuModel} · ${host.logicalCpus} threads'),
          row(
            Icons.storage,
            'RAM: ${host.memTotalMb} MB (livre: ${host.memAvailableMb} MB)',
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.controller});
  final VmController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Card(
          color: cs.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.error_outline, color: cs.error),
                    const SizedBox(width: 10),
                    Text(
                      'Não foi possível executar o Android',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      controller.error ?? 'Erro desconhecido.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () =>
                          Process.run('xdg-open', [SecadaPaths.instance.logsDir]),
                      icon: const Icon(Icons.folder_open, size: 18),
                      label: const Text('Abrir logs'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: controller.start,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Tentar novamente'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DropHint extends StatelessWidget {
  const _DropHint();
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.10),
          border: Border.all(color: cs.primary, width: 2),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.download_rounded, size: 48, color: cs.primary),
            const SizedBox(height: 8),
            Text(
              'Solte o APK ou XAPK para instalar',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _InstallPanel extends StatelessWidget {
  const _InstallPanel({required this.queue, required this.onLaunch});
  final InstallQueue queue;
  final void Function(String packageName) onLaunch;

  @override
  Widget build(BuildContext context) {
    final job = queue.current;
    if (job == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final failed = job.phase == InstallPhase.failed;
    final done = job.phase == InstallPhase.done;
    final pending = queue.pending.length;
    return Material(
      elevation: 3,
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: (MediaQuery.sizeOf(context).width - SecadaTheme.sideBarWidth - 32)
            .clamp(200.0, 360.0),
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  failed
                      ? Icons.error_outline
                      : done
                      ? Icons.check_circle_outline
                      : Icons.android,
                  color: failed
                      ? cs.error
                      : done
                      ? const Color(0xFF4CAF7D)
                      : cs.primary,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    job.packageName ?? job.fileName,
                    style: tt.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (job.finished)
                  IconButton(
                    tooltip: 'Fechar',
                    visualDensity: VisualDensity.compact,
                    onPressed: queue.dismiss,
                    icon: const Icon(Icons.close, size: 18),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                job.message,
                style: tt.bodySmall?.copyWith(
                  color: failed ? cs.error : cs.onSurfaceVariant,
                ),
              ),
            ),
            if (!job.finished) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: LinearProgressIndicator(
                  value: job.phase == InstallPhase.transferring
                      ? job.fraction
                      : null,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ],
            if (pending > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('$pending na fila', style: tt.labelSmall),
              ),
            if (done && job.packageName != null)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6, right: 8),
                  child: FilledButton.tonalIcon(
                    onPressed: () => onLaunch(job.packageName!),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Abrir'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BlockingOverlay extends StatelessWidget {
  const _BlockingOverlay({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.55),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(text, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}

/// Bordas invisíveis para redimensionar a janela sem decoração.
class _ResizeEdges extends StatelessWidget {
  const _ResizeEdges();

  static const double t = 6;

  // Valores de GdkWindowEdge.
  static const nw = 0, n = 1, ne = 2, w = 3, e = 4, sw = 5, s = 6, se = 7;

  Widget _edge(int edge, MouseCursor cursor) => MouseRegion(
    cursor: cursor,
    child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => NativeBridge.instance.startWindowResize(edge),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          left: t,
          right: t,
          top: 0,
          height: t,
          child: _edge(n, SystemMouseCursors.resizeUp),
        ),
        Positioned(
          left: t,
          right: t,
          bottom: 0,
          height: t,
          child: _edge(s, SystemMouseCursors.resizeDown),
        ),
        Positioned(
          top: t,
          bottom: t,
          left: 0,
          width: t,
          child: _edge(w, SystemMouseCursors.resizeLeft),
        ),
        Positioned(
          top: t,
          bottom: t,
          right: 0,
          width: t,
          child: _edge(e, SystemMouseCursors.resizeRight),
        ),
        Positioned(
          left: 0,
          top: 0,
          width: t * 2,
          height: t * 2,
          child: _edge(nw, SystemMouseCursors.resizeUpLeft),
        ),
        Positioned(
          right: 0,
          top: 0,
          width: t * 2,
          height: t * 2,
          child: _edge(ne, SystemMouseCursors.resizeUpRight),
        ),
        Positioned(
          left: 0,
          bottom: 0,
          width: t * 2,
          height: t * 2,
          child: _edge(sw, SystemMouseCursors.resizeDownLeft),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          width: t * 2,
          height: t * 2,
          child: _edge(se, SystemMouseCursors.resizeDownRight),
        ),
      ],
    );
  }
}
