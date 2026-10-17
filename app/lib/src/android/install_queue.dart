import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/app_log.dart';
import '../vm/vm_controller.dart';
import 'apk_installer.dart';

/// Item da fila de instalação, observado pela interface.
class InstallJob {
  InstallJob(this.path, {this.waitForAndroid = false});
  final String path;

  /// Arquivo aberto de fora do SECADA Emulator (duplo clique): se o Android ainda não
  /// estiver pronto, liga a VM e espera em vez de recusar.
  final bool waitForAndroid;
  String get fileName => p.basename(path);
  InstallPhase phase = InstallPhase.inspecting;
  double? fraction;
  String message = 'Na fila…';
  String? packageName;
  bool get finished => phase == InstallPhase.done || phase == InstallPhase.failed;
}

/// Fila sequencial de instalações (seleção de arquivos ou arrastar e soltar).
class InstallQueue extends ChangeNotifier {
  InstallQueue(this.vm);
  final VmController vm;

  final Queue<InstallJob> _pending = Queue();
  final List<InstallJob> history = [];
  InstallJob? current;
  bool _running = false;

  List<InstallJob> get pending => _pending.toList();
  bool get visible => current != null || _pending.isNotEmpty;

  /// Tipos de arquivo que o SECADA Emulator instala.
  static bool isInstallable(String path) {
    final l = path.toLowerCase();
    return l.endsWith('.apk') || l.endsWith('.xapk');
  }

  void enqueue(Iterable<String> paths, {bool fromOutside = false}) {
    for (final path in paths) {
      final job = InstallJob(path, waitForAndroid: fromOutside);
      if (!isInstallable(path)) {
        job
          ..phase = InstallPhase.failed
          ..message = 'Apenas arquivos .apk e .xapk podem ser instalados.';
        current ??= job;
        history.add(job);
        continue;
      }
      _pending.add(job);
    }
    notifyListeners();
    unawaited(_pump());
  }

  void dismiss() {
    if (current?.finished ?? false) {
      current = null;
      notifyListeners();
      unawaited(_pump());
    }
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (_pending.isNotEmpty) {
        if (current != null && !current!.finished) break;
        final job = _pending.removeFirst();
        current = job;
        notifyListeners();
        await _run(job);
        history.add(job);
        notifyListeners();
        if (_pending.isNotEmpty) {
          // Mostra o resultado brevemente antes do próximo.
          await Future<void>.delayed(const Duration(milliseconds: 1200));
          if (current == job) current = null;
        }
      }
    } finally {
      _running = false;
    }
  }

  /// Android pronto de verdade: ADB conectado e boot concluído (inclui a
  /// tradução ARM, sem a qual um app ARM recém-instalado não abriria).
  bool get _androidReady => vm.adbReady && vm.state == VmState.running;

  /// Espera o Android ficar pronto, ligando a VM se estiver desligada.
  /// Retorna false se a VM falhou ou o tempo acabou.
  Future<bool> _awaitAndroid(InstallJob job) async {
    job.message = 'Aguardando o Android iniciar…';
    notifyListeners();
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    var started = false;
    while (!_androidReady) {
      if (DateTime.now().isAfter(deadline)) {
        job.message = 'O Android demorou demais para iniciar.';
        return false;
      }
      if (vm.state == VmState.error) {
        job.message = 'O Android não iniciou: ${vm.error ?? 'veja os logs do SECADA Emulator'}';
        return false;
      }
      if (vm.state == VmState.stopped && !started) {
        started = true;
        log.info('Ligando a VM para instalar ${job.fileName}');
        unawaited(vm.start());
      } else if (vm.state == VmState.stopped && started) {
        // Iniciou e voltou a "desligado" sem erro: foi desligada de propósito.
        job.message = 'O Android foi desligado antes de a instalação começar.';
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return true;
  }

  Future<void> _run(InstallJob job) async {
    if (job.waitForAndroid && !_androidReady && !await _awaitAndroid(job)) {
      job.phase = InstallPhase.failed;
      return;
    }
    final adb = vm.adb;
    if (adb == null || !vm.adbReady) {
      job
        ..phase = InstallPhase.failed
        ..message = 'O Android ainda não está pronto. Inicie a VM e aguarde o '
            'boot terminar.';
      return;
    }
    log.info('Instalando ${job.path}');
    try {
      final installer =
          ApkInstaller(adb, armTranslation: vm.settings.armTranslation, arm64: vm.arm64Ready);
      await for (final pr in installer.install(job.path)) {
        job.phase = pr.phase;
        job.fraction = pr.fraction;
        job.message = pr.message ?? job.message;
        job.packageName = pr.info?.packageName ?? job.packageName;
        notifyListeners();
      }
      log.info('Instalação de ${job.fileName}: ${job.phase.name} — ${job.message}');
    } catch (e, st) {
      log.error('Instalação falhou', e, st);
      job
        ..phase = InstallPhase.failed
        ..message = 'Erro inesperado: $e';
    }
  }
}
