import 'dart:convert';
import 'dart:io';

import '../core/app_log.dart';
import '../core/paths.dart';
import '../host/host_info.dart';

/// Modo gráfico da VM.
enum GraphicsMode {
  /// VGA padrão (bochs-drm) + renderização por software no Android (CPU).
  standard('Software — VGA (compatibilidade, mais lento)'),

  /// virtio-vga sem 3D (framebuffer virtio-gpu) + renderização por software.
  virtio('Software — VirtIO 2D (compatibilidade, mais lento)'),

  /// virtio-vga-gl com VirGL: OpenGL ES do Android acelerado pela GPU do
  /// host (egl-headless). Padrão; se a GPU não puder ser usada, o SECADA Emulator cai
  /// sozinho para o modo por software.
  virgl('GPU do host (VirGL) — recomendado');

  const GraphicsMode(this.label);
  final String label;
}

/// Configuração persistente da máquina virtual.
class VmSettings {
  const VmSettings({
    this.cpus = 4,
    this.memoryMb = 4096,
    this.width = 1280,
    this.height = 720,
    this.dpi = 240,
    this.diskGb = 32,
    this.graphics = GraphicsMode.virgl,
    this.escAsBack = true,
    this.audio = true,
    this.autoStart = true,
    this.leanAndroid = false,
    this.armTranslation = true,
    this.imagePath = '',
    this.qemuPath = '',
    this.adbPath = '',
    this.adbPort = 6555,
  });

  final int cpus;
  final int memoryMb;
  final int width;
  final int height;
  final int dpi;
  final int diskGb;
  final GraphicsMode graphics;

  /// Revisão dos padrões de fábrica gravada junto com a configuração. Ao
  /// subir a revisão, configurações antigas adotam os novos padrões:
  /// 2 = gráficos pela GPU; 3 = Android enxuto desligado.
  static const defaultsRev = 3;
  final bool escAsBack;

  /// Áudio do Android (Intel HDA) pelo PulseAudio/PipeWire do host.
  final bool audio;

  /// Inicia o Android automaticamente ao abrir o SECADA Emulator.
  final bool autoStart;

  /// Android enxuto: remove apps e serviços dispensáveis (ver LeanProfile).
  /// Desligado de fábrica.
  final bool leanAndroid;

  /// Tradução ARM (libhoudini do Android-x86): roda apps só ARM 32 bits.
  /// Ligada de fábrica; o tradutor é baixado na primeira vez.
  final bool armTranslation;

  /// ISO do Android-x86 (vazio = procurar automaticamente).
  final String imagePath;

  /// Caminhos opcionais; vazio = detecção automática.
  final String qemuPath;
  final String adbPath;

  /// Porta TCP local (127.0.0.1) encaminhada para o adbd (5555) do Android.
  final int adbPort;

  VmSettings copyWith({
    int? cpus,
    int? memoryMb,
    int? width,
    int? height,
    int? dpi,
    int? diskGb,
    GraphicsMode? graphics,
    bool? escAsBack,
    bool? audio,
    bool? autoStart,
    bool? leanAndroid,
    bool? armTranslation,
    String? imagePath,
    String? qemuPath,
    String? adbPath,
    int? adbPort,
  }) {
    return VmSettings(
      cpus: cpus ?? this.cpus,
      memoryMb: memoryMb ?? this.memoryMb,
      width: width ?? this.width,
      height: height ?? this.height,
      dpi: dpi ?? this.dpi,
      diskGb: diskGb ?? this.diskGb,
      graphics: graphics ?? this.graphics,
      escAsBack: escAsBack ?? this.escAsBack,
      audio: audio ?? this.audio,
      autoStart: autoStart ?? this.autoStart,
      leanAndroid: leanAndroid ?? this.leanAndroid,
      armTranslation: armTranslation ?? this.armTranslation,
      imagePath: imagePath ?? this.imagePath,
      qemuPath: qemuPath ?? this.qemuPath,
      adbPath: adbPath ?? this.adbPath,
      adbPort: adbPort ?? this.adbPort,
    );
  }

  Map<String, Object?> toJson() => {
        'cpus': cpus,
        'memoryMb': memoryMb,
        'width': width,
        'height': height,
        'dpi': dpi,
        'diskGb': diskGb,
        'graphics': graphics.name,
        'defaultsRev': defaultsRev,
        'escAsBack': escAsBack,
        'audio': audio,
        'autoStart': autoStart,
        'leanAndroid': leanAndroid,
        'armTranslation': armTranslation,
        'imagePath': imagePath,
        'qemuPath': qemuPath,
        'adbPath': adbPath,
        'adbPort': adbPort,
      };

  factory VmSettings.fromJson(Map<String, Object?> j) {
    const d = VmSettings();
    T pick<T>(String k, T fallback) => j[k] is T ? j[k] as T : fallback;
    final rev = pick<int>('defaultsRev', pick<int>('graphicsRev', 0));
    return VmSettings(
      cpus: pick('cpus', d.cpus),
      memoryMb: pick('memoryMb', d.memoryMb),
      width: pick('width', d.width),
      height: pick('height', d.height),
      dpi: pick('dpi', d.dpi),
      diskGb: pick('diskGb', d.diskGb),
      // Configurações de revisões anteriores adotam os novos padrões de
      // fábrica (a chave antiga "graphicsRev" equivale à revisão 2).
      graphics: rev < 2
          ? GraphicsMode.virgl
          : GraphicsMode.values.firstWhere((e) => e.name == j['graphics'],
              orElse: () => d.graphics),
      escAsBack: pick('escAsBack', d.escAsBack),
      audio: pick('audio', d.audio),
      autoStart: pick('autoStart', d.autoStart),
      leanAndroid: rev < 3 ? false : pick('leanAndroid', d.leanAndroid),
      armTranslation: pick('armTranslation', d.armTranslation),
      imagePath: pick('imagePath', d.imagePath),
      qemuPath: pick('qemuPath', d.qemuPath),
      adbPath: pick('adbPath', d.adbPath),
      adbPort: pick('adbPort', d.adbPort),
    );
  }

  /// Valida a configuração contra o hardware do host.
  ///
  /// Retorna a lista de erros (impedem a inicialização). Avisos não
  /// bloqueantes vão para [warnings].
  List<String> validate(HostInfo host, {List<String>? warnings}) {
    final errors = <String>[];
    if (cpus < 1) errors.add('A VM precisa de pelo menos 1 núcleo virtual.');
    if (host.logicalCpus > 0 && cpus > host.logicalCpus) {
      errors.add('$cpus vCPUs excedem os ${host.logicalCpus} núcleos lógicos '
          'do computador.');
    } else if (host.logicalCpus > 0 && cpus == host.logicalCpus) {
      warnings?.add('Usar todos os núcleos do host pode deixar o sistema lento.');
    }
    if (memoryMb < 2048) {
      errors.add('O Android 9 precisa de pelo menos 2048 MB de RAM.');
    }
    if (host.memTotalMb > 0 && memoryMb > host.memTotalMb - 1024) {
      errors.add('$memoryMb MB de RAM não deixam memória suficiente para o '
          'host (total: ${host.memTotalMb} MB).');
    } else if (host.memAvailableMb > 0 && memoryMb > host.memAvailableMb) {
      warnings?.add('A memória livre agora (${host.memAvailableMb} MB) é menor '
          'que a alocada; o host pode usar swap.');
    }
    if (width < 480 || width > 3840 || height < 480 || height > 2160) {
      errors.add('Resolução deve estar entre 480×480 e 3840×2160.');
    }
    if (width < height) {
      errors.add('O SECADA Emulator usa sempre paisagem: a largura deve ser maior que a altura.');
    }
    if (width % 8 != 0) {
      errors.add('A largura da tela deve ser múltipla de 8.');
    }
    if (dpi < 120 || dpi > 640) errors.add('DPI deve estar entre 120 e 640.');
    if (diskGb < 8 || diskGb > 1024) {
      errors.add('Armazenamento deve estar entre 8 e 1024 GB.');
    }
    if (adbPort < 1024 || adbPort > 65535) {
      errors.add('Porta ADB inválida.');
    }
    return errors;
  }
}

/// Persistência de [VmSettings] em `~/.config/secada/settings.json`.
class SettingsStore {
  SettingsStore({String? path}) : path = path ?? SecadaPaths.instance.settingsFile;
  final String path;

  Future<VmSettings> load() async {
    final f = File(path);
    if (!await f.exists()) return const VmSettings();
    try {
      final json = jsonDecode(await f.readAsString());
      return VmSettings.fromJson(Map<String, Object?>.from(json as Map));
    } catch (e) {
      log.warn('Configuração inválida em $path, usando padrões: $e');
      return const VmSettings();
    }
  }

  Future<void> save(VmSettings s) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(s.toJson()));
    await tmp.rename(path); // Escrita atômica.
  }
}
