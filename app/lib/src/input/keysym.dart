import 'package:flutter/services.dart';

/// Converte eventos de teclado do Flutter em keysyms X11, o formato usado pelo
/// protocolo RFB. O QEMU traduz o keysym para o scancode do teclado PS/2
/// virtual (layout en-us no convidado).
abstract final class Keysym {
  static const escape = 0xff1b;

  static const xf86Back = 0x1008ff26;
  static const xf86HomePage = 0x1008ff18;

  static final Map<LogicalKeyboardKey, int> _special = {
    LogicalKeyboardKey.backspace: 0xff08,
    LogicalKeyboardKey.tab: 0xff09,
    LogicalKeyboardKey.enter: 0xff0d,
    LogicalKeyboardKey.numpadEnter: 0xff8d,
    LogicalKeyboardKey.escape: 0xff1b,
    LogicalKeyboardKey.delete: 0xffff,
    LogicalKeyboardKey.insert: 0xff63,
    LogicalKeyboardKey.home: 0xff50,
    LogicalKeyboardKey.end: 0xff57,
    LogicalKeyboardKey.pageUp: 0xff55,
    LogicalKeyboardKey.pageDown: 0xff56,
    LogicalKeyboardKey.arrowLeft: 0xff51,
    LogicalKeyboardKey.arrowUp: 0xff52,
    LogicalKeyboardKey.arrowRight: 0xff53,
    LogicalKeyboardKey.arrowDown: 0xff54,
    LogicalKeyboardKey.shiftLeft: 0xffe1,
    LogicalKeyboardKey.shiftRight: 0xffe2,
    LogicalKeyboardKey.controlLeft: 0xffe3,
    LogicalKeyboardKey.controlRight: 0xffe4,
    LogicalKeyboardKey.capsLock: 0xffe5,
    LogicalKeyboardKey.metaLeft: 0xffe7,
    LogicalKeyboardKey.metaRight: 0xffe8,
    LogicalKeyboardKey.altLeft: 0xffe9,
    LogicalKeyboardKey.altRight: 0xffea,
    LogicalKeyboardKey.numLock: 0xff7f,
    LogicalKeyboardKey.scrollLock: 0xff14,
    LogicalKeyboardKey.printScreen: 0xff61,
    LogicalKeyboardKey.pause: 0xff13,
    LogicalKeyboardKey.contextMenu: 0xff67,
    LogicalKeyboardKey.space: 0x20,
    LogicalKeyboardKey.f1: 0xffbe,
    LogicalKeyboardKey.f2: 0xffbf,
    LogicalKeyboardKey.f3: 0xffc0,
    LogicalKeyboardKey.f4: 0xffc1,
    LogicalKeyboardKey.f5: 0xffc2,
    LogicalKeyboardKey.f6: 0xffc3,
    LogicalKeyboardKey.f7: 0xffc4,
    LogicalKeyboardKey.f8: 0xffc5,
    LogicalKeyboardKey.f9: 0xffc6,
    LogicalKeyboardKey.f10: 0xffc7,
    LogicalKeyboardKey.f11: 0xffc8,
    LogicalKeyboardKey.f12: 0xffc9,
    LogicalKeyboardKey.numpad0: 0xffb0,
    LogicalKeyboardKey.numpad1: 0xffb1,
    LogicalKeyboardKey.numpad2: 0xffb2,
    LogicalKeyboardKey.numpad3: 0xffb3,
    LogicalKeyboardKey.numpad4: 0xffb4,
    LogicalKeyboardKey.numpad5: 0xffb5,
    LogicalKeyboardKey.numpad6: 0xffb6,
    LogicalKeyboardKey.numpad7: 0xffb7,
    LogicalKeyboardKey.numpad8: 0xffb8,
    LogicalKeyboardKey.numpad9: 0xffb9,
    LogicalKeyboardKey.numpadDecimal: 0xffae,
    LogicalKeyboardKey.numpadAdd: 0xffab,
    LogicalKeyboardKey.numpadSubtract: 0xffad,
    LogicalKeyboardKey.numpadMultiply: 0xffaa,
    LogicalKeyboardKey.numpadDivide: 0xffaf,
  };

  /// Keysym para o evento de tecla pressionada, ou null se não mapeável.
  static int? forKeyDown(KeyEvent event) {
    final special = _special[event.logicalKey];
    if (special != null) return special;
    final ch = event.character;
    if (ch != null && ch.isNotEmpty) {
      final cp = ch.runes.first;
      if (cp >= 0x20 && cp != 0x7f) return fromCodePoint(cp);
    }
    // Com Ctrl pressionado o caractere pode vir como controle (0x01..0x1f);
    // o keyId de teclas "imprimíveis" é o próprio code point.
    final id = event.logicalKey.keyId;
    if (id >= 0x20 && id <= 0x10ffff) return fromCodePoint(id);
    return null;
  }

  static int fromCodePoint(int cp) =>
      (cp >= 0x20 && cp <= 0xff) ? cp : 0x01000000 | cp;
}

/// Scancodes XT (set 1; prefixo e0 = bit 0x80) usados com a extensão QEMU
/// Extended Key Event. O kernel do convidado converte e0 6a em KEY_BACK (158)
/// e e0 32 em KEY_HOMEPAGE (172); o Generic.kl do Android mapeia esses códigos
/// para BACK e HOME. (A tabela de layout do QEMU trunca keysyms XF86 para 16
/// bits, por isso esses atalhos não funcionam como KeyEvent comum.)
abstract final class XtScancode {
  static const back = 0xea;
  static const homePage = 0xb2;
}
