// Issue #314 — the design system gives every app header a hairline bottom
// rule so it reads as its own plane above the content field, instead of the
// header, the content area and an empty state all sitting on one flat sheet
// of canvas. The rule is promoted into `PlotTheme` rather than repeated as
// per-screen decoration, so this pins it at the theme level.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

void main() {
  final themes = <String, ThemeData>{
    'light': PlotTheme.light(),
    'dark': PlotTheme.dark(),
    'highContrast': PlotTheme.highContrast(),
  };

  themes.forEach((name, theme) {
    final c = theme.extension<PlotColors>()!;

    group('PlotTheme.$name app header', () {
      test('rules the header off with a border-coloured bottom side', () {
        final shape = theme.appBarTheme.shape;
        expect(shape, isA<Border>());
        final border = shape! as Border;
        expect(border.bottom.color, c.border);
        expect(border.bottom.width, greaterThan(0));
        // Only the bottom edge is drawn — it is a rule, not a frame.
        expect(border.top, BorderSide.none);
        expect(border.left, BorderSide.none);
        expect(border.right, BorderSide.none);
      });

      test('does not lift or tint the header when content scrolls under it', () {
        expect(theme.appBarTheme.elevation, 0);
        expect(theme.appBarTheme.scrolledUnderElevation, 0);
        expect(theme.appBarTheme.surfaceTintColor, Colors.transparent);
      });

      test('keeps the header on the app surface, distinct from the sunk field',
          () {
        expect(theme.appBarTheme.backgroundColor, c.surfaceApp);
        expect(c.surfaceApp, isNot(c.surfaceSunk));
      });
    });
  });
}
