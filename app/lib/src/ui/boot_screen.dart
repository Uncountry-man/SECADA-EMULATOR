import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../vm/vm_controller.dart';

/// Tela exibida enquanto a máquina virtual e o Android inicializam (ou
/// desligam). Cobre a área do Android até ele estar pronto para uso.
///
/// Layout: fundo grafite com hexágonos discretos nas bordas, marca "SECADA" no
/// centro e, no rodapé, uma linha fina de progresso (com o percentual
/// acompanhando a ponta) sobre uma faixa de status com dicas e a etapa atual.
class BootScreen extends StatefulWidget {
  const BootScreen({super.key, required this.controller});
  final VmController controller;

  static const background = Color(0xFF2A2C31);
  static const footer = Color(0xFF1F2024);
  static const accent = Color(0xFF3FB6A5);

  @override
  State<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends State<BootScreen> with SingleTickerProviderStateMixin {
  static const _tips = [
    'Arraste um APK ou XAPK para a janela (ou dê dois cliques nele) para instalar',
    'F11 alterna a tela cheia',
    'Voltar, Início e Recentes ficam na barra lateral',
    'Gire a tela pela barra lateral para usar apps em modo retrato',
    'Ajuste CPU, memória e resolução em Configurações',
  ];

  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  )..repeat();
  late final Timer _tipTimer;
  int _tip = 0;

  @override
  void initState() {
    super.initState();
    _tipTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (mounted) setState(() => _tip = (_tip + 1) % _tips.length);
    });
  }

  @override
  void dispose() {
    _tipTimer.cancel();
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.controller;
    final stopping = vm.state == VmState.stopping;
    final progress = vm.bootProgress;
    final step = stopping ? 'Desligando o Android…' : vm.bootStep;
    final tip = vm.firstBoot && !stopping
        ? 'Primeira inicialização: configurando Wi-Fi, idioma e apps '
            '(cerca de 1 minuto, só desta vez)'
        : _tips[_tip];
    final determinate = !stopping && progress > 0.01;

    return ColoredBox(
      color: BootScreen.background,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      radius: 0.9,
                      colors: [Color(0xFF2F3137), BootScreen.background],
                    ),
                  ),
                ),
                RepaintBoundary(
                  child: CustomPaint(painter: _HexagonsPainter(_drift)),
                ),
                Center(
                  child: FractionallySizedBox(
                    widthFactor: 0.34,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: FittedBox(
                        child: _Wordmark(dimmed: stopping),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _ProgressLine(
                    value: determinate ? progress.clamp(0.0, 1.0) : null,
                  ),
                ),
              ],
            ),
          ),
          _Footer(tip: tip, step: step),
        ],
      ),
    );
  }
}

/// Logotipo "SECADA" (imagem) + selo com a versão do Android.
class _Wordmark extends StatelessWidget {
  const _Wordmark({required this.dimmed});
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: dimmed ? 0.6 : 1,
      duration: const Duration(milliseconds: 400),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset('assets/secada-wordmark.png',
              height: 54, filterQuality: FilterQuality.high),
          const SizedBox(width: 12),
          Container(
            width: 48,
            height: 54,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: BootScreen.accent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              '9',
              style: TextStyle(
                color: Color(0xFF14171A),
                fontSize: 42,
                height: 1,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Linha fina de progresso de largura total; o percentual fica num selo na
/// ponta da barra. Sem valor ([value] nulo), mostra um trecho deslizante.
class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.value});
  final double? value;

  static const _line = 2.0;
  static const _pillW = 34.0;
  static const _pillH = 14.0;

  @override
  Widget build(BuildContext context) {
    final v = value;
    if (v == null) {
      return const SizedBox(
        height: _line,
        child: LinearProgressIndicator(
          minHeight: _line,
          color: BootScreen.accent,
          backgroundColor: Color(0x14FFFFFF),
        ),
      );
    }
    return SizedBox(
      height: _pillH,
      child: LayoutBuilder(builder: (context, box) {
        final head = box.maxWidth * v;
        final pillLeft = (head - _pillW / 2).clamp(0.0, box.maxWidth - _pillW);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: _line,
              child: const ColoredBox(color: Color(0x14FFFFFF)),
            ),
            Positioned(
              left: 0,
              bottom: 0,
              height: _line,
              width: head,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF2F8F83), BootScreen.accent],
                  ),
                ),
              ),
            ),
            Positioned(
              left: pillLeft,
              bottom: 0,
              width: _pillW,
              height: _pillH,
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: BootScreen.accent,
                  borderRadius: BorderRadius.circular(_pillH / 2),
                ),
                child: Text(
                  '${(v * 100).round()}%',
                  style: const TextStyle(
                    color: Color(0xFF0E1A18),
                    fontSize: 9.5,
                    height: 1,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        );
      }),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.tip, required this.step});
  final String tip;
  final String step;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: Color(0xFFA3A7AE), fontSize: 11.5, height: 1);
    return Container(
      height: 24,
      color: BootScreen.footer,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.centerLeft,
                children: [...previous, ?current],
              ),
              child: Text(tip,
                  key: ValueKey(tip),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 2,
            child: Text(step,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: style),
          ),
        ],
      ),
    );
  }
}

/// Hexágonos translúcidos nas bordas, flutuando devagar.
class _HexagonsPainter extends CustomPainter {
  _HexagonsPainter(this.t) : super(repaint: t);
  final Animation<double> t;

  // (x, y) em fração da área; raio em fração da altura; opacidade.
  static const _hexes = <(double, double, double, double)>[
    (0.10, 0.06, 0.24, 0.035),
    (0.215, 0.36, 0.105, 0.028),
    (0.02, 0.43, 0.17, 0.032),
    (0.04, 0.60, 0.055, 0.024),
    (0.29, -0.02, 0.07, 0.02),
    (0.985, 0.66, 0.14, 0.032),
    (0.87, 0.98, 0.14, 0.028),
    (0.995, 0.97, 0.09, 0.024),
    (0.80, 0.08, 0.06, 0.016),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final phase = t.value * 2 * math.pi;
    for (var i = 0; i < _hexes.length; i++) {
      final (fx, fy, fr, alpha) = _hexes[i];
      final r = fr * size.height;
      final c = Offset(fx * size.width, fy * size.height + math.sin(phase + i * 1.7) * 3);
      final path = Path();
      for (var k = 0; k < 6; k++) {
        final a = math.pi / 6 + k * math.pi / 3; // vértice para cima
        final pt = c + Offset(math.cos(a) * r, math.sin(a) * r);
        k == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
      }
      path.close();
      canvas.drawPath(path, Paint()..color = Colors.white.withValues(alpha: alpha));
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = Colors.white.withValues(alpha: alpha * 0.6));
    }
  }

  @override
  bool shouldRepaint(_HexagonsPainter old) => false;
}
