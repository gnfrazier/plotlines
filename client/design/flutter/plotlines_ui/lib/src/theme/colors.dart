import 'package:flutter/material.dart';

/// Plotlines brand palette + semantic color roles.
///
/// Base tokens are the raw brand colors from the style guide. Semantic getters
/// resolve against the active [PlotBrightness] so the same widget code works in
/// light (canvas), dark (dusk), and outdoor high-contrast modes.
enum PlotBrightness { light, dark, highContrast }

@immutable
class PlotColors extends ThemeExtension<PlotColors> {
  const PlotColors({
    required this.surfaceApp,
    required this.surfaceCard,
    required this.surfaceSunk,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.border,
    required this.primary,
    required this.onPrimary,
    required this.success,
    required this.info,
    required this.warning,
    required this.danger,
  });

  // ---- Base brand tokens (mode-independent references) ----
  static const canvas = Color(0xFFF4EFE4);
  static const panel = Color(0xFFEBE3D4);
  static const paper = Color(0xFFFBF9F3);
  static const ink = Color(0xFF221F1A);
  static const ink2 = Color(0xFF544D42);
  static const ink3 = Color(0xFF8C8476);
  static const line = Color(0xFFD9D0BE);
  static const blaze = Color(0xFFDB5A28); // primary
  static const spruce = Color(0xFF2C4A3B); // land / success
  static const slate = Color(0xFF3D6577); // water / info (Riverslate)
  static const gold = Color(0xFFB5852B); // caution — fills & markers ONLY
  static const ember = Color(0xFF9A3412); // hazard / danger

  final Color surfaceApp;
  final Color surfaceCard;
  final Color surfaceSunk;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color border;
  final Color primary;
  final Color onPrimary;
  final Color success;
  final Color info;
  final Color warning;
  final Color danger;

  static const light = PlotColors(
    surfaceApp: canvas,
    surfaceCard: paper,
    surfaceSunk: panel,
    textPrimary: ink,
    textSecondary: ink2,
    textMuted: ink3,
    border: line,
    primary: blaze,
    onPrimary: Color(0xFFFFFFFF),
    success: spruce,
    info: slate,
    warning: gold,
    danger: ember,
  );

  static const dark = PlotColors(
    surfaceApp: Color(0xFF17140F),
    surfaceCard: Color(0xFF201C16),
    surfaceSunk: Color(0xFF2A251D),
    textPrimary: Color(0xFFF4EFE4),
    textSecondary: Color(0xFFD6CDBB),
    textMuted: Color(0xFF9A9080),
    border: Color(0xFF3A342A),
    primary: Color(0xFFE4703F),
    onPrimary: Color(0xFF1B1712),
    success: Color(0xFF6FB495),
    info: Color(0xFF6FA6BE),
    warning: Color(0xFFD8A845),
    danger: Color(0xFFD9603F),
  );

  /// Outdoor high-contrast: pure black field, white strokes, saturated accents.
  static const highContrast = PlotColors(
    surfaceApp: Color(0xFF000000),
    surfaceCard: Color(0xFF000000),
    surfaceSunk: Color(0xFF0B0B0B),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0xFFF2F2F2),
    textMuted: Color(0xFFCFCFCF),
    border: Color(0xFFFFFFFF),
    primary: Color(0xFFFF6A34),
    onPrimary: Color(0xFF000000),
    success: Color(0xFF7BD6A9),
    info: Color(0xFF7FC2DB),
    warning: Color(0xFFFFCF33),
    danger: Color(0xFFFF4D3D),
  );

  static PlotColors of(BuildContext context) =>
      Theme.of(context).extension<PlotColors>() ?? light;

  @override
  PlotColors copyWith({
    Color? surfaceApp,
    Color? surfaceCard,
    Color? surfaceSunk,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? border,
    Color? primary,
    Color? onPrimary,
    Color? success,
    Color? info,
    Color? warning,
    Color? danger,
  }) {
    return PlotColors(
      surfaceApp: surfaceApp ?? this.surfaceApp,
      surfaceCard: surfaceCard ?? this.surfaceCard,
      surfaceSunk: surfaceSunk ?? this.surfaceSunk,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      border: border ?? this.border,
      primary: primary ?? this.primary,
      onPrimary: onPrimary ?? this.onPrimary,
      success: success ?? this.success,
      info: info ?? this.info,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
    );
  }

  @override
  PlotColors lerp(ThemeExtension<PlotColors>? other, double t) {
    if (other is! PlotColors) return this;
    return PlotColors(
      surfaceApp: Color.lerp(surfaceApp, other.surfaceApp, t)!,
      surfaceCard: Color.lerp(surfaceCard, other.surfaceCard, t)!,
      surfaceSunk: Color.lerp(surfaceSunk, other.surfaceSunk, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      border: Color.lerp(border, other.border, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      onPrimary: Color.lerp(onPrimary, other.onPrimary, t)!,
      success: Color.lerp(success, other.success, t)!,
      info: Color.lerp(info, other.info, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}
