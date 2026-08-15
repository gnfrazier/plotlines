import 'package:flutter/material.dart';
import 'colors.dart';
import 'typography.dart';
import 'tokens.dart';

/// Builds brand-themed Material 3 [ThemeData] for each mode. Adaptive across
/// Android, iOS, web, and desktop — density and target sizes suit touch and
/// pointer alike.
class PlotTheme {
  PlotTheme._();

  static ThemeData light() => _build(PlotColors.light, Brightness.light);
  static ThemeData dark() => _build(PlotColors.dark, Brightness.dark);
  static ThemeData highContrast() =>
      _build(PlotColors.highContrast, Brightness.dark);

  static ThemeData _build(PlotColors c, Brightness brightness) {
    final scheme = ColorScheme(
      brightness: brightness,
      primary: c.primary,
      onPrimary: c.onPrimary,
      secondary: c.info,
      onSecondary: c.onPrimary,
      error: c.danger,
      onError: c.onPrimary,
      surface: c.surfaceCard,
      onSurface: c.textPrimary,
      surfaceContainerHighest: c.surfaceSunk,
      outline: c.border,
      outlineVariant: c.border,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: c.surfaceApp,
      canvasColor: c.surfaceApp,
      dividerColor: c.border,
      splashFactory: InkSparkle.splashFactory,
      textTheme: PlotTypography.textTheme(c.textPrimary, c.textSecondary),
      extensions: <ThemeExtension<dynamic>>[c],
      dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: c.surfaceApp,
        foregroundColor: c.textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: PlotTypography.title(c.textPrimary),
      ),
      cardTheme: CardThemeData(
        color: c.surfaceCard,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: PlotRadii.cardShape,
          side: BorderSide(color: c.border),
        ),
        margin: EdgeInsets.zero,
      ),
      // Primary buttons: label ≥16 bold so paper text clears WCAG on Blaze;
      // min height 48 keeps a comfortable field target.
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: c.primary,
          foregroundColor: c.onPrimary,
          disabledBackgroundColor: c.border,
          disabledForegroundColor: c.textMuted,
          elevation: 0,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: const RoundedRectangleBorder(borderRadius: PlotRadii.controlShape),
          textStyle: PlotTypography.h2(c.onPrimary)
              .copyWith(fontSize: 16, height: 1, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.textPrimary,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          side: BorderSide(color: c.textPrimary, width: 1.5),
          shape: const RoundedRectangleBorder(borderRadius: PlotRadii.controlShape),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          // Ink label (not Blaze) so small text clears contrast on canvas.
          foregroundColor: c.textPrimary,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surfaceCard,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(PlotRadii.lg),
          side: BorderSide(color: c.border),
        ),
        titleTextStyle: PlotTypography.title(c.textPrimary),
        contentTextStyle: PlotTypography.body(c.textSecondary),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surfaceCard,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: c.textSecondary,
        textColor: c.textPrimary,
        minVerticalPadding: 12,
        titleTextStyle: PlotTypography.body(c.textPrimary)
            .copyWith(fontWeight: FontWeight.w600, height: 1.2),
        subtitleTextStyle: PlotTypography.small(c.textSecondary),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.textPrimary,
        contentTextStyle: PlotTypography.small(c.surfaceCard),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
