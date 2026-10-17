import 'package:flutter/services.dart';

import 'keymap_models.dart';

/// Perfis que acompanham o SECADA Emulator: modelos por gênero e perfis por jogo.
///
/// As posições são **pontos de partida** com a disposição típica de cada
/// gênero (controle à esquerda, ações à direita); cada jogo tem seu próprio
/// HUD e o editor serve para ajustá-las com o jogo aberto.
abstract final class Presets {
  static String _k(LogicalKeyboardKey k) => Trigger.key(k);

  static int _n = 0;
  static String _id() => 'p${++_n}';

  static TapBinding _tap(String key, double x, double y) => TapBinding(_id(), key, x, y);

  static DpadBinding _wasd(double x, double y, {double r = .13}) => DpadBinding(
        _id(),
        up: _k(LogicalKeyboardKey.keyW),
        down: _k(LogicalKeyboardKey.keyS),
        left: _k(LogicalKeyboardKey.keyA),
        right: _k(LogicalKeyboardKey.keyD),
        x: x,
        y: y,
        radius: r,
      );

  static AimBinding _aim({double x = .45, double y = .1, double w = .5, double h = .62}) =>
      AimBinding(_id(), _k(LogicalKeyboardKey.f1), x, y, w, h, 1.0);

  static KeymapProfile _fps(String name, {List<String> packages = const [], String note = ''}) {
    return KeymapProfile(
      name: name,
      packages: packages,
      builtin: true,
      note: note.isEmpty
          ? 'WASD anda, F1 liga/desliga a mira com o mouse, botão esquerdo atira, '
              'Espaço pula, C agacha, R recarrega, F interage, Shift corre.'
          : note,
      bindings: [
        _wasd(.15, .68),
        _aim(),
        _tap(Trigger.mouseLeft, .85, .58), // atirar
        _tap(Trigger.mouseRight, .76, .40), // mira (luneta)
        _tap(_k(LogicalKeyboardKey.space), .94, .78), // pular
        _tap(_k(LogicalKeyboardKey.keyC), .80, .80), // agachar
        _tap(_k(LogicalKeyboardKey.keyZ), .94, .50), // deitar
        _tap(_k(LogicalKeyboardKey.keyR), .70, .80), // recarregar
        _tap(_k(LogicalKeyboardKey.keyF), .62, .58), // interagir/pegar
        _tap(_k(LogicalKeyboardKey.shiftLeft), .30, .45), // correr
        _tap(_k(LogicalKeyboardKey.digit1), .44, .92),
        _tap(_k(LogicalKeyboardKey.digit2), .50, .92),
        _tap(_k(LogicalKeyboardKey.digit3), .56, .92),
        _tap(_k(LogicalKeyboardKey.keyM), .92, .10), // mapa
      ],
    );
  }

  static KeymapProfile _moba(String name, {List<String> packages = const []}) {
    return KeymapProfile(
      name: name,
      packages: packages,
      builtin: true,
      note: 'WASD move o herói, Espaço ataca, Q/E/R usam habilidades, F feitiço, '
          'B retorna. O mouse funciona como dedo.',
      bindings: [
        _wasd(.13, .70, r: .12),
        _tap(_k(LogicalKeyboardKey.space), .90, .78), // ataque básico
        _tap(_k(LogicalKeyboardKey.keyQ), .78, .84), // habilidade 1
        _tap(_k(LogicalKeyboardKey.keyE), .80, .62), // habilidade 2
        _tap(_k(LogicalKeyboardKey.keyR), .93, .55), // habilidade 3 (ultimate)
        _tap(_k(LogicalKeyboardKey.keyF), .66, .84), // feitiço
        _tap(_k(LogicalKeyboardKey.keyB), .56, .90), // retornar
        _tap(_k(LogicalKeyboardKey.digit1), .30, .92),
        _tap(_k(LogicalKeyboardKey.digit2), .36, .92),
      ],
    );
  }

  static KeymapProfile _racing(String name, {List<String> packages = const []}) {
    return KeymapProfile(
      name: name,
      packages: packages,
      builtin: true,
      note: '←/→ ou A/D viram, ↑/W acelera, ↓/S freia, Espaço usa nitro, Shift derrapa.',
      bindings: [
        _tap(_k(LogicalKeyboardKey.arrowLeft), .10, .76),
        _tap(_k(LogicalKeyboardKey.arrowRight), .24, .76),
        _tap(_k(LogicalKeyboardKey.keyA), .10, .76),
        _tap(_k(LogicalKeyboardKey.keyD), .24, .76),
        _tap(_k(LogicalKeyboardKey.arrowUp), .90, .76),
        _tap(_k(LogicalKeyboardKey.keyW), .90, .76),
        _tap(_k(LogicalKeyboardKey.arrowDown), .78, .76),
        _tap(_k(LogicalKeyboardKey.keyS), .78, .76),
        _tap(_k(LogicalKeyboardKey.space), .90, .55),
        _tap(_k(LogicalKeyboardKey.shiftLeft), .78, .55),
      ],
    );
  }

  static KeymapProfile _platform(String name, {List<String> packages = const []}) {
    return KeymapProfile(
      name: name,
      packages: packages,
      builtin: true,
      note: '←/→ ou A/D andam, Espaço pula, J e K são ações.',
      bindings: [
        _tap(_k(LogicalKeyboardKey.arrowLeft), .10, .80),
        _tap(_k(LogicalKeyboardKey.arrowRight), .22, .80),
        _tap(_k(LogicalKeyboardKey.keyA), .10, .80),
        _tap(_k(LogicalKeyboardKey.keyD), .22, .80),
        _tap(_k(LogicalKeyboardKey.space), .90, .78),
        _tap(_k(LogicalKeyboardKey.keyJ), .78, .66),
        _tap(_k(LogicalKeyboardKey.keyK), .90, .52),
      ],
    );
  }

  static KeymapProfile _swipes(String name, {List<String> packages = const []}) {
    SwipeBinding s(LogicalKeyboardKey k, double x1, double y1, double x2, double y2) =>
        SwipeBinding(_id(), _k(k), x1, y1, x2, y2);
    return KeymapProfile(
      name: name,
      packages: packages,
      builtin: true,
      note: 'Setas (ou WASD) fazem o deslize correspondente; Espaço toca no centro.',
      bindings: [
        s(LogicalKeyboardKey.arrowLeft, .55, .5, .25, .5),
        s(LogicalKeyboardKey.arrowRight, .45, .5, .75, .5),
        s(LogicalKeyboardKey.arrowUp, .5, .6, .5, .25),
        s(LogicalKeyboardKey.arrowDown, .5, .4, .5, .8),
        s(LogicalKeyboardKey.keyA, .55, .5, .25, .5),
        s(LogicalKeyboardKey.keyD, .45, .5, .75, .5),
        s(LogicalKeyboardKey.keyW, .5, .6, .5, .25),
        s(LogicalKeyboardKey.keyS, .5, .4, .5, .8),
        _tap(_k(LogicalKeyboardKey.space), .5, .5),
      ],
    );
  }

  static KeymapProfile _minecraft() {
    return KeymapProfile(
      name: 'Minecraft',
      packages: const ['com.mojang.minecraftpe'],
      builtin: true,
      note: 'WASD anda, F1 liga a mira, botão esquerdo quebra, direito coloca, '
          'Espaço pula, Shift agacha, E abre o inventário.',
      bindings: [
        _wasd(.14, .70),
        _aim(x: .35, y: .1, w: .6, h: .7),
        _tap(Trigger.mouseLeft, .5, .5),
        _tap(Trigger.mouseRight, .5, .5),
        _tap(_k(LogicalKeyboardKey.space), .90, .66),
        _tap(_k(LogicalKeyboardKey.shiftLeft), .90, .86),
        _tap(_k(LogicalKeyboardKey.keyE), .56, .93),
      ],
    );
  }

  /// GTA San Andreas (e clientes SA-MP, como o Backstage): HUD nativo do GTA
  /// mobile. A pé o direcional fica à esquerda e os botões à direita; de
  /// carro os botões de direção ficam sob o mesmo direcional (WASD) e acelerar
  /// e frear ficam nas setas, na região dos botões da direita.
  static KeymapProfile _gtaSa() {
    return KeymapProfile(
      name: 'GTA San Andreas / SA-MP',
      packages: const ['com.rockstargames.gtasa', 'com.backstage'],
      builtin: true,
      note: 'WASD anda (e dirige para os lados), F1 liga a câmera com o mouse, '
          'botão esquerdo ataca/atira, direito mira, Shift corre, Espaço pula, '
          'F entra/sai do veículo, C agacha, Q troca de arma, V muda a câmera, '
          'M abre o mapa. De carro: ↑ acelera, ↓ freia/ré, Ctrl freio de mão, '
          'H buzina.',
      bindings: [
        _wasd(.13, .72, r: .12),
        _aim(x: .30, y: .08, w: .40, h: .60),
        _tap(Trigger.mouseLeft, .88, .62), // atacar / atirar
        _tap(Trigger.mouseRight, .78, .48), // mirar
        _tap(_k(LogicalKeyboardKey.shiftLeft), .93, .82), // correr
        _tap(_k(LogicalKeyboardKey.space), .81, .84), // pular
        _tap(_k(LogicalKeyboardKey.keyF), .73, .66), // entrar/sair do veículo
        _tap(_k(LogicalKeyboardKey.keyC), .68, .84), // agachar
        _tap(_k(LogicalKeyboardKey.keyQ), .93, .12), // trocar de arma
        _tap(_k(LogicalKeyboardKey.keyV), .50, .10), // câmera
        _tap(_k(LogicalKeyboardKey.keyM), .10, .20), // radar / mapa
        _tap(_k(LogicalKeyboardKey.arrowUp), .91, .80), // acelerar
        _tap(_k(LogicalKeyboardKey.arrowDown), .79, .86), // frear / ré
        _tap(_k(LogicalKeyboardKey.controlLeft), .67, .88), // freio de mão
        _tap(_k(LogicalKeyboardKey.keyH), .56, .88), // buzina
      ],
    );
  }

  /// Todos os perfis embutidos. Cada chamada devolve cópias novas.
  static List<KeymapProfile> all() {
    _n = 0;
    return [
      // Modelos por gênero (sem pacote: servem de ponto de partida).
      _fps('Modelo: Tiro (FPS / Battle Royale)'),
      _moba('Modelo: MOBA'),
      _racing('Modelo: Corrida'),
      _platform('Modelo: Plataforma / Arcade'),
      _swipes('Modelo: Deslizar (endless runner)'),
      // Jogos conhecidos.
      _fps('Free Fire', packages: const ['com.dts.freefireth', 'com.dts.freefiremax']),
      _fps('PUBG Mobile / BGMI',
          packages: const ['com.tencent.ig', 'com.pubg.imobile', 'com.pubg.krmobile']),
      _fps('Call of Duty: Mobile', packages: const ['com.activision.callofduty.shooter']),
      _fps('Standoff 2', packages: const ['com.axlebolt.standoff2']),
      _moba('Mobile Legends', packages: const ['com.mobile.legends']),
      _moba('Wild Rift', packages: const ['com.riotgames.league.wildrift']),
      _racing('Asphalt 9', packages: const ['com.gameloft.android.ANMP.GloftA9HM']),
      _swipes('Subway Surfers', packages: const ['com.kiloo.subwaysurf']),
      _minecraft(),
      _gtaSa(),
    ];
  }

  /// Perfil genérico quando o app em primeiro plano não tem perfil próprio.
  static KeymapProfile generic() => KeymapProfile(
        name: 'Genérico (WASD + Espaço)',
        builtin: true,
        note: 'WASD move e Espaço toca; o mouse funciona como dedo. Abra o editor '
            'para posicionar os botões do seu jogo.',
        bindings: _wasdSpace(),
      );

  static List<KeyBinding> _wasdSpace() {
    _n = 100;
    return [
      _wasd(.15, .68),
      _tap(_k(LogicalKeyboardKey.space), .90, .75),
    ];
  }
}
