import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../android/adb.dart';
import '../android/arm_translation.dart';
import '../android/bundled_apps.dart';
import '../android/guest_setup.dart';
import '../android/guest_shell.dart';
import '../android/pointer_lock_watcher.dart';
import '../core/app_log.dart';
import '../core/native_bridge.dart';
import '../core/paths.dart';
import '../host/host_info.dart';
import '../host/host_power.dart';
import '../settings/vm_settings.dart';
import 'android_image.dart';
import 'disk_manager.dart';
import 'gpu.dart';
import 'initrd_overlay.dart';
import 'qemu_command.dart';
import 'qemu_locator.dart';
import 'qmp_client.dart';

enum VmState { stopped, preparing, booting, running, stopping, error }

extension VmStateLabel on VmState {
  String get label => switch (this) {
        VmState.stopped => 'Desligado',
        VmState.preparing => 'Preparando',
        VmState.booting => 'Inicializando',
        VmState.running => 'Em execução',
        VmState.stopping => 'Desligando',
        VmState.error => 'Erro',
      };
  bool get isActive =>
      this == VmState.booting || this == VmState.running || this == VmState.stopping;
}

/// Região do framebuffer que contém a imagem do Android. Normalmente é o
/// framebuffer inteiro; na rotação rápida (`wm size`) o Android desenha a
/// tela girada centralizada, e só essa área é exibida.
class DisplayViewport {
  const DisplayViewport(this.left, this.top, this.width, this.height);
  final double left, top, width, height;
  double get aspect => width / height;
}

/// Orquestra o ciclo de vida da máquina virtual Android.
class VmController extends ChangeNotifier {
  VmController({SettingsStore? store}) : _store = store ?? SettingsStore() {
    _lockWatcher.onChanged = (locked) {
      if (guestPointerLock == locked) return;
      log.info('Trava do ponteiro: o Android ${locked ? 'prendeu' : 'soltou'} o mouse');
      guestPointerLock = locked;
      notifyListeners();
    };
    _lockTimer = Timer.periodic(const Duration(seconds: 2), (_) => _lockTick());
  }

  static const vmName = 'default';

  /// Versão do provisionamento: aumentar faz VMs existentes repetirem os
  /// ajustes de primeiro boot (Wi-Fi, idioma, fuso, modo desenvolvedor...).
  static const provisionVersion = 3;

  final SettingsStore _store;
  final NativeBridge _native = NativeBridge.instance;

  VmSettings settings = const VmSettings();
  HostInfo host = const HostInfo();
  VmState state = VmState.stopped;
  String status = 'Desligado';
  String? error;
  List<String> warnings = const [];

  /// Progresso exibido na tela de inicialização (0..1) e etapa atual.
  double bootProgress = 0;
  String bootStep = '';
  bool firstBoot = false;

  /// O disco de dados foi criado nesta execução (nada a restaurar do perfil
  /// enxuto).
  bool _freshDisk = false;
  double _bootTarget = 0;
  Timer? _progressTimer;

  int? textureId;
  int fbWidth = 0;
  int fbHeight = 0;
  bool displayConnected = false;
  bool adbReady = false;

  /// Um app do Android pediu a trava do ponteiro (jogo com a câmera presa ao
  /// mouse): a janela prende o cursor do computador e envia movimento relativo.
  bool guestPointerLock = false;
  final PointerLockWatcher _lockWatcher = PointerLockWatcher();
  Timer? _lockTimer;
  bool wifiConnected = false;

  /// Rotação rápida ativa (geometria lógica trocada via `wm size`).
  bool quickRotated = false;

  /// Modo gráfico efetivo desta execução (pode ser software se a GPU não
  /// puder ser usada) e a GPU escolhida para o VirGL.
  GraphicsMode graphics = GraphicsMode.virgl;
  GpuChoice? gpu;

  /// A VM com VirGL caiu na inicialização: até reabrir o SECADA Emulator, usa software.
  bool _gpuFailed = false;

  /// O display D-Bus falhou (EGL/dmabuf do host): até reabrir o SECADA Emulator, o VirGL
  /// usa o caminho egl-headless + VNC.
  bool _dbusFailed = false;
  bool _useDbus = false;

  /// Caminho da imagem nesta execução: "dbus" (GPU, até 60 quadros/s) ou
  /// "vnc".
  String displayBackend = 'vnc';

  /// Tradução ARM ativa no Android (apps só ARM 32 bits rodam).
  bool armReady = false;

  /// Tradução ARM 64 bits ativa: apps ARM64 rodam e o Android prefere a
  /// versão ARM64 dos apps, como um celular.
  bool arm64Ready = false;

  /// Boot atual com `arm64-v8a` declarado nas ABIs (initrd do SECADA Emulator).
  bool _arm64Boot = false;

  /// Download do tradutor ARM em andamento (começa junto com a VM).
  Future<String>? _armDownload;
  double _armProgress = 0;

  Adb? adb;
  QmpClient? _qmp;
  GuestShell? _shell;
  GuestSetup? _guest;
  String? _qemuLog;
  RandomAccessFile? _lock;
  bool _stopRequested = false;
  Completer<void>? _exitCompleter;
  StreamSubscription<NativeEvent>? _eventSub;
  Timer? _batteryTimer;
  int _bootToken = 0;

  String get vmDir => SecadaPaths.instance.vmDir(vmName);
  String get socketDir => SecadaPaths.instance.vmSocketDir(vmName);
  String get vncSocket => p.join(socketDir, 'vnc.sock');
  String get qmpSocket => p.join(socketDir, 'qmp.sock');
  String get serialSocket => p.join(socketDir, 'serial.sock');
  String get dbusQmpSocket => p.join(socketDir, 'dqmp.sock');
  String get pidFile => p.join(socketDir, 'qemu.pid');
  String? get qemuLogPath => _qemuLog;
  String get serialLogPath => p.join(SecadaPaths.instance.logsDir, 'android-serial.log');
  File get _provisionMarker => File(p.join(vmDir, 'provisioned-v$provisionVersion'));

  /// Proporção da tela do Android (para a janela acompanhar).
  double get displayAspect {
    if (fbWidth > 0 && fbHeight > 0) return viewport.aspect;
    return settings.width / settings.height;
  }

  DisplayViewport get viewport {
    if (fbWidth <= 0 || fbHeight <= 0) {
      return DisplayViewport(0, 0, settings.width.toDouble(), settings.height.toDouble());
    }
    if (!quickRotated) {
      return DisplayViewport(0, 0, fbWidth.toDouble(), fbHeight.toDouble());
    }
    // Geometria lógica girada (altura x largura) encaixada no framebuffer.
    final lw = fbHeight.toDouble(), lh = fbWidth.toDouble();
    final scale = (fbWidth / lw) < (fbHeight / lh) ? fbWidth / lw : fbHeight / lh;
    final w = lw * scale, h = lh * scale;
    return DisplayViewport((fbWidth - w) / 2, (fbHeight - h) / 2, w, h);
  }

  // ------------------------------------------------------------ inicialização
  Future<void> init() async {
    settings = await _store.load();
    _eventSub = _native.events.listen(_onNativeEvent);
    try {
      host = await HostInfo.probe();
      log.info('Host: $host');
    } catch (e) {
      log.error('Falha ao diagnosticar o host', e);
    }
    await _killStaleVm();
    if (settings.autoStart) {
      // A tela de inicialização aparece já no primeiro quadro.
      state = VmState.preparing;
      status = 'Preparando';
      bootStep = 'Iniciando…';
    } else {
      _setStatus('Desligado');
    }
  }

  /// Chamado pela interface após o primeiro quadro.
  void autoStartIfEnabled() {
    if (settings.autoStart) {
      state = VmState.stopped;
      unawaited(start());
    }
  }

  Future<void> saveSettings(VmSettings s) async {
    settings = s;
    await _store.save(s);
    log.info('Configurações salvas: ${s.toJson()}');
    notifyListeners();
  }

  /// Encerra uma VM órfã de uma execução anterior (por exemplo, após o
  /// aplicativo ter sido morto com SIGKILL durante o desligamento).
  Future<void> _killStaleVm() async {
    final f = File(pidFile);
    if (!await f.exists()) return;
    final pid = int.tryParse((await f.readAsString()).trim());
    if (pid == null) return;
    final comm = File('/proc/$pid/comm');
    if (await comm.exists() && (await comm.readAsString()).trim() == 'secada-vm') {
      log.warn('Encerrando VM órfã (pid $pid) de uma execução anterior');
      Process.killPid(pid, ProcessSignal.sigterm);
      for (var i = 0; i < 100 && await comm.exists(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (await comm.exists()) Process.killPid(pid, ProcessSignal.sigkill);
    }
    await f.delete().catchError((_) => f);
  }

  // ---------------------------------------------------------------- progresso
  /// Avança a barra suavemente até [target]; [step] é o texto da etapa.
  void _progress(double target, String step) {
    _bootTarget = target.clamp(0.0, 1.0);
    if (target < bootProgress) bootProgress = target;
    bootStep = step;
    status = step;
    _progressTimer ??= Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (bootProgress < _bootTarget) {
        bootProgress += ((_bootTarget - bootProgress) * 0.12).clamp(0.002, 0.05);
        if (bootProgress > _bootTarget) bootProgress = _bootTarget;
        notifyListeners();
      }
    });
    notifyListeners();
  }

  void _stopProgress() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  // -------------------------------------------------------------------- start
  Future<void> start() async {
    if (state == VmState.preparing && _bootToken > 0 || state.isActive) return;
    error = null;
    warnings = const [];
    _stopRequested = false;
    quickRotated = false;
    wifiConnected = false;
    bootProgress = 0;
    final token = ++_bootToken;
    _setState(VmState.preparing, 'Verificando o sistema…');
    _progress(0.04, 'Verificando o sistema…');
    try {
      host = await HostInfo.probe();
      if (!host.kvmUsable) {
        throw _StartError('KVM indisponível. ${host.kvmError}');
      }
      final warn = <String>[];
      final errors = settings.validate(host, warnings: warn);
      if (errors.isNotEmpty) throw _StartError(errors.join('\n'));

      final qemu = await QemuLocator.locate(configuredPath: settings.qemuPath);
      if (qemu == null) {
        throw _StartError('QEMU não encontrado. Instale com "sudo apt install '
            'qemu-system-x86" ou execute scripts/fetch-qemu-runtime.sh.');
      }
      log.info('QEMU: $qemu');

      // GPU do host (VirGL) sempre que possível; software só como último
      // recurso, avisando o motivo.
      graphics = settings.graphics;
      gpu = null;
      if (graphics == GraphicsMode.virgl) {
        _progress(0.06, 'Preparando a GPU…');
        gpu = _gpuFailed ? null : await Gpu.select(qemu);
        if (gpu == null) {
          final why = _gpuFailed
              ? 'a GPU falhou ao iniciar a máquina virtual'
              : Gpu.lastError;
          log.warn('VirGL indisponível ($why); usando renderização por software');
          warn.add('Aceleração por GPU indisponível ($why). O Android está '
              'usando renderização por software, mais lenta.');
          graphics = GraphicsMode.standard;
        }
      }
      warnings = warn;
      _useDbus = gpu != null && !_dbusFailed;
      displayBackend = 'vnc';

      final adbPath = await Adb.locate(settings.adbPath);
      if (adbPath == null) {
        throw _StartError('ADB não encontrado. Instale com "sudo apt install '
            'adb" ou indique o caminho nas configurações.');
      }

      _progress(0.08, 'Validando a imagem do Android…');
      final iso = await AndroidImageManager.findIso(settings.imagePath);
      if (iso == null) {
        throw _StartError(settings.imagePath.isEmpty
            ? 'Nenhuma imagem Android encontrada em '
                '${SecadaPaths.instance.imagesDir}. Execute '
                'scripts/fetch-android-image.sh ou selecione uma ISO nas '
                'configurações.'
            : 'Imagem Android não encontrada: ${settings.imagePath}');
      }
      final iso9660 = await AndroidImageManager.prepare(iso, vmDir);
      log.info('Imagem: ${iso9660.isoPath} (${iso9660.volumeId})');

      // ARM64 só é declarado ao Android quando o tradutor existe: sem ele,
      // apps com as duas versões seriam instalados como ARM64 e não abririam.
      arm64Ready = false;
      _arm64Boot = settings.armTranslation &&
          await Arm64Translation.isAvailable() &&
          !await _arm64KnownBad();
      final image = AndroidImage(
        isoPath: iso9660.isoPath,
        kernelPath: iso9660.kernelPath,
        initrdPath: await InitrdOverlay.prepare(iso9660.initrdPath, arm64: _arm64Boot),
        volumeId: iso9660.volumeId,
      );

      // O tradutor ARM (~43 MB) é baixado em paralelo ao boot na primeira vez.
      armReady = false;
      if (settings.armTranslation && _armDownload == null && !await ArmTranslation.isDownloaded()) {
        _armProgress = 0;
        _armDownload = ArmTranslation.ensureDownloaded(onProgress: (f) => _armProgress = f);
        _armDownload!.catchError((Object e) {
          _armDownload = null; // nova tentativa no próximo boot
          return '';
        });
      }

      _progress(0.12, 'Preparando o armazenamento…');
      final disk = await DiskManager.ensureDataDisk(
          vmDir: vmDir, sizeGb: settings.diskGb, qemu: qemu);
      _freshDisk = disk.created;
      firstBoot = disk.created || !await _provisionMarker.exists();

      await SecadaPaths.ensurePrivateDir(socketDir);
      await _acquireLock();
      for (final s in [vncSocket, qmpSocket, serialSocket, dbusQmpSocket]) {
        final f = File(s);
        if (await f.exists()) await f.delete();
      }
      final adbPort = await _findFreePort(settings.adbPort);

      await Directory(SecadaPaths.instance.logsDir).create(recursive: true);
      _qemuLog = p.join(SecadaPaths.instance.logsDir, 'qemu.log');
      await _rotateLog(_qemuLog!);
      await _rotateLog(serialLogPath);
      final argv = buildQemuArgv(QemuLaunchSpec(
        qemu: qemu,
        image: image,
        dataDisk: disk.path,
        settings: settings.copyWith(graphics: graphics),
        renderNode: gpu?.node.path ?? '',
        dbusQmpSocket: _useDbus ? dbusQmpSocket : null,
        vncSocket: vncSocket,
        qmpSocket: qmpSocket,
        serialLog: serialLogPath,
        serialSocket: serialSocket,
        pidFile: pidFile,
        adbPort: adbPort,
        pulseSocket: settings.audio ? await _pulseSocket() : null,
        // O houdini64 só inicializa em CPU "GenuineIntel".
        intelCpuIdentity: _arm64Boot && host.cpuVendor != 'GenuineIntel',
      ));
      await File(_qemuLog!).writeAsString(
          '${DateTime.now().toIso8601String()} ${argv.join(' ')}\n',
          mode: FileMode.append);
      log.info('Iniciando QEMU: ${argv.join(' ')}');

      _progress(0.18, 'Iniciando a máquina virtual…');
      _exitCompleter = Completer<void>();
      final pid = await _native.startVm(argv: argv, env: qemu.env, logPath: _qemuLog!);
      log.info('QEMU iniciado (pid $pid)');
      _setState(VmState.booting, bootStep);

      _qmp = await QmpClient.connect(qmpSocket);
      _qmp!.events.listen((e) => log.info('QMP evento: ${e['event']}'));

      // Nos modos por software o Android-x86 desenha BGR num framebuffer
      // XRGB, então o QEMU entrega R e B trocados; com VirGL (gralloc gbm) as
      // cores já chegam certas. Medido comparando com o screencap do Android.
      textureId = await _native.connectDisplay(vncSocket,
          swapRedBlue: graphics != GraphicsMode.virgl,
          dbusQmpSocket: _useDbus ? dbusQmpSocket : null,
          renderNode: _useDbus ? gpu!.node.path : null);

      _shell = await GuestShell.connect(serialSocket);
      _guest = GuestSetup(_shell!);
      adb = Adb(adbPath, '127.0.0.1:$adbPort');
      unawaited(adb!.startServer());
      notifyListeners();
      unawaited(_bootSequence(token, grown: disk.grown));
    } on _StartError catch (e) {
      await _failStart(e.message);
    } on ImageError catch (e) {
      await _failStart(e.message);
    } on DiskError catch (e) {
      await _failStart(e.message);
    } on PlatformException catch (e) {
      await _failStart(e.message ?? e.code);
    } catch (e, st) {
      log.error('Falha ao iniciar', e, st);
      await _failStart('Falha ao iniciar a VM: $e');
    }
  }

  Future<String?> _pulseSocket() async {
    final rt = Platform.environment['XDG_RUNTIME_DIR'];
    if (rt == null) return null;
    final s = p.join(rt, 'pulse', 'native');
    return await FileSystemEntity.type(s) == FileSystemEntityType.unixDomainSock ? s : null;
  }

  Future<void> _failStart(String message) async {
    log.error('Inicialização falhou: $message');
    _stopProgress();
    if (await _native.isVmRunning()) {
      await _forceStop();
    }
    await _cleanupSession();
    error = message;
    _setState(VmState.error, 'Erro');
  }

  bool _alive(int token) => token == _bootToken && state == VmState.booting;

  /// Espera o Android terminar o boot acompanhando as fases pelo console.
  Future<bool> _waitAndroid(int token, double from, double to) async {
    final g = _guest!;
    _progress(from, 'Carregando o kernel do Android…');
    if (!await _shell!.waitReady(timeout: const Duration(seconds: 90))) {
      log.warn('Console serial não respondeu');
    } else {
      await g.earlyBoot();
    }
    final deadline = DateTime.now().add(Duration(seconds: firstBoot ? 420 : 240));
    var lastPhase = -1;
    while (_alive(token) && DateTime.now().isBefore(deadline)) {
      final phase = await g.bootPhase();
      if (phase != lastPhase) {
        lastPhase = phase;
        final span = to - from;
        switch (phase) {
          case 0:
            _progress(from + span * 0.25, 'Iniciando serviços do sistema…');
          case 1:
            _progress(from + span * 0.55, 'Iniciando o Android…');
          case 2:
            _progress(from + span * 0.92, 'Carregando a interface…');
          case 3:
            _progress(to, 'Android iniciado');
            return true;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    return false;
  }

  Future<void> _bootSequence(int token, {required bool grown}) async {
    final started = DateTime.now();
    final booted = await _waitAndroid(token, 0.22, firstBoot ? 0.6 : 0.8);
    if (!_alive(token)) return;
    if (!booted) {
      warnings = [...warnings, 'O Android demorou demais para responder.'];
      log.warn('Timeout aguardando o boot');
    }
    final g = _guest!;
    if (firstBoot) {
      _progress(0.64, 'Removendo apps e serviços dispensáveis…');
      await _applyProfile(g);
      _progress(0.68, 'Configurando o Android pela primeira vez…');
      final needsRestart = await g.firstBoot();
      _progress(0.72, 'Conectando o Wi-Fi…');
      wifiConnected = await g.ensureWifi();
      await _provisionMarker.writeAsString(DateTime.now().toIso8601String());
      if (needsRestart && _alive(token)) {
        _progress(0.74, 'Aplicando idioma e fuso horário…');
        final reset = _qmp?.events
            .firstWhere((e) => e['event'] == 'RESET')
            .timeout(const Duration(seconds: 60));
        await g.reboot();
        try {
          await reset;
        } catch (_) {
          await _qmp?.execute('system_reset').catchError((_) => null);
        }
        await _waitAndroid(token, 0.76, 0.9);
        if (!_alive(token)) return;
      }
    }
    _progress(0.92, 'Ajustando tela, bateria e rede…');
    await g.everyBoot();
    await _applyProfile(g);
    if (!wifiConnected) wifiConnected = await g.ensureWifi();
    if (grown) {
      final r = await _shell!.run('resize2fs /dev/block/vda',
          timeout: const Duration(minutes: 5));
      log.info('resize2fs: ${r?.exitCode} ${r?.output}');
    }
    if (!_alive(token)) return;

    _progress(0.96, 'Conectando o ADB…');
    final adbDeadline = DateTime.now().add(const Duration(seconds: 40));
    while (_alive(token) && DateTime.now().isBefore(adbDeadline)) {
      if ((await adb!.state()) == 'device') {
        adbReady = true;
        break;
      }
      await adb!.connect();
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    if (!_alive(token)) return;
    if (!adbReady) {
      warnings = [...warnings, 'ADB indisponível: instalação de APKs desativada.'];
    } else {
      await _syncArmTranslation(token);
      if (!_alive(token)) return;
      if ((await BundledApps.pending(vmDir)).isNotEmpty) {
        _progress(0.97, 'Instalando navegador e notas…');
        await BundledApps.installPending(adb!, vmDir);
        if (!_alive(token)) return;
      }
      // Uma vez por VM: atalhos na tela inicial (o perfil enxuto limpa o
      // launcher e o Android não cria ícones para apps instalados por ADB).
      final homeMarker = File(p.join(vmDir, 'home-icons-v1'));
      if (!await homeMarker.exists()) {
        _progress(0.98, 'Organizando a tela inicial…');
        final pinned = await g.pinToHome(adb!, [
          ...BundledApps.apps.map((a) => a.packageName),
          'com.android.documentsui',
          'com.android.settings',
        ]);
        if (pinned) await homeMarker.writeAsString(DateTime.now().toIso8601String());
        if (!_alive(token)) return;
      }
    }
    log.info('Android pronto em ${DateTime.now().difference(started).inSeconds}s '
        '(wifi=$wifiConnected adb=$adbReady)');
    _progress(1, 'Pronto');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    _stopProgress();
    _setState(VmState.running, 'Em execução');
    _batteryTimer?.cancel();
    _batteryTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      if (state == VmState.running) await _guest?.applyBattery(await HostPower.read());
    });
  }

  /// Liga ou desliga a tradução ARM no Android conforme a configuração.
  /// Na primeira vez espera o download do tradutor e o envia por ADB.
  Future<void> _syncArmTranslation(int token) async {
    final g = _guest!;
    if (!settings.armTranslation) {
      if (await _shell!.getProp('persist.sys.nativebridge') == '1') {
        await g.setArmEnabled(false);
        log.info('Tradução ARM desligada');
      }
      return;
    }
    if (await g.armActive()) {
      armReady = true;
      log.info('Tradução ARM ativa');
      await _syncArm64(token);
      return;
    }
    _progress(0.965, 'Preparando a tradução ARM…');
    try {
      if (!await g.armFilePresent()) {
        var local = ArmTranslation.localPath;
        if (!await ArmTranslation.isDownloaded()) {
          final dl = _armDownload ??=
              ArmTranslation.ensureDownloaded(onProgress: (f) => _armProgress = f);
          // Mostra o andamento enquanto espera o download terminar.
          var done = false;
          unawaited(dl.whenComplete(() => done = true).catchError((_) => ''));
          while (!done && _alive(token)) {
            _progress(0.965, 'Baixando o tradutor ARM… ${(_armProgress * 100).round()}%');
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
          if (!_alive(token)) return;
          local = await dl;
        }
        _progress(0.97, 'Instalando a tradução ARM…');
        const tmp = '/data/local/tmp/${ArmTranslation.fileName}';
        final push = await adb!.runOnDevice(['push', local, tmp],
            timeout: const Duration(minutes: 3));
        if (!push.ok || !await g.installArmFile(tmp)) {
          throw ArmTranslationError('falha ao copiar o tradutor para o Android '
              '(${push.stderr.trim()})');
        }
      }
      await g.setArmEnabled(true);
      for (var i = 0; i < 30 && !armReady && _alive(token); i++) {
        armReady = await g.armActive();
        if (!armReady) await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (armReady) {
        log.info('Tradução ARM ativada');
      } else {
        throw ArmTranslationError('o Android não ativou o tradutor (veja "logcat -s houdini")');
      }
      if (_alive(token)) await _syncArm64(token);
    } catch (e) {
      _armDownload = null;
      log.warn('Tradução ARM indisponível: $e');
      warnings = [
        ...warnings,
        'Tradução ARM indisponível: $e. Apps só ARM não vão abrir; o SECADA Emulator tenta '
            'de novo no próximo boot.',
      ];
    }
  }

  /// Tradução ARM 64 bits: envia o tradutor na primeira vez e espera o
  /// serviço `nativebridge64` montá-lo. Falhar aqui não derruba a tradução
  /// de 32 bits.
  Future<void> _syncArm64(int token) async {
    final g = _guest!;
    if (!_arm64Boot) return;
    if (!await g.arm64Declared()) {
      log.warn('Initrd do SECADA Emulator não declarou arm64-v8a; tradução ARM64 desligada');
      return;
    }
    if (await g.arm64Active()) {
      arm64Ready = true;
      log.info('Tradução ARM64 ativa');
      return;
    }
    try {
      final local = Arm64Translation.localPath;
      final size = await Arm64Translation.size();
      if (!await g.arm64FilePresent(size)) {
        _progress(0.972, 'Instalando a tradução ARM 64 bits…');
        const tmp = '/data/local/tmp/${Arm64Translation.fileName}';
        final push = await adb!.runOnDevice(['push', local, tmp],
            timeout: const Duration(minutes: 5));
        if (!push.ok || !await g.installArm64File(tmp)) {
          throw ArmTranslationError('falha ao copiar o tradutor ARM64 para o Android '
              '(${push.stderr.trim()})');
        }
      }
      await g.startArm64();
      for (var i = 0; i < 40 && !arm64Ready && _alive(token); i++) {
        arm64Ready = await g.arm64Active();
        if (!arm64Ready) await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (!arm64Ready) {
        throw ArmTranslationError('o Android não ativou o tradutor ARM64 '
            '(veja "logcat -s houdini")');
      }
      log.info('Tradução ARM64 ativada');
      if (await _arm64BadMarker.exists()) await _arm64BadMarker.delete();
    } catch (e) {
      log.warn('Tradução ARM64 indisponível: $e');
      // Nos próximos boots o Android não anuncia ARM64 com este arquivo: sem
      // o tradutor, apps seriam instalados na versão ARM64 e não abririam.
      if (_alive(token)) await _arm64BadMarker.writeAsString(await _arm64Stamp());
      warnings = [
        ...warnings,
        'Tradução ARM 64 bits indisponível: $e. Apps ARM usam a versão de 32 bits; '
            'o SECADA Emulator só tenta de novo quando o arquivo do tradutor mudar.',
      ];
    }
  }

  File get _arm64BadMarker => File(p.join(vmDir, 'arm64-failed'));

  Future<String> _arm64Stamp() async {
    final st = await File(Arm64Translation.localPath).stat();
    return '${st.size}:${st.modified.millisecondsSinceEpoch}';
  }

  /// O tradutor ARM64 atual já falhou nesta VM.
  Future<bool> _arm64KnownBad() async =>
      await _arm64BadMarker.exists() &&
      await _arm64BadMarker.readAsString() == await _arm64Stamp();

  /// Aplica (ou desfaz) o perfil enxuto conforme a configuração. O estado
  /// aplicado fica num marcador para só restaurar quando a opção mudar. Num
  /// disco recém-criado não há nada a restaurar.
  Future<void> _applyProfile(GuestSetup g) async {
    final fullMarker = File(p.join(vmDir, 'profile-full'));
    if (settings.leanAndroid) {
      await g.applyLean();
      if (await fullMarker.exists()) await fullMarker.delete();
    } else if (!await fullMarker.exists()) {
      if (!_freshDisk) await g.restoreFull();
      await fullMarker.writeAsString('1');
    }
    // Sempre, com ou sem o perfil enxuto: sem câmera na VM e um só launcher.
    await g.removeCameraApps();
    await g.ensureHome();
  }

  // --------------------------------------------------------------------- stop
  /// Desligamento ordenado. Ordem: `reboot -p` pelo console (o Android grava
  /// tudo e desliga), botão ACPI, `quit` via QMP, SIGTERM e, por fim, SIGKILL.
  Future<void> stop() async {
    if (!(await _native.isVmRunning())) {
      _stopProgress();
      await _cleanupSession();
      _setState(VmState.stopped, 'Desligado');
      return;
    }
    _stopRequested = true;
    _bootToken++;
    _stopProgress();
    _setState(VmState.stopping, 'Desligando Android…');
    final exit = _exitCompleter?.future ?? Future<void>.value();

    Future<bool> waitExit(Duration d) async {
      try {
        await exit.timeout(d);
        return true;
      } on TimeoutException {
        return false;
      }
    }

    var done = false;
    // Só espera pelo console se ele estiver respondendo.
    final alive = _shell != null &&
        !_shell!.isClosed &&
        (await _shell!.run('echo ok', timeout: const Duration(seconds: 2)))?.ok == true;
    if (alive) {
      log.info('Desligando pelo console (reboot -p)');
      unawaited(_guest!.powerOff());
      done = await waitExit(const Duration(seconds: 25));
    }
    if (!done && _qmp != null && !_qmp!.isClosed) {
      log.warn('Desligando via ACPI (system_powerdown)');
      await _qmp!.execute('system_powerdown').catchError((_) => null);
      done = await waitExit(const Duration(seconds: 8));
      if (!done) {
        log.warn('Encerrando QEMU via QMP quit');
        await _qmp!.execute('quit').catchError((_) => null);
        done = await waitExit(const Duration(seconds: 8));
      }
    }
    if (!done) await _forceStop();
  }

  Future<void> _forceStop() async {
    log.warn('Encerrando QEMU com SIGTERM');
    _stopRequested = true;
    await _native.signalVm(15);
    try {
      await (_exitCompleter?.future ?? Future<void>.value())
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      log.error('QEMU não respondeu ao SIGTERM; enviando SIGKILL');
      await _native.signalVm(9);
      await (_exitCompleter?.future ?? Future<void>.value())
          .timeout(const Duration(seconds: 5), onTimeout: () {});
    }
  }

  /// Reinicia apenas o Android (o processo QEMU continua).
  Future<void> rebootAndroid() async {
    if (!state.isActive || state == VmState.stopping) return;
    adbReady = false;
    quickRotated = false;
    firstBoot = false;
    await disableTouchDevice();
    final token = ++_bootToken;
    bootProgress = 0;
    _setState(VmState.booting, 'Reiniciando Android…');
    _progress(0.1, 'Reiniciando o Android…');
    // Só volta a consultar o boot depois do RESET da máquina; caso contrário
    // o Android antigo (ainda desligando) responderia boot_completed=1.
    final reset = _qmp?.events
        .firstWhere((e) => e['event'] == 'RESET')
        .timeout(const Duration(seconds: 45));
    if (_guest != null) {
      await _guest!.reboot();
    } else {
      await _qmp?.execute('system_reset').catchError((_) => null);
    }
    try {
      await reset;
    } catch (_) {
      log.warn('Sem RESET após reboot; forçando system_reset');
      await _qmp?.execute('system_reset').catchError((_) => null);
    }
    await adb?.disconnect();
    if (token == _bootToken) {
      unawaited(_bootSequence(token, grown: false));
    }
  }

  // ---------------------------------------------------------------- rotação
  /// Rotação rápida: troca a geometria lógica do Android (`wm size`). O
  /// Android sempre inicia em paisagem.
  Future<void> toggleQuickRotation() async {
    final g = _shell;
    if (g == null || state != VmState.running || fbWidth == 0) return;
    if (quickRotated) {
      await g.run('wm size reset');
      quickRotated = false;
    } else {
      await g.run('wm size ${fbHeight}x$fbWidth');
      quickRotated = true;
    }
    notifyListeners();
  }

  // ------------------------------------------------------ trava do ponteiro
  void _lockTick() {
    final a = adb;
    if (adbReady && a != null && state == VmState.running) {
      _lockWatcher.ensureRunning(a);
    } else if (_lockWatcher.running || guestPointerLock) {
      _lockWatcher.stop();
    }
  }

  /// Movimento relativo do mouse (em pixels do Android), pelo mouse PS/2 da VM.
  /// O tablet USB só entende posição absoluta; deslocamento infinito (câmera de
  /// jogo) precisa deste caminho.
  void sendRelativeMouse(int dx, int dy) {
    if (dx == 0 && dy == 0) return;
    _qmp?.send('input-send-event', {
      'events': [
        if (dx != 0) {'type': 'rel', 'data': {'axis': 'x', 'value': dx}},
        if (dy != 0) {'type': 'rel', 'data': {'axis': 'y', 'value': dy}},
      ],
    });
  }

  // ------------------------------------------------- toque (mapeador de teclas)
  static const touchDeviceId = 'secadamt';

  /// O dispositivo de toque multitoque está no convidado.
  bool touchDeviceReady = false;

  /// Adiciona a tela de toque virtual (`virtio-multitouch`) à VM em execução.
  ///
  /// Ela só existe enquanto o mapeador está ligado: enquanto ela está na VM, o
  /// QEMU pode entregar os botões do mouse a ela em vez do tablet USB, então
  /// nesse período todo o ponteiro do SECADA Emulator vira toque. Vinculada à placa de
  /// vídeo (`display=vga0`) quando possível, para que o roteamento não dependa
  /// da ordem em que o convidado ativa os dispositivos.
  Future<bool> enableTouchDevice() async {
    final q = _qmp;
    if (q == null || q.isClosed || state != VmState.running) return false;
    if (touchDeviceReady) return true;
    final display = displayDeviceIdFor(graphics);
    try {
      await q.execute('device_add', arguments: {
        'driver': 'virtio-multitouch-pci',
        'id': touchDeviceId,
        'display': ?display,
      });
    } catch (e) {
      log.warn('Não foi possível adicionar a tela de toque: $e');
      return false;
    }
    // Espera o kernel do convidado criar o dispositivo e o Android registrá-lo.
    var seen = false;
    for (var i = 0; i < 40 && !seen; i++) {
      final r = await _shell?.run('grep -c "Virtio MultiTouch" /proc/bus/input/devices',
          timeout: const Duration(seconds: 3));
      seen = r?.output.trim() == '1';
      if (!seen) await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));
    touchDeviceReady = seen;
    log.info('Tela de toque virtual ${seen ? 'pronta' : 'não apareceu no convidado'}');
    if (!seen) await disableTouchDevice();
    notifyListeners();
    return seen;
  }

  Future<void> disableTouchDevice() async {
    final q = _qmp;
    touchDeviceReady = false;
    if (q == null || q.isClosed) return;
    try {
      await q.execute('device_del', arguments: {'id': touchDeviceId});
    } catch (_) {}
    notifyListeners();
  }

  /// Envia eventos de entrada (toques) ao QEMU sem esperar resposta.
  void sendTouchEvents(List<Map<String, Object?>> events) {
    final display = displayDeviceIdFor(graphics);
    _qmp?.send('input-send-event', {'events': events, 'device': ?display});
  }

  // ------------------------------------------------------------------ eventos
  void _onNativeEvent(NativeEvent e) {
    switch (e.type) {
      case 'vmExit':
        _onVmExit(e.data['code'] as int? ?? -1, e.data['signaled'] == true,
            e.data['signal'] as int? ?? 0);
      case 'display':
        final st = e.data['state'];
        displayConnected = st == 'connected';
        if (st == 'failed') log.warn('Display: ${e.data['detail']}');
        notifyListeners();
      case 'displayBackend':
        if (e.data['state'] == 'dbus') {
          displayBackend = 'dbus';
          log.info('Display D-Bus ativo: quadros direto da GPU (${gpu?.node})');
        } else {
          log.warn('Display D-Bus falhou: ${e.data['detail']}');
          if (_useDbus && !_dbusFailed && state != VmState.stopping) {
            _dbusFailed = true;
            unawaited(_restartForFallback());
          }
        }
      case 'displaySize':
        fbWidth = e.data['width'] as int? ?? 0;
        fbHeight = e.data['height'] as int? ?? 0;
        log.info('Resolução do display: ${fbWidth}x$fbHeight');
        notifyListeners();
    }
  }

  /// Reinicia a VM pelo caminho de reserva (VirGL via egl-headless + VNC)
  /// quando o display D-Bus não funciona neste host.
  Future<void> _restartForFallback() async {
    log.warn('Reiniciando a VM com o display VNC (reserva)');
    await stop();
    // A limpeza da sessão termina depois do fim do processo.
    for (var i = 0; i < 100 && state != VmState.stopped; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await start();
  }

  Future<void> _onVmExit(int code, bool signaled, int signal) async {
    log.info('QEMU encerrou: code=$code signaled=$signaled signal=$signal');
    final expected = _stopRequested || state == VmState.stopping;
    final wasBooting = state == VmState.booting;
    if (!(_exitCompleter?.isCompleted ?? true)) _exitCompleter!.complete();
    _bootToken++;
    _stopProgress();
    await _cleanupSession();
    if (expected || (!signaled && code == 0)) {
      _setState(VmState.stopped, 'Desligado');
    } else if (graphics == GraphicsMode.virgl && wasBooting && !_gpuFailed) {
      // Falha do VirGL (driver/EGL do host): tenta de novo por software.
      log.warn('A VM com VirGL encerrou durante o boot; repetindo por software');
      _gpuFailed = true;
      _setState(VmState.stopped, 'Desligado');
      unawaited(start());
    } else {
      final tail = await _logTail(_qemuLog, 12);
      error = 'A máquina virtual encerrou inesperadamente '
          '(${signaled ? 'sinal $signal' : 'código $code'}).\n$tail';
      _setState(VmState.error, 'Erro');
    }
  }

  Future<void> _cleanupSession() async {
    _batteryTimer?.cancel();
    touchDeviceReady = false;
    await _native.disconnectDisplay().catchError((_) {});
    textureId = null;
    displayConnected = false;
    adbReady = false;
    wifiConnected = false;
    quickRotated = false;
    fbWidth = fbHeight = 0;
    final q = _qmp;
    _qmp = null;
    await q?.close().catchError((_) {});
    final s = _shell;
    _shell = null;
    _guest = null;
    await s?.close();
    final a = adb;
    if (a != null) await a.disconnect().catchError((_) {});
    try {
      await _lock?.unlock();
      await _lock?.close();
    } catch (_) {}
    _lock = null;
    for (final s in [vncSocket, qmpSocket, serialSocket, dbusQmpSocket]) {
      final f = File(s);
      if (await f.exists()) await f.delete().catchError((_) => f);
    }
  }

  // --------------------------------------------------------------- utilidades
  Future<void> _acquireLock() async {
    final f = File(p.join(socketDir, 'instance.lock'));
    final raf = await f.open(mode: FileMode.write);
    try {
      await raf.lock(FileLock.exclusive);
    } catch (_) {
      await raf.close();
      throw _StartError('Outra instância do SECADA Emulator já está usando esta VM.');
    }
    _lock = raf;
  }

  Future<int> _findFreePort(int preferred) async {
    for (var port = preferred; port < preferred + 50 && port < 65536; port++) {
      try {
        final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
        await s.close();
        return port;
      } catch (_) {}
    }
    throw _StartError('Nenhuma porta local livre para o ADB a partir de $preferred.');
  }

  Future<void> _rotateLog(String path) async {
    final f = File(path);
    if (await f.exists() && await f.length() > 4 * 1024 * 1024) {
      await f.rename('$path.1');
    }
  }

  Future<String> _logTail(String? path, int lines) async {
    if (path == null) return '';
    try {
      final all = await File(path).readAsLines();
      return all.skip(all.length > lines ? all.length - lines : 0).join('\n');
    } catch (_) {
      return '';
    }
  }

  void _setState(VmState s, String text) {
    state = s;
    status = text;
    notifyListeners();
  }

  void _setStatus(String text) {
    status = text;
    notifyListeners();
  }

  @override
  void dispose() {
    _lockTimer?.cancel();
    _lockWatcher.stop();
    _eventSub?.cancel();
    _batteryTimer?.cancel();
    _stopProgress();
    super.dispose();
  }
}

class _StartError implements Exception {
  _StartError(this.message);
  final String message;
}
