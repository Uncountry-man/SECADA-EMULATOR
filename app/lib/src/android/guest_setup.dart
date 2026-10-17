import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_log.dart';
import '../host/host_power.dart';
import 'adb.dart';
import 'arm_translation.dart';
import 'guest_shell.dart';
import 'lean_profile.dart';

/// Configuração do Android feita pelo console root (ver [GuestShell]).
class GuestSetup {
  GuestSetup(this.shell);
  final GuestShell shell;

  Future<String> _sh(String cmd, {Duration timeout = const Duration(seconds: 20)}) async {
    final r = await shell.run(cmd, timeout: timeout);
    log.info('guest: $cmd -> ${r?.exitCode ?? 'timeout'}');
    return r?.output ?? '';
  }

  Future<bool> bootCompleted() async => (await shell.getProp('sys.boot_completed')) == '1';

  /// Fase do boot para a tela de inicialização: 0 = kernel/init,
  /// 1 = framework (zygote) iniciado, 2 = animação de boot, 3 = concluído.
  Future<int> bootPhase() async {
    final r = await shell.run(
        'getprop sys.boot_completed; getprop init.svc.zygote; getprop init.svc.bootanim',
        timeout: const Duration(seconds: 4));
    if (r == null) return 0;
    final p = r.output.split('\n').map((l) => l.trim()).toList();
    if (p.isNotEmpty && p[0] == '1') return 3;
    if (p.length > 2 && p[2] == 'running') return 2;
    if (p.length > 1 && p[1] == 'running') return 1;
    return 0;
  }

  /// Sem barra de navegação: com `qemu.hw.mainkeys=1` o WindowManager trata
  /// o aparelho como tendo teclas físicas e a barra nem é criada (Voltar,
  /// Início e Recentes ficam na barra lateral do SECADA Emulator). A propriedade precisa
  /// existir antes do system_server; o init do Android-x86 (build userdebug)
  /// carrega `/data/local.prop` no post-fs-data, antes do zygote.
  static const localProp = 'qemu.hw.mainkeys=1';

  /// Executado assim que o console responde, ainda no começo do boot: em
  /// discos criados antes do local.prop, faz a propriedade valer já neste
  /// boot se o system_server ainda não a leu.
  Future<void> earlyBoot() => _sh('setprop qemu.hw.mainkeys 1');

  /// Ajustes únicos do primeiro boot. Retorna true se exigem reiniciar o
  /// Android (idioma/fuso só valem após reiniciar).
  Future<bool> firstBoot() async {
    final locale = HostPower.locale();
    final tz = await HostPower.timezone();
    await _sh('cmd package set-home-activity com.android.launcher3/.Launcher');
    await _sh('settings put system screen_off_timeout 2147483647');
    await _sh('settings put global stay_on_while_plugged_in 7');
    await _sh('settings put system accelerometer_rotation 0');
    await _sh('settings put system user_rotation 0');
    await _sh('locksettings set-disabled true');
    await _sh('settings put secure immersive_mode_confirmations confirmed');
    await _sh('setprop persist.adb.tcp.port 5555');
    // Já começa com as opções do desenvolvedor liberadas e a depuração USB
    // ligada (o adbd escuta em TCP para o encaminhamento local do QEMU).
    await _sh('settings put global development_settings_enabled 1; '
        'settings put global adb_enabled 1');
    var needsRestart = false;
    if (locale != null && await shell.getProp('persist.sys.locale') != locale) {
      await _sh('setprop persist.sys.locale $locale');
      needsRestart = true;
    }
    if (tz != null && await shell.getProp('persist.sys.timezone') != tz) {
      await _sh('setprop persist.sys.timezone $tz');
      needsRestart = true;
    }
    return needsRestart;
  }

  /// Componente HOME do Taskbar (modo desktop do Android-x86): um segundo
  /// launcher que faz o Android perguntar qual usar.
  static const _taskbarHome =
      'com.farmerbb.taskbar.androidx86/com.farmerbb.taskbar.activity.HomeActivity';

  /// Garante um único launcher padrão, sem o seletor "Usar como Página
  /// inicial". O Android guarda a preferência junto com o conjunto de
  /// launchers existentes; ao mudar esse conjunto (o Taskbar volta quando o
  /// perfil enxuto é desligado, por exemplo) a preferência se perde e o
  /// seletor aparece. Por isso o Taskbar é desativado e o Launcher3 é
  /// redefinido sempre que o seletor ainda aparecer. Launchers instalados
  /// pelo usuário e escolhidos com "Sempre" continuam valendo.
  Future<void> ensureHome() async {
    const resolve = 'cmd package resolve-activity --brief -a '
        'android.intent.action.MAIN -c android.intent.category.HOME | tail -1';
    final out = await _sh('pm disable $_taskbarHome >/dev/null 2>&1; '
        'case "\$($resolve)" in *ResolverActivity*) '
        'cmd package set-home-activity com.android.launcher3/.Launcher;; esac; '
        '$resolve');
    log.info('Launcher padrão: ${out.trim().split('\n').last}');
  }

  // ------------------------------------------------------------- tradução ARM
  /// Tradutor montado e registrado no kernel (ver [ArmTranslation]).
  Future<bool> armActive() async {
    final r = await shell.run(
        '[ -e /proc/sys/fs/binfmt_misc/arm_exe ] && [ -s /system/lib/libhoudini.so ] && echo ativo',
        timeout: const Duration(seconds: 8));
    return r?.output.contains('ativo') ?? false;
  }

  /// O arquivo do tradutor já está no Android (em qualquer das pastas que o
  /// `enable_nativebridge` usa).
  Future<bool> armFilePresent() async {
    final r = await shell.run(
        'for f in /data/media/0/arm/${ArmTranslation.fileName} /data/arm/${ArmTranslation.fileName}; do '
        '[ "\$(stat -c %s \$f 2>/dev/null)" = "${ArmTranslation.sizeBytes}" ] && echo presente; done',
        timeout: const Duration(seconds: 8));
    return r?.output.contains('presente') ?? false;
  }

  /// Move o arquivo enviado por ADB para a pasta onde o serviço o procura
  /// (dono media_rw, como o próprio script cria). Fica direto em
  /// /data/media/0/arm porque, se o serviço já estiver esperando o arquivo,
  /// é ali que ele tenta montar a cada volta.
  Future<bool> installArmFile(String pushedPath) async {
    final r = await shell.run(
        'mkdir -p /data/media/0/arm && chown 1023:1023 /data/media/0/arm && '
        'mv $pushedPath /data/media/0/arm/${ArmTranslation.fileName} && '
        'chown 1023:1023 /data/media/0/arm/${ArmTranslation.fileName} && '
        'chmod 664 /data/media/0/arm/${ArmTranslation.fileName}',
        timeout: const Duration(seconds: 20));
    return r?.ok ?? false;
  }

  /// Tradutor ARM 64 bits montado e registrado (ver [Arm64Translation]).
  Future<bool> arm64Active() async {
    final r = await shell.run(
        '[ -e /proc/sys/fs/binfmt_misc/arm64_exe ] && [ -s /system/lib64/libhoudini.so ] && echo ativo',
        timeout: const Duration(seconds: 8));
    return r?.output.contains('ativo') ?? false;
  }

  /// O Android foi iniciado com `arm64-v8a` nas ABIs (initrd do SECADA Emulator).
  Future<bool> arm64Declared() async =>
      (await shell.getProp('ro.product.cpu.abilist64')).contains('arm64-v8a');

  Future<bool> arm64FilePresent(int size) async {
    final r = await shell.run(
        '[ "\$(stat -c %s /data/media/0/arm/${Arm64Translation.fileName} 2>/dev/null)" = "$size" ] '
        '&& echo presente',
        timeout: const Duration(seconds: 8));
    return r?.output.contains('presente') ?? false;
  }

  Future<bool> installArm64File(String pushedPath) async {
    final r = await shell.run(
        'mkdir -p /data/media/0/arm && chown 1023:1023 /data/media/0/arm && '
        'mv $pushedPath /data/media/0/arm/${Arm64Translation.fileName} && '
        'chown 1023:1023 /data/media/0/arm/${Arm64Translation.fileName} && '
        'chmod 664 /data/media/0/arm/${Arm64Translation.fileName}',
        timeout: const Duration(seconds: 20));
    return r?.ok ?? false;
  }

  /// (Re)inicia o serviço de 64 bits criado pelo initrd do SECADA Emulator. Só é
  /// chamado com o tradutor ainda inativo: o serviço pode estar esperando
  /// o arquivo (tenta a cada 30 s) e reiniciá-lo monta na hora.
  Future<void> startArm64() =>
      _sh('stop nativebridge64; start nativebridge64');

  /// Liga/desliga a tradução. Ligar inicia o serviço `nativebridge` (só
  /// quando o tradutor ainda não está ativo: rodá-lo de novo derrubaria apps
  /// ARM em execução).
  Future<void> setArmEnabled(bool on) async {
    if (on) {
      await _sh('setprop persist.sys.nativebridge 1; start nativebridge');
    } else {
      await _sh('setprop persist.sys.nativebridge 0');
    }
  }

  /// Remove os apps de câmera (ver [LeanProfile.alwaysRemoved]).
  Future<void> removeCameraApps() => _sh(
      'for p in ${LeanProfile.alwaysRemoved.join(' ')}; do '
      'pm path \$p >/dev/null 2>&1 && pm uninstall -k --user 0 \$p >/dev/null 2>&1; '
      'done');

  /// Ajustes aplicados a cada boot (rápidos e idempotentes).
  Future<void> everyBoot() async {
    // Paisagem nativa ocupando todo o framebuffer. O modo imersivo é só uma
    // segunda garantia contra a barra de navegação (ver [localProp]).
    await _sh('wm size reset; settings put system user_rotation 0; '
        'settings put global policy_control immersive.navigation=*; '
        'grep -qx "$localProp" /data/local.prop 2>/dev/null || '
        '{ echo "$localProp" > /data/local.prop; chmod 644 /data/local.prop; }');
    await applyBattery(await HostPower.read());
  }

  Future<void> applyBattery(HostPower p) async {
    await shell.run(
        'dumpsys battery set present 1; dumpsys battery set level ${p.level}; '
        'dumpsys battery set ac ${p.acOnline ? 1 : 0}; '
        'dumpsys battery set status ${p.status}',
        timeout: const Duration(seconds: 10));
  }

  /// Grava listas em /data/local/tmp em blocos curtos (o terminal serial
  /// não lida bem com linhas muito longas).
  Future<void> _writeList(String file, List<String> items) async {
    await _sh('rm -f $file');
    for (var i = 0; i < items.length; i += 12) {
      final chunk = items.skip(i).take(12).map((e) => "'$e'").join(' ');
      await shell.run('for x in $chunk; do echo "\$x" >> $file; done');
    }
  }

  /// Aplica o perfil enxuto ([LeanProfile]). Idempotente e rápido quando já
  /// aplicado (uma única listagem de pacotes). Retorna quantos foram
  /// removidos nesta passagem.
  Future<int> applyLean() async {
    const list = '/data/local/tmp/secada-lean.txt';
    const comps = '/data/local/tmp/secada-lean-comps.txt';
    await _writeList(list, LeanProfile.packages);
    await _writeList(comps, LeanProfile.settingsSuggestions);
    final r = await shell.run(
        'n=0; installed=\$(pm list packages -e); '
        'for p in \$(cat $list); do '
        'if echo "\$installed" | grep -qx "package:\$p"; then '
        'o=\$(pm uninstall -k --user 0 "\$p" 2>&1); '
        'case "\$o" in *Success*) n=\$((n+1));; '
        '*) pm disable-user --user 0 "\$p" >/dev/null 2>&1 && n=\$((n+1));; esac; '
        'fi; done; '
        'while read c; do pm disable "\$c" >/dev/null 2>&1; done < $comps; '
        'if [ \$n -gt 0 ]; then pm clear com.android.launcher3 >/dev/null 2>&1; fi; '
        // Sem o Chrome, o WebView standalone passa a ser o provedor (apps que
        // exibem conteúdo web dependem dele).
        'pm enable com.google.android.webview >/dev/null 2>&1; '
        'cmd webviewupdate set-webview-implementation com.google.android.webview '
        '>/dev/null 2>&1; '
        'echo "lean=\$n"',
        timeout: const Duration(minutes: 3));
    final n = int.tryParse(RegExp(r'lean=(\d+)').firstMatch(r?.output ?? '')?.group(1) ?? '') ?? 0;
    log.info('Perfil enxuto: $n pacote(s) removido(s) nesta inicialização');
    return n;
  }

  /// Desfaz o perfil enxuto (restaura todos os pacotes da imagem).
  Future<void> restoreFull() async {
    const list = '/data/local/tmp/secada-lean.txt';
    const comps = '/data/local/tmp/secada-lean-comps.txt';
    await _writeList(list, LeanProfile.packages);
    await _writeList(comps, LeanProfile.settingsSuggestions);
    await shell.run(
        'for p in \$(cat $list); do cmd package install-existing "\$p" >/dev/null 2>&1; '
        'pm enable "\$p" >/dev/null 2>&1; done; '
        'while read c; do pm enable "\$c" >/dev/null 2>&1; done < $comps',
        timeout: const Duration(minutes: 3));
    log.info('Perfil enxuto desfeito: pacotes da imagem restaurados');
  }

  /// Coloca atalhos de [packages] na tela inicial (linha abaixo da busca).
  ///
  /// O Launcher3 do Android 9 só cria atalhos sozinho para instalações
  /// feitas pela loja (motivo "usuário"); as do ADB não ganham ícone. Então
  /// os itens são gravados direto no banco do launcher, com ele parado. O
  /// script vai por ADB (linhas longas não passam bem pelo console) e roda
  /// como root pelo console. Pacotes que já têm atalho são ignorados.
  Future<bool> pinToHome(Adb adb, List<String> packages) async {
    const remote = '/data/local/tmp/secada-home.sh';
    final tmp = await Directory.systemTemp.createTemp('secada-home');
    try {
      final f = File(p.join(tmp.path, 'secada-home.sh'));
      await f.writeAsString(_pinScript);
      final push = await adb.runOnDevice(['push', f.path, remote]);
      if (!push.ok) {
        log.warn('Atalhos na tela inicial: push falhou: ${push.stderr}');
        return false;
      }
    } finally {
      await tmp.delete(recursive: true);
    }
    final r = await shell.run('sh $remote ${packages.join(' ')}; rm -f $remote',
        timeout: const Duration(seconds: 40));
    log.info('Atalhos na tela inicial: ${r?.exitCode ?? 'timeout'} ${r?.output ?? ''}');
    return r?.ok ?? false;
  }

  // O Android reabre o launcher assim que ele é parado (é a tela inicial),
  // então tudo é gravado numa única transação e o launcher é parado de novo
  // no fim para recarregar o banco já completo.
  static const _pinScript = r"""
dir=/data/data/com.android.launcher3/databases
db=$dir/launcher.db
sql=/data/local/tmp/secada-home.sql
[ -f $db ] || { echo "sem launcher.db"; exit 3; }
q() { sqlite3 $db "$1"; }
id=$(q "select ifnull(max(_id),0) from favorites")
x=0
echo "begin; insert or ignore into workspaceScreens (_id, screenRank) values (0, 0);" > $sql
for p in "$@"; do
  c=$(cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$p" | tail -1)
  case "$c" in */*) ;; *) continue ;; esac
  [ "$(q "select count(*) from favorites where intent like '%component=$c;%'")" = 0 ] || continue
  while [ "$(q "select count(*) from favorites where container=-100 and screen=0 and cellY=1 and cellX=$x")" != 0 ]; do
    x=$((x + 1))
  done
  id=$((id + 1))
  echo "insert into favorites (_id,intent,container,screen,cellX,cellY,spanX,spanY,itemType,profileId) values ($id,'#Intent;action=android.intent.action.MAIN;category=android.intent.category.LAUNCHER;launchFlags=0x10200000;component=$c;end',-100,0,$x,1,1,1,0,0);" >> $sql
  echo "+ $c"
  x=$((x + 1))
done
echo "commit;" >> $sql
am force-stop com.android.launcher3
sqlite3 $db < $sql || exit 4
rm -f $sql
chown $(stat -c %u:%g $dir) $dir/*
restorecon -R $dir >/dev/null 2>&1
am force-stop com.android.launcher3
am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1
exit 0
""";

  Future<bool> wifiConnected() async {
    final out = await shell.run('dumpsys wifi | grep -m1 mNetworkInfo',
        timeout: const Duration(seconds: 10));
    return out?.output.contains('state: CONNECTED') ?? false;
  }

  /// Conecta o Wi-Fi virtual ("VirtWifi" do Android-x86) pela própria tela de
  /// Wi-Fi do Android, para que ele crie e salve a rede do jeito oficial; nos
  /// boots seguintes ela reconecta sozinha.
  Future<bool> ensureWifi() async {
    for (var attempt = 1; attempt <= 4; attempt++) {
      if (await wifiConnected()) return true;
      await _sh('svc wifi enable');
      await _sh('am start -a android.settings.WIFI_SETTINGS');
      await Future<void>.delayed(const Duration(seconds: 3));
      final dump = await _sh(
          'uiautomator dump /data/local/tmp/secada-ui.xml >/dev/null 2>&1; '
          'grep -o \'text="VirtWifi"[^>]*bounds="[^"]*"\' /data/local/tmp/secada-ui.xml',
          timeout: const Duration(seconds: 30));
      final m = RegExp(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"').firstMatch(dump);
      if (m != null) {
        final x = (int.parse(m.group(1)!) + int.parse(m.group(3)!)) ~/ 2;
        final y = (int.parse(m.group(2)!) + int.parse(m.group(4)!)) ~/ 2;
        await _sh('input tap $x $y');
      }
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (await wifiConnected()) {
          await _sh('input keyevent 3');
          log.info('Wi-Fi conectado (tentativa $attempt)');
          return true;
        }
      }
    }
    await _sh('input keyevent 3');
    log.warn('Não foi possível conectar o Wi-Fi virtual');
    return false;
  }

  Future<void> reboot() => _sh('reboot', timeout: const Duration(seconds: 3));
  Future<void> powerOff() => _sh('reboot -p', timeout: const Duration(seconds: 3));
}
