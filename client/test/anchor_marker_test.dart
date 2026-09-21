// #410 — the promoted-anchor mark: a diamond no other marker uses (brand
// guardrail: shape + internal mark, never colour alone), fixed size because
// an anchor is canon rather than a salience-scored candidate.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

void main() {
  testWidgets('every mark renders without throwing', (tester) async {
    for (final mark in AnchorMarkerMark.values) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AnchorMarker(mark: mark)),
      ));
      expect(find.byType(AnchorMarker), findsOneWidget);
    }
  });

  testWidgets('draws at its stated size, not scaled by anything', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AnchorMarker(key: key, size: 28)),
    ));
    final box = key.currentContext!.findRenderObject() as RenderBox;
    expect(box.size, const Size(28, 28));
  });

  testWidgets('renders in light, dark and high-contrast themes', (tester) async {
    for (final theme in [PlotTheme.light(), PlotTheme.dark(), PlotTheme.highContrast()]) {
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: const Scaffold(body: AnchorMarker(mark: AnchorMarkerMark.multiRole)),
      ));
      expect(find.byType(AnchorMarker), findsOneWidget);
    }
  });
}
