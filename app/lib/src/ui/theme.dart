import 'package:flutter/material.dart';

/// Identidade visual do SECADA Emulator: grafite neutro com acento verde-petróleo.
abstract final class SecadaTheme {
  static const seed = Color(0xFF2F8F83);
  static const surfaceDeep = Color(0xFF0F1113); // fundo da área do Android
  static const titleBarHeight = 40.0;
  static const sideBarWidth = 56.0;

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
      surface: const Color(0xFF16181B),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.compact,
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }

  static Color stateColor(ColorScheme cs, String state) => switch (state) {
        'running' => const Color(0xFF4CAF7D),
        'booting' || 'preparing' || 'stopping' => const Color(0xFFE0A93B),
        'error' => cs.error,
        _ => cs.outline,
      };
}
