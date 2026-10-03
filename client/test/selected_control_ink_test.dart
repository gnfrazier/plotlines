// Issue #613 — selected chips and segments are filled Riverslate (Material 3's
// secondaryContainer), and several surfaces set their labels in textPrimary
// or textSecondary on top of it: dark ink on dark teal. The fill and its ink
// are now one token pair, stated in the theme and used by every label that
// carries its own colour.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/passage_mode_picker.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

double _luminance(Color c) => c.computeLuminance();
double _contrast(Color a, Color b) {
  final hi = math.max(_luminance(a), _luminance(b)), lo = math.min(_luminance(a), _luminance(b));
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  final themes = <String, ThemeData>{
    'light': PlotTheme.light(),
    'dark': PlotTheme.dark(),
    'highContrast': PlotTheme.highContrast(),
  };

  themes.forEach((name, theme) {
    final c = theme.extension<PlotColors>()!;
    test('$name: the selected fill and its ink are the brand pair, at AA contrast', () {
      expect(theme.colorScheme.secondaryContainer, c.selectedControl);
      expect(theme.colorScheme.onSecondaryContainer, c.onSelectedControl);
      expect(_contrast(c.selectedControl, c.onSelectedControl), greaterThanOrEqualTo(4.5));
    });
  });

  test('light: white ink on Riverslate', () {
    expect(PlotColors.light.selectedControl, PlotColors.slate);
    expect(PlotColors.light.onSelectedControl, const Color(0xFFFFFFFF));
  });

  testWidgets('the passage mode picker inks the selected segment for its fill', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(currentTripProvider.notifier).open(Trip(
          id: 't1',
          title: 'T',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          modes: const {'cycling', 'hiking'},
        ));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: PlotTheme.light(),
        home: Scaffold(body: PassageModePicker(selected: 'cycling', onSelected: (_) {})),
      ),
    ));
    const c = PlotColors.light;
    Color? ink(String label) => tester.widget<Text>(find.text(label)).style?.color;
    expect(ink('Ride'), c.onSelectedControl);
    expect(ink('Hike'), c.textPrimary);
  });
}
