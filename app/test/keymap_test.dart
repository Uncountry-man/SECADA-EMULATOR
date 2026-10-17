import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:secada/src/keymap/keymap_engine.dart';
import 'package:secada/src/keymap/keymap_models.dart';
import 'package:secada/src/keymap/keymap_store.dart';
import 'package:secada/src/keymap/presets.dart';
import 'package:secada/src/keymap/touch_injector.dart';

/// Resumo legível de um lote de eventos enviado ao QEMU.
class Touch {
  Touch(this.type, this.slot, this.x, this.y, {this.btn});
  final String type; // begin | update | end
  final int slot;
  final double? x, y;
  final bool? btn; // estado de BTN_TOUCH, se o lote o mudou

  @override
  String toString() =>
      '$type s$slot${x == null ? '' : ' (${x!.toStringAsFixed(3)},${y!.toStringAsFixed(3)})'}'
      '${btn == null ? '' : ' btn=$btn'}';
}

List<Touch> summarize(List<List<Map<String, Object?>>> batches) {
  final out = <Touch>[];
  for (final batch in batches) {
    String? type;
    int slot = 0;
    double? x, y;
    bool? btn;
    for (final e in batch) {
      if (e['type'] == 'btn') {
        btn = (e['data'] as Map)['down'] as bool;
        continue;
      }
      final d = e['data'] as Map;
      if (d['type'] != 'data') {
        type = d['type'] as String;
        slot = d['slot'] as int;
        if (type == 'end') expect(d['tracking-id'], -1);
      } else if (d['axis'] == 'x') {
        x = (d['value'] as int) / TouchInjector.absMax;
      } else {
        y = (d['value'] as int) / TouchInjector.absMax;
      }
    }
    out.add(Touch(type!, slot, x, y, btn: btn));
  }
  return out;
}

KeyDownEvent down(LogicalKeyboardKey k) => KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.keyA, logicalKey: k, timeStamp: Duration.zero);
KeyUpEvent up(LogicalKeyboardKey k) =>
    KeyUpEvent(physicalKey: PhysicalKeyboardKey.keyA, logicalKey: k, timeStamp: Duration.zero);

void main() {
  group('TouchInjector', () {
    late List<List<Map<String, Object?>>> sent;
    late TouchInjector inj;
    setUp(() {
      sent = [];
      inj = TouchInjector(sent.add);
    });

    test('toque simples: begin com BTN_TOUCH e posição; end com id -1', () {
      inj.down(0, .25, .5);
      inj.up(0);
      final t = summarize(sent);
      expect(t[0].type, 'begin');
      expect(t[0].btn, isTrue);
      expect(t[0].x, closeTo(.25, .001));
      expect(t[0].y, closeTo(.5, .001));
      expect(t[1].type, 'end');
      expect(t[1].btn, isFalse);
    });

    test('dois dedos: BTN_TOUCH só no primeiro down e no último up', () {
      inj.down(0, .1, .1);
      inj.down(1, .9, .9);
      inj.up(0);
      inj.up(1);
      final t = summarize(sent);
      expect(t.map((e) => e.btn), [true, null, null, false]);
      expect(inj.hasTouch, isFalse);
    });

    test('move só vale para dedo encostado e usa o mesmo tracking-id', () {
      inj.move(3, .5, .5);
      expect(sent, isEmpty);
      inj.down(3, .5, .5);
      final id = ((sent.first.first['data'] as Map)['tracking-id']) as int;
      inj.move(3, .6, .5);
      expect(((sent.last.first['data'] as Map)['tracking-id']), id);
    });

    test('tracking-ids são únicos entre toques', () {
      final ids = <int>{};
      for (var i = 0; i < 20; i++) {
        inj.down(0, .5, .5);
        ids.add(((sent.last.first['data'] as Map)['tracking-id']) as int);
        inj.up(0);
      }
      expect(ids.length, 20);
    });

    test('coordenadas são limitadas à faixa do dispositivo', () {
      inj.down(0, -2, 5);
      final t = summarize(sent).first;
      expect(t.x, 0);
      expect(t.y, 1);
    });

    test('upAll solta tudo', () {
      inj.down(0, .1, .1);
      inj.down(5, .2, .2);
      inj.upAll();
      expect(inj.hasTouch, isFalse);
    });
  });

  group('KeymapEngine', () {
    late List<List<Map<String, Object?>>> sent;
    late KeymapEngine engine;
    setUp(() {
      sent = [];
      engine = KeymapEngine(TouchInjector(sent.add), aspect: () => 2.0);
    });
    tearDown(() => engine.dispose());

    KeymapProfile profile(List<KeyBinding> b) => KeymapProfile(name: 't', bindings: b);

    test('toque: pressionar encosta e soltar levanta; repetição é consumida', () {
      engine.setProfile(profile([TapBinding('a', Trigger.key(LogicalKeyboardKey.space), .9, .7)]));
      expect(engine.handleKey(down(LogicalKeyboardKey.space)), isTrue);
      expect(engine.handleKey(KeyRepeatEvent(
          physicalKey: PhysicalKeyboardKey.space,
          logicalKey: LogicalKeyboardKey.space,
          timeStamp: Duration.zero)), isTrue);
      expect(engine.handleKey(up(LogicalKeyboardKey.space)), isTrue);
      final t = summarize(sent);
      expect(t.map((e) => e.type), ['begin', 'end']);
      expect(t.first.x, closeTo(.9, .001));
    });

    test('tecla sem mapeamento não é consumida', () {
      engine.setProfile(profile([TapBinding('a', Trigger.key(LogicalKeyboardKey.keyQ), .1, .1)]));
      expect(engine.handleKey(down(LogicalKeyboardKey.keyZ)), isFalse);
      expect(sent, isEmpty);
    });

    test('modo digitação devolve as teclas ao Android', () {
      engine.setProfile(profile([TapBinding('a', Trigger.key(LogicalKeyboardKey.keyQ), .1, .1)]));
      engine.setPaused(true);
      expect(engine.handleKey(down(LogicalKeyboardKey.keyQ)), isFalse);
      engine.setPaused(false);
      expect(engine.handleKey(down(LogicalKeyboardKey.keyQ)), isTrue);
    });

    DpadBinding wasd() => DpadBinding('d',
        up: Trigger.key(LogicalKeyboardKey.keyW),
        down: Trigger.key(LogicalKeyboardKey.keyS),
        left: Trigger.key(LogicalKeyboardKey.keyA),
        right: Trigger.key(LogicalKeyboardKey.keyD),
        x: .2,
        y: .7,
        radius: .1);

    test('direcional: começa no centro e anda na direção da tecla', () {
      engine.setProfile(profile([wasd()]));
      engine.handleKey(down(LogicalKeyboardKey.keyD));
      final t = summarize(sent);
      expect(t[0].type, 'begin');
      expect(t[0].x, closeTo(.2, .001));
      expect(t[0].y, closeTo(.7, .001));
      // raio .1 da altura; na horizontal divide pela proporção (2.0).
      expect(t[1].type, 'update');
      expect(t[1].x, closeTo(.2 + .1 / 2, .001));
      expect(t[1].y, closeTo(.7, .001));
    });

    test('direcional: diagonal é normalizada e soltar tudo levanta o dedo', () {
      engine.setProfile(profile([wasd()]));
      engine.handleKey(down(LogicalKeyboardKey.keyW));
      engine.handleKey(down(LogicalKeyboardKey.keyD));
      final last = summarize(sent).last;
      const k = 0.70710678;
      expect(last.x, closeTo(.2 + .1 * k / 2, .001));
      expect(last.y, closeTo(.7 - .1 * k, .001));
      engine.handleKey(up(LogicalKeyboardKey.keyW));
      engine.handleKey(up(LogicalKeyboardKey.keyD));
      expect(summarize(sent).last.type, 'end');
    });

    test('direcional + tiro ao mesmo tempo usam pontos diferentes', () {
      engine.setProfile(profile([
        wasd(),
        TapBinding('t', Trigger.key(LogicalKeyboardKey.space), .9, .6),
      ]));
      engine.handleKey(down(LogicalKeyboardKey.keyW));
      engine.handleKey(down(LogicalKeyboardKey.space));
      final slots = summarize(sent).where((e) => e.type == 'begin').map((e) => e.slot).toSet();
      expect(slots.length, 2);
    });

    test('deslizar: arrasta até o destino e levanta ao soltar', () async {
      engine.setProfile(profile([
        SwipeBinding('s', Trigger.key(LogicalKeyboardKey.arrowLeft), .5, .5, .2, .5),
      ]));
      engine.handleKey(down(LogicalKeyboardKey.arrowLeft));
      engine.handleKey(up(LogicalKeyboardKey.arrowLeft)); // solta antes do fim
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final t = summarize(sent);
      expect(t.first.type, 'begin');
      expect(t.last.type, 'end');
      final lastMove = t.lastWhere((e) => e.type == 'update');
      expect(lastMove.x, closeTo(.2, .001));
    });

    test('mira: liga com a tecla, arrasta a região e recentra na borda', () async {
      engine.setProfile(profile([
        AimBinding('a', Trigger.key(LogicalKeyboardKey.f1), .5, .2, .4, .4, 1.0),
      ]));
      expect(engine.aiming, isFalse);
      engine.handleKey(down(LogicalKeyboardKey.f1));
      expect(engine.aiming, isTrue);
      engine.aimDelta(.05, 0);
      var t = summarize(sent);
      expect(t.first.type, 'begin');
      expect(t.first.x, closeTo(.7, .001)); // centro da região (.5 + .4/2)
      expect(t.last.x, closeTo(.75, .001));
      // Passar do limite direito (.9): levanta e recomeça do centro.
      for (var i = 0; i < 6; i++) {
        engine.aimDelta(.05, 0);
      }
      t = summarize(sent);
      expect(t.where((e) => e.type == 'end').length, greaterThanOrEqualTo(1));
      for (final e in t.where((e) => e.x != null)) {
        expect(e.x!, inInclusiveRange(.5 - .001, .9 + .001));
      }
      // Parado, o dedo da câmera é levantado.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(engine.injector.isDown(8), isFalse);
      engine.handleKey(up(LogicalKeyboardKey.f1));
      engine.handleKey(down(LogicalKeyboardKey.f1));
      expect(engine.aiming, isFalse);
    });

    test('mouse vira dedo fora da mira e botões do perfil dentro dela', () {
      engine.setProfile(profile([
        AimBinding('a', Trigger.key(LogicalKeyboardKey.f1), .5, .2, .4, .4, 1.0),
        TapBinding('fire', Trigger.mouseLeft, .85, .6),
      ]));
      engine.pointer(.3, .3, kPrimaryMouseButton);
      engine.pointer(.35, .3, kPrimaryMouseButton);
      engine.pointer(.35, .3, 0);
      var t = summarize(sent);
      expect(t.map((e) => e.type), ['begin', 'update', 'end']);
      expect(t.every((e) => e.slot == 9), isTrue);

      sent.clear();
      engine.handleKey(down(LogicalKeyboardKey.f1));
      engine.pointer(.3, .3, kPrimaryMouseButton); // dentro da mira: dispara "fire"
      engine.pointer(.3, .3, 0);
      t = summarize(sent);
      expect(t.map((e) => e.type), ['begin', 'end']);
      expect(t.first.x, closeTo(.85, .001));
    });

    test('trocar de perfil ou soltar tudo levanta os dedos', () {
      engine.setProfile(profile([wasd()]));
      engine.handleKey(down(LogicalKeyboardKey.keyW));
      expect(engine.injector.hasTouch, isTrue);
      engine.setProfile(null);
      expect(engine.injector.hasTouch, isFalse);
    });
  });

  group('Perfis', () {
    test('GTA San Andreas ativa para o jogo original e o Backstage', () {
      final gta = Presets.all().firstWhere((p) => p.name.startsWith('GTA San Andreas'));
      expect(gta.packages, containsAll(['com.rockstargames.gtasa', 'com.backstage']));
      expect(gta.builtin, isTrue);
      expect(gta.bindings.whereType<DpadBinding>(), hasLength(1));
      expect(gta.bindings.whereType<AimBinding>(), hasLength(1));
    });

    test('todos os perfis embutidos são válidos e sobrevivem ao JSON', () {
      final all = Presets.all();
      expect(all.length, greaterThan(8));
      final names = <String>{};
      for (final prof in all) {
        expect(names.add(prof.name), isTrue, reason: 'nome repetido: ${prof.name}');
        expect(prof.bindings, isNotEmpty);
        final ids = <String>{};
        for (final b in prof.bindings) {
          expect(ids.add(b.id), isTrue, reason: '${prof.name}: id repetido ${b.id}');
          for (final t in b.triggers) {
            expect(t, isNotEmpty, reason: '${prof.name}: ${b.kind} sem tecla');
          }
          final j = b.toJson();
          for (final k in ['x', 'y', 'x2', 'y2', 'w', 'h']) {
            if (j[k] != null) expect(j[k] as double, inInclusiveRange(0, 1));
          }
        }
        // Dois botões diferentes não podem usar a mesma tecla, exceto se
        // forem mapeamentos equivalentes (ex.: seta e WASD vão a pontos
        // distintos da lista, nunca a mesma tecla duas vezes).
        final used = <String>{};
        for (final b in prof.bindings) {
          for (final t in b.triggers.where((t) => t.isNotEmpty)) {
            expect(used.add(t), isTrue, reason: '${prof.name}: tecla repetida ${Trigger.label(t)}');
          }
        }
        final back = KeymapProfile.fromJson(prof.toJson())!;
        expect(back.toJson(), prof.toJson());
      }
    });

    test('perfis de jogos conhecidos são encontrados pelo pacote', () {
      final store = KeymapStore(dir: '/nao/existe');
      expect(store.forPackage('com.dts.freefireth')?.name, 'Free Fire');
      expect(store.forPackage('com.kiloo.subwaysurf')?.name, 'Subway Surfers');
      expect(store.forPackage('com.exemplo.qualquer'), isNull);
    });

    test('JSON inválido é descartado sem derrubar o resto', () {
      expect(KeymapProfile.fromJson('texto'), isNull);
      expect(KeymapProfile.fromJson({'name': ''}), isNull);
      final p = KeymapProfile.fromJson({
        'name': 'x',
        'bindings': [
          {'type': 'tap', 'key': 'k:97', 'x': 5, 'y': -1, 'id': 'a'},
          {'type': 'tap', 'key': 'k:98', 'x': .5, 'y': .5, 'id': 'a'}, // id repetido
          {'type': 'desconhecido'},
          'lixo',
        ],
      })!;
      expect(p.bindings.length, 2);
      expect(p.bindings.map((b) => b.id).toSet().length, 2);
      final t = p.bindings.first as TapBinding;
      expect(t.x, 1); // limitado a 0..1
      expect(t.y, 0);
    });

    test('rótulos das teclas', () {
      expect(Trigger.label(Trigger.key(LogicalKeyboardKey.keyW)), 'W');
      expect(Trigger.label(Trigger.key(LogicalKeyboardKey.arrowLeft)), '←');
      expect(Trigger.label(Trigger.key(LogicalKeyboardKey.space)), 'Espaço');
      expect(Trigger.label(Trigger.mouseLeft), 'Mouse E');
      expect(Trigger.label(Trigger.none), '—');
    });
  });

  group('KeymapStore', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('secada-keymaps'));
    tearDown(() async => tmp.delete(recursive: true));

    test('grava, relê, renomeia e exclui perfis do usuário', () async {
      final store = KeymapStore(dir: tmp.path);
      final prof = KeymapProfile(name: 'Meu Jogo Ação', packages: ['com.x.y'], bindings: [
        TapBinding('a', Trigger.key(LogicalKeyboardKey.keyE), .3, .4),
      ]);
      await store.save(prof);
      expect(File(p.join(tmp.path, 'meu-jogo-acao.json')).existsSync(), isTrue);

      final again = KeymapStore(dir: tmp.path);
      await again.load();
      expect(again.user.single.name, 'Meu Jogo Ação');
      expect(again.forPackage('com.x.y')?.name, 'Meu Jogo Ação');

      await again.delete(again.user.single);
      expect(Directory(tmp.path).listSync().where((e) => e.path.endsWith('.json')), isEmpty);
    });

    test('perfil do usuário tem prioridade sobre o embutido', () async {
      final store = KeymapStore(dir: tmp.path);
      await store.save(KeymapProfile(name: 'Meu FF', packages: ['com.dts.freefireth']));
      expect(store.forPackage('com.dts.freefireth')?.name, 'Meu FF');
    });

    test('preferências persistem e arquivos inválidos são ignorados', () async {
      final store = KeymapStore(dir: tmp.path);
      store.prefs
        ..showHud = false
        ..sensitivity = 2.5;
      await store.savePrefs();
      File(p.join(tmp.path, 'quebrado.json')).writeAsStringSync('{ não é json');
      final again = KeymapStore(dir: tmp.path);
      await again.load();
      expect(again.prefs.showHud, isFalse);
      expect(again.prefs.sensitivity, 2.5);
      expect(again.user, isEmpty);
    });

    test('nomes únicos e slugs sem acentos', () {
      final store = KeymapStore(dir: tmp.path);
      expect(KeymapStore.slug('Ação & Aventura!'), 'acao-aventura');
      expect(store.uniqueName('Free Fire'), 'Free Fire (2)');
      expect(store.uniqueName('Inédito'), 'Inédito');
    });
  });
}
