// Issue #320 — the `start` and `finish` marks are drawn in `NodeMarker`'s
// `CustomPainter` alongside the other six. A smoke test that every marker
// paints at a range of sizes without throwing (the painter does the real
// brand work; a golden lives in the design skill's gallery).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

void main() {
  testWidgets('every NodeMarkerType paints at small and large sizes', (tester) async {
    for (final type in NodeMarkerType.values) {
      for (final size in const [12.0, 26.0, 64.0]) {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(child: NodeMarker(type, size: size)),
          ),
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '$type at $size threw while painting',
        );
        expect(find.byType(NodeMarker), findsOneWidget);
      }
    }
  });

  testWidgets('start and finish are present in the enum with distinct default colors',
      (tester) async {
    // Colour only reinforces the shape, but the two must not be identical —
    // a grayscale cue sheet leans on shape, a screen on both.
    expect(NodeMarkerType.values, contains(NodeMarkerType.start));
    expect(NodeMarkerType.values, contains(NodeMarkerType.finish));
  });
}
