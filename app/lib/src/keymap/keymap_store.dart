import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_log.dart';
import '../core/paths.dart';
import 'keymap_models.dart';
import 'presets.dart';

/// Preferências gerais do mapeador.
class KeymapPrefs {
  KeymapPrefs({this.showHud = true, this.autoProfile = true, this.sensitivity = 1.0});

  /// Mostra os emblemas das teclas sobre a tela enquanto o mapeamento está
  /// ligado.
  bool showHud;

  /// Troca o perfil sozinho conforme o app em primeiro plano.
  bool autoProfile;

  /// Multiplicador global da sensibilidade da mira.
  double sensitivity;

  Map<String, Object?> toJson() =>
      {'showHud': showHud, 'autoProfile': autoProfile, 'sensitivity': sensitivity};

  static KeymapPrefs fromJson(Object? j) {
    if (j is! Map) return KeymapPrefs();
    return KeymapPrefs(
      showHud: j['showHud'] is bool ? j['showHud'] as bool : true,
      autoProfile: j['autoProfile'] is bool ? j['autoProfile'] as bool : true,
      sensitivity: j['sensitivity'] is num ? (j['sensitivity'] as num).toDouble().clamp(.2, 4.0) : 1.0,
    );
  }
}

/// Perfis do usuário em `~/.config/secada/keymaps/*.json` + perfis embutidos.
class KeymapStore {
  KeymapStore({String? dir}) : dir = dir ?? p.join(SecadaPaths.instance.configDir, 'keymaps');

  final String dir;
  final List<KeymapProfile> builtin = Presets.all();
  final List<KeymapProfile> user = [];
  final Map<KeymapProfile, String> _files = {};
  KeymapPrefs prefs = KeymapPrefs();

  static const _prefsFile = 'prefs.json';

  List<KeymapProfile> get all => [...user, ...builtin];

  Future<void> load() async {
    user.clear();
    _files.clear();
    final d = Directory(dir);
    if (!await d.exists()) return;
    final files = await d.list().where((e) => e is File && e.path.endsWith('.json')).toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final name = p.basename(f.path);
      try {
        final json = jsonDecode(await File(f.path).readAsString());
        if (name == _prefsFile) {
          prefs = KeymapPrefs.fromJson(json);
          continue;
        }
        final profile = KeymapProfile.fromJson(json);
        if (profile == null) {
          log.warn('Perfil de teclas inválido ignorado: $name');
          continue;
        }
        user.add(profile);
        _files[profile] = f.path;
      } catch (e) {
        log.warn('Não foi possível ler $name: $e');
      }
    }
  }

  static String slug(String name) {
    final s = name
        .toLowerCase()
        .replaceAll(RegExp(r'[áàâãä]'), 'a')
        .replaceAll(RegExp(r'[éèêë]'), 'e')
        .replaceAll(RegExp(r'[íìîï]'), 'i')
        .replaceAll(RegExp(r'[óòôõö]'), 'o')
        .replaceAll(RegExp(r'[úùûü]'), 'u')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return s.isEmpty ? 'perfil' : s;
  }

  Future<void> _write(String path, Object json) async {
    await Directory(dir).create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
    await tmp.rename(path); // Escrita atômica.
  }

  /// Grava (ou atualiza) um perfil do usuário.
  Future<void> save(KeymapProfile profile) async {
    var path = _files[profile];
    if (path == null) {
      final base = slug(profile.name);
      var candidate = p.join(dir, '$base.json');
      for (var i = 2; File(candidate).existsSync() || candidate.endsWith(_prefsFile); i++) {
        candidate = p.join(dir, '$base-$i.json');
      }
      path = candidate;
      _files[profile] = path;
      if (!user.contains(profile)) user.add(profile);
    }
    await _write(path, profile.toJson());
  }

  Future<void> delete(KeymapProfile profile) async {
    final path = _files.remove(profile);
    user.remove(profile);
    if (path != null) {
      final f = File(path);
      if (await f.exists()) await f.delete();
    }
  }

  Future<void> savePrefs() => _write(p.join(dir, _prefsFile), prefs.toJson());

  /// Perfil para o app em primeiro plano: o do usuário tem prioridade sobre
  /// o embutido.
  KeymapProfile? forPackage(String pkg) {
    for (final list in [user, builtin]) {
      for (final prof in list) {
        if (prof.packages.contains(pkg)) return prof;
      }
    }
    return null;
  }

  bool isUser(KeymapProfile profile) => user.contains(profile);

  /// Nome que ainda não existe, derivado de [base].
  String uniqueName(String base) {
    final names = all.map((e) => e.name).toSet();
    if (!names.contains(base)) return base;
    for (var i = 2;; i++) {
      final n = '$base ($i)';
      if (!names.contains(n)) return n;
    }
  }
}
