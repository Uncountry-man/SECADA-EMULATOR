import 'dart:convert';

import '../core/app_log.dart';
import 'adb.dart';

/// Códigos de tecla Android (KeyEvent.KEYCODE_*).
abstract final class AndroidKey {
  static const home = 3;
  static const back = 4;
  static const appSwitch = 187;
}

/// Aplicativo instalado pelo usuário.
class InstalledApp {
  InstalledApp(this.packageName, {this.versionName});
  final String packageName;
  final String? versionName;
}

/// Operações de alto nível sobre o Android em execução (via ADB).
class AndroidController {
  AndroidController(this.adb);
  final Adb adb;

  Future<void> pressKey(int keycode) => adb.keyEvent(keycode);

  /// Lista os apps de terceiros (instalados pelo usuário).
  Future<List<InstalledApp>> listUserApps() async {
    final r = await adb.shell('pm list packages -3');
    if (!r.ok) throw AdbError('Não foi possível listar os aplicativos: ${r.text}');
    final apps = <InstalledApp>[];
    for (final line in const LineSplitter().convert(r.text)) {
      final l = line.trim();
      if (l.startsWith('package:')) apps.add(InstalledApp(l.substring(8)));
    }
    apps.sort((a, b) => a.packageName.compareTo(b.packageName));
    return apps;
  }

  /// Abre a atividade principal (LAUNCHER) de um pacote.
  Future<void> launch(String packageName) async {
    final resolved = await adb.shell(
        'cmd package resolve-activity --brief -c android.intent.category.LAUNCHER '
        '$packageName');
    final lines = const LineSplitter()
        .convert(resolved.text)
        .map((l) => l.trim())
        .where((l) => l.contains('/'))
        .toList();
    if (lines.isEmpty) {
      throw AdbError('O aplicativo $packageName não possui tela inicial para abrir.');
    }
    final component = lines.last;
    final r = await adb.shell('am start -n $component');
    log.info('launch $component -> ${r.exitCode} ${r.text}');
    if (!r.ok || r.text.contains('Error')) {
      throw AdbError('Falha ao abrir $packageName: ${r.text}');
    }
  }

  Future<void> uninstall(String packageName) async {
    final r = await adb.runOnDevice(['uninstall', packageName],
        timeout: const Duration(minutes: 2));
    if (!r.text.contains('Success')) {
      throw AdbError('Falha ao desinstalar $packageName: ${r.text} ${r.stderr}');
    }
  }
}
