import 'dart:io';

import 'package:secada/src/host/host_info.dart';
import 'package:secada/src/settings/vm_settings.dart';
import 'package:flutter_test/flutter_test.dart';

const _host = HostInfo(
  kvmPresent: true,
  kvmAccessible: true,
  kvmApiVersion: 12,
  logicalCpus: 8,
  memTotalMb: 16000,
  memAvailableMb: 9000,
);

void main() {
  test('padrões são válidos num host comum', () {
    expect(const VmSettings().validate(_host), isEmpty);
  });

  test('rejeita mais vCPUs que núcleos lógicos', () {
    final e = const VmSettings(cpus: 9).validate(_host);
    expect(e.single, contains('8 núcleos'));
  });

  test('rejeita RAM insuficiente e RAM que esgota o host', () {
    expect(const VmSettings(memoryMb: 1024).validate(_host), isNotEmpty);
    expect(const VmSettings(memoryMb: 15500).validate(_host), isNotEmpty);
  });

  test('avisa (sem bloquear) quando a RAM livre é menor que a alocada', () {
    final warnings = <String>[];
    final e = const VmSettings(memoryMb: 12000).validate(_host, warnings: warnings);
    expect(e, isEmpty);
    expect(warnings, isNotEmpty);
  });

  test('resolução, DPI, disco e porta inválidos', () {
    expect(const VmSettings(width: 1366).validate(_host).single, contains('múltipla de 8'));
    expect(const VmSettings(width: 320).validate(_host), isNotEmpty);
    expect(const VmSettings(dpi: 90).validate(_host), isNotEmpty);
    expect(const VmSettings(diskGb: 4).validate(_host), isNotEmpty);
    expect(const VmSettings(adbPort: 80).validate(_host), isNotEmpty);
    expect(const VmSettings(width: 720, height: 1280).validate(_host),
        contains(contains('paisagem')));
  });

  test('JSON ida e volta preserva todos os campos', () {
    const s = VmSettings(
      cpus: 2,
      memoryMb: 3072,
      width: 1600,
      height: 900,
      dpi: 200,
      diskGb: 48,
      audio: false,
      autoStart: false,
      graphics: GraphicsMode.virgl,
      escAsBack: false,
      imagePath: '/x.iso',
      adbPort: 7000,
    );
    final back = VmSettings.fromJson(s.toJson());
    expect(back.toJson(), s.toJson());
  });

  test('JSON corrompido ou parcial cai nos padrões', () {
    final s = VmSettings.fromJson({'cpus': 'muitos', 'graphics': 'inexistente'});
    expect(s.cpus, 4);
    expect(s.graphics, GraphicsMode.virgl);
  });

  test('configuração antiga por software passa a usar a GPU', () {
    expect(VmSettings.fromJson({'graphics': 'standard'}).graphics, GraphicsMode.virgl);
    // A chave antiga "graphicsRev: 2" equivale à revisão 2.
    expect(VmSettings.fromJson({'graphics': 'standard', 'graphicsRev': 2}).graphics,
        GraphicsMode.standard);
    // Escolha feita depois da migração é respeitada.
    final kept = VmSettings.fromJson(
        {'graphics': 'standard', 'defaultsRev': VmSettings.defaultsRev});
    expect(kept.graphics, GraphicsMode.standard);
  });

  test('Android enxuto vem desligado de fábrica e migra configurações antigas', () {
    expect(const VmSettings().leanAndroid, isFalse);
    expect(VmSettings.fromJson({}).leanAndroid, isFalse);
    // Valor gravado por uma versão em que o padrão era ligado.
    expect(VmSettings.fromJson({'leanAndroid': true}).leanAndroid, isFalse);
    expect(VmSettings.fromJson({'leanAndroid': true, 'graphicsRev': 2}).leanAndroid,
        isFalse);
    // Escolha explícita na revisão atual é respeitada.
    expect(
        VmSettings.fromJson({'leanAndroid': true, 'defaultsRev': VmSettings.defaultsRev})
            .leanAndroid,
        isTrue);
  });

  test('SettingsStore grava de forma atômica e relê', () async {
    final dir = await Directory.systemTemp.createTemp('secada-settings');
    addTearDown(() => dir.delete(recursive: true));
    final store = SettingsStore(path: '${dir.path}/settings.json');
    expect((await store.load()).cpus, 4);
    await store.save(const VmSettings(cpus: 6));
    expect((await store.load()).cpus, 6);
    expect(File('${dir.path}/settings.json.tmp').existsSync(), isFalse);
  });
}
