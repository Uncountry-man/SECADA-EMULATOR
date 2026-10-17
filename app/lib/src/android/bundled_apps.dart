import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_log.dart';
import '../core/paths.dart';
import 'adb.dart';

/// Aplicativo que o SECADA Emulator pré-instala no Android.
class BundledApp {
  const BundledApp(this.packageName, this.apk, this.label);
  final String packageName;
  final String apk;
  final String label;
}

/// Navegador e bloco de notas pré-instalados (baixados do F-Droid por
/// `scripts/fetch-guest-apps.sh` e embarcados em `runtime/apps`).
///
/// Cada app é instalado uma única vez por VM: o pacote entra num marcador
/// depois de instalado, então se o usuário o desinstalar ele não volta.
abstract final class BundledApps {
  static const apps = <BundledApp>[
    BundledApp('org.mozilla.fennec_fdroid', 'org.mozilla.fennec_fdroid_1570010.apk',
        'Navegador'),
    BundledApp('org.fossify.notes', 'org.fossify.notes_13.apk', 'Notas'),
  ];

  static List<String> get _dirs => [
        p.join(SecadaPaths.bundleDir, 'runtime', 'apps'),
        p.join(SecadaPaths.instance.dataDir, 'runtime', 'apps'),
      ];

  static Future<String?> _find(BundledApp app) async {
    for (final d in _dirs) {
      final f = File(p.join(d, app.apk));
      if (await f.exists()) return f.path;
    }
    return null;
  }

  /// Apps ainda não instalados nesta VM (e cujo APK está disponível).
  static Future<List<(BundledApp, String)>> pending(String vmDir) async {
    final done = await _done(vmDir);
    final out = <(BundledApp, String)>[];
    for (final a in apps) {
      if (done.contains(a.packageName)) continue;
      final apk = await _find(a);
      if (apk == null) {
        log.warn('APK de ${a.label} ausente (execute scripts/fetch-guest-apps.sh)');
        continue;
      }
      out.add((a, apk));
    }
    return out;
  }

  /// Instala os apps pendentes (os atalhos na tela inicial são criados
  /// depois, por `GuestSetup.pinToHome`).
  static Future<void> installPending(Adb adb, String vmDir) async {
    for (final (app, apk) in await pending(vmDir)) {
      final r = await adb.runOnDevice(['install', '-r', apk],
          timeout: const Duration(minutes: 5));
      final ok = r.stdout.contains('Success');
      log.info('Pré-instalação de ${app.packageName}: '
          '${ok ? 'ok' : '${r.text} ${r.stderr}'.trim()}');
      if (ok) {
        await File(_marker(vmDir))
            .writeAsString('${app.packageName}\n', mode: FileMode.append);
      }
    }
  }

  static String _marker(String vmDir) => p.join(vmDir, 'bundled-apps');

  static Future<Set<String>> _done(String vmDir) async {
    final f = File(_marker(vmDir));
    if (!await f.exists()) return {};
    return (await f.readAsLines()).map((l) => l.trim()).where((l) => l.isNotEmpty).toSet();
  }
}
