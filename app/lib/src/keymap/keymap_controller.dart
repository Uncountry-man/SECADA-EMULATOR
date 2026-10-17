import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/app_log.dart';
import '../vm/vm_controller.dart';
import 'keymap_engine.dart';
import 'keymap_models.dart';
import 'keymap_store.dart';
import 'touch_injector.dart';

/// Estado do mapeador de teclas: liga/desliga, perfil ativo, edição.
///
/// Ligar o mapeador adiciona à VM uma tela de toque (ver
/// [VmController.enableTouchDevice]); com ela presente o mouse do SECADA Emulator passa a
/// agir como um dedo e as teclas mapeadas viram toques.
class KeymapController extends ChangeNotifier {
  KeymapController(this.vm, {KeymapStore? store}) : store = store ?? KeymapStore() {
    injector = TouchInjector(vm.sendTouchEvents);
    engine = KeymapEngine(injector, aspect: () => vm.displayAspect);
    vm.addListener(_onVm);
  }

  final VmController vm;
  final KeymapStore store;
  late final TouchInjector injector;
  late final KeymapEngine engine;

  bool enabled = false;
  bool busy = false;

  /// Pacote do app em primeiro plano no Android (null = desconhecido).
  String? foregroundPackage;

  /// Apps do sistema: um perfil de jogo nunca é associado a eles.
  static const systemPackages = {
    'android',
    'com.android.launcher3',
    'com.android.systemui',
    'com.android.settings',
    'com.android.documentsui',
    'com.android.packageinstaller',
    'com.google.android.packageinstaller',
  };

  /// O app em primeiro plano, se for um app de usuário (candidato a perfil).
  String? get gamePackage {
    final p = foregroundPackage;
    return p == null || systemPackages.contains(p) ? null : p;
  }

  /// Perfil em uso (null = nenhum: as teclas passam direto ao Android).
  KeymapProfile? profile;

  /// O usuário escolheu o perfil à mão: não troca sozinho por app.
  bool pinned = false;

  // --------------------------------------------------------------- edição
  bool editing = false;

  /// Cópia de trabalho do perfil em edição.
  KeymapProfile? draft;
  KeymapProfile? _editTarget;
  String? selectedId;

  /// Quando não nulo, a próxima tecla pressionada é entregue a este callback
  /// (null com Esc = cancelar).
  void Function(String? trigger)? _capture;
  bool get capturing => _capture != null;

  Timer? _poll;

  Future<void> init() async {
    await store.load();
    engine.sensitivity = store.prefs.sensitivity;
  }

  KeymapPrefs get prefs => store.prefs;

  // ---------------------------------------------------------- ligar/desligar
  Future<bool> setEnabled(bool value) async {
    if (busy || enabled == value) return enabled == value;
    busy = true;
    notifyListeners();
    try {
      if (value) {
        final ok = await vm.enableTouchDevice();
        if (!ok) return false;
        enabled = true;
        await _detectForeground();
        _selectForPackage();
        _poll = Timer.periodic(const Duration(seconds: 3), (_) => _detectForeground());
      } else {
        await _shutDown();
      }
      return true;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _shutDown() async {
    _poll?.cancel();
    _poll = null;
    if (editing) cancelEdit();
    engine.setProfile(null);
    engine.setPaused(false);
    injector.upAll();
    enabled = false;
    await vm.disableTouchDevice();
  }

  void _onVm() {
    // A tela de toque some junto com a VM (parada, reinício do Android).
    if (enabled && !busy && (vm.state != VmState.running || !vm.touchDeviceReady)) {
      _poll?.cancel();
      _poll = null;
      engine.setProfile(null);
      enabled = false;
      editing = false;
      draft = null;
      notifyListeners();
    }
  }

  // ------------------------------------------------------- perfil por app
  Future<void> _detectForeground() async {
    final adb = vm.adb;
    if (adb == null || !vm.adbReady || editing) return;
    try {
      final r = await adb.shell('dumpsys window | grep -m1 mCurrentFocus',
          timeout: const Duration(seconds: 6));
      final m = RegExp(r'\s([A-Za-z0-9_.]+)/[A-Za-z0-9_.$]+\}').firstMatch(r.text);
      final pkg = m?.group(1);
      if (pkg != null && pkg != foregroundPackage) {
        foregroundPackage = pkg;
        if (!pinned && prefs.autoProfile) _selectForPackage();
        notifyListeners();
      }
    } catch (_) {}
  }

  void _selectForPackage() {
    final pkg = foregroundPackage;
    final p = pkg == null ? null : store.forPackage(pkg);
    _apply(p);
  }

  void _apply(KeymapProfile? p) {
    profile = p;
    engine.setProfile(enabled && !editing ? p : null);
    notifyListeners();
  }

  /// Escolha manual do perfil (null = nenhum). Mantém a escolha até o usuário
  /// religar a troca automática.
  void selectProfile(KeymapProfile? p) {
    pinned = p != null;
    _apply(p);
  }

  Future<void> setAutoProfile(bool v) async {
    prefs.autoProfile = v;
    if (v) {
      pinned = false;
      _selectForPackage();
    }
    await store.savePrefs();
    notifyListeners();
  }

  Future<void> setShowHud(bool v) async {
    prefs.showHud = v;
    await store.savePrefs();
    notifyListeners();
  }

  Future<void> setSensitivity(double v, {bool persist = true}) async {
    prefs.sensitivity = v;
    engine.sensitivity = v;
    notifyListeners();
    if (persist) await store.savePrefs();
  }

  /// Modo digitação: as teclas passam ao Android (F8).
  void togglePaused() {
    engine.setPaused(!engine.paused);
    notifyListeners();
  }

  // ---------------------------------------------------------------- edição
  /// Começa a editar [source] (ou o perfil ativo). Perfis embutidos são
  /// copiados; o original não muda.
  void beginEdit([KeymapProfile? source]) {
    final src = source ?? profile;
    if (src == null || !enabled) return;
    _editTarget = src;
    draft = src.copy(
        name: store.isUser(src) || !src.builtin
            ? src.name
            : store.uniqueName('${src.name} (meu)'));
    // Num perfil sem pacote, sugere associá-lo ao app em primeiro plano.
    final pkg = gamePackage;
    if (!store.isUser(src) && pkg != null && draft!.packages.isEmpty) {
      draft!.packages = [pkg];
    }
    selectedId = null;
    editing = true;
    engine.setProfile(null);
    notifyListeners();
  }

  /// Cria um perfil novo a partir de um modelo e já abre o editor.
  void beginFromTemplate(KeymapProfile template) {
    _apply(template);
    beginEdit(template);
  }

  void beginBlank() {
    final blank = KeymapProfile(name: store.uniqueName('Novo perfil'));
    _apply(blank);
    beginEdit(blank);
  }

  Future<void> saveEdit() async {
    final d = draft;
    if (d == null) return;
    final target = _editTarget;
    KeymapProfile result;
    if (target != null && store.isUser(target)) {
      target
        ..name = d.name
        ..packages = d.packages
        ..bindings = d.bindings
        ..note = d.note;
      result = target;
    } else {
      result = d;
    }
    try {
      await store.save(result);
    } catch (e) {
      log.warn('Não foi possível salvar o perfil: $e');
    }
    _finishEdit(result);
  }

  void cancelEdit() => _finishEdit(_editTarget);

  void _finishEdit(KeymapProfile? active) {
    editing = false;
    draft = null;
    _editTarget = null;
    selectedId = null;
    _capture = null;
    // Um perfil novo cancelado antes de salvar não existe em lugar nenhum.
    profile = active != null && store.all.contains(active) ? active : null;
    engine.setProfile(enabled ? profile : null);
    notifyListeners();
  }

  Future<void> deleteProfile(KeymapProfile p) async {
    if (!store.isUser(p)) return;
    await store.delete(p);
    if (profile == p) _apply(null);
    notifyListeners();
  }

  // Alterações no rascunho (o editor chama notifyChanged após mexer).
  void notifyChanged() => notifyListeners();

  KeyBinding addBinding(BindingKind kind) {
    final d = draft!;
    final id = d.nextId();
    final KeyBinding b = switch (kind) {
      BindingKind.tap => TapBinding(id, Trigger.none, .5, .5),
      BindingKind.dpad => DpadBinding(id, x: .15, y: .68),
      BindingKind.swipe => SwipeBinding(id, Trigger.none, .5, .6, .5, .3),
      BindingKind.aim => AimBinding(id, Trigger.key(LogicalKeyboardKey.f1), .45, .1, .5, .62, 1.0),
    };
    d.bindings.add(b);
    selectedId = id;
    notifyListeners();
    return b;
  }

  void removeSelected() {
    final d = draft;
    if (d == null) return;
    d.bindings.removeWhere((b) => b.id == selectedId);
    selectedId = null;
    notifyListeners();
  }

  KeyBinding? get selected =>
      draft?.bindings.where((b) => b.id == selectedId).firstOrNull;

  // ------------------------------------------------------ captura de teclas
  /// Pede a próxima tecla. [onDone] recebe o disparador, ou null (Esc).
  void captureTrigger(void Function(String? trigger) onDone) {
    _capture = onDone;
    notifyListeners();
  }

  void cancelCapture() {
    final c = _capture;
    _capture = null;
    c?.call(null);
    notifyListeners();
  }

  /// Entrega a tecla ao pedido de captura. Retorna true se consumiu.
  bool offerKey(KeyEvent e) {
    final c = _capture;
    if (c == null) return false;
    if (e is! KeyDownEvent) return true;
    _capture = null;
    c(e.logicalKey == LogicalKeyboardKey.escape ? null : Trigger.key(e.logicalKey));
    notifyListeners();
    return true;
  }

  /// Entrega um botão do mouse ao pedido de captura (menu "Mouse").
  void offerTrigger(String trigger) {
    final c = _capture;
    if (c == null) return;
    _capture = null;
    c(trigger);
    notifyListeners();
  }

  List<KeymapProfile> get templates =>
      store.builtin.where((p) => p.name.startsWith('Modelo:')).toList();

  /// Libera tudo antes de o app fechar.
  Future<void> shutDown() async {
    if (enabled) await _shutDown();
  }

  @override
  void dispose() {
    _poll?.cancel();
    vm.removeListener(_onVm);
    engine.dispose();
    super.dispose();
  }
}
