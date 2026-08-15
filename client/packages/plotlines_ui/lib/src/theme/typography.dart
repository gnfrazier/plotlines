import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Three families, each mapped to a job:
/// - Instrument Serif — expressive display (hero lines, the diarist voice)
/// - Archivo — functional UI + body
/// - JetBrains Mono — data, coordinates, cue sheets
class PlotTypography {
  PlotTypography._();

  static TextStyle get _serif => GoogleFonts.instrumentSerif();
  static TextStyle get _sans => GoogleFonts.archivo();
  static TextStyle get _mono => GoogleFonts.jetBrainsMono();

  /// Expressive serif display. Use sparingly for editorial moments.
  static TextStyle display(Color c) => _serif.copyWith(
        fontSize: 56,
        height: 0.92,
        color: c,
        fontWeight: FontWeight.w400,
      );

  static TextStyle h1(Color c) =>
      _sans.copyWith(fontSize: 40, height: 1.05, fontWeight: FontWeight.w800, color: c);
  static TextStyle h2(Color c) =>
      _sans.copyWith(fontSize: 28, height: 1.1, fontWeight: FontWeight.w700, color: c);
  static TextStyle title(Color c) =>
      _sans.copyWith(fontSize: 20, height: 1.2, fontWeight: FontWeight.w700, color: c);
  static TextStyle body(Color c) =>
      _sans.copyWith(fontSize: 16, height: 1.7, fontWeight: FontWeight.w400, color: c);
  static TextStyle small(Color c) =>
      _sans.copyWith(fontSize: 13, height: 1.6, fontWeight: FontWeight.w500, color: c);

  /// Data / mono — numbers, units, coordinates. Often UPPERCASE + tracked.
  static TextStyle data(Color c) => _mono.copyWith(
        fontSize: 12,
        height: 1.4,
        letterSpacing: 0.12 * 12,
        fontWeight: FontWeight.w500,
        color: c,
      );

  /// Builds a Material [TextTheme] from the given foreground colors.
  static TextTheme textTheme(Color primary, Color secondary) => TextTheme(
        displayLarge: display(primary),
        displayMedium: display(primary),
        headlineLarge: h1(primary),
        headlineMedium: h2(primary),
        titleLarge: title(primary),
        bodyLarge: body(primary),
        bodyMedium: body(secondary),
        bodySmall: small(secondary),
        labelLarge: _sans.copyWith(
            fontSize: 16, fontWeight: FontWeight.w700, color: primary),
        labelSmall: data(secondary),
      );
}
