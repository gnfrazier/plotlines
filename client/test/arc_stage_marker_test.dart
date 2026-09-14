// FR38 / O6, issue #392 — the map-side arc-stage badge. Mirrors
// `node_marker_test.dart`'s shape: a smoke test that every known stage paints
// without throwing, plus the "shape carries the meaning" guardrail — the
// five stages must not collapse onto the same icon, and an unrecognised
// stage draws nothing rather than a wrong glyph.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/presentation/map/arc_stage_marker.dart';

const _knownStages = ['exposition', 'rising', 'crux', 'climax', 'resolution'];

void main() {
  test('every known stage has an icon, and no two stages share one', () {
    final icons = _knownStages.map(arcStageIcon).toList();
    expect(icons, everyElement(isNotNull));
    expect(icons.toSet(), hasLength(_knownStages.length),
        reason: 'shape carries the meaning — two stages must not read as the same mark');
  });

  test('an unrecognised stage has no icon', () {
    expect(arcStageIcon('not_a_stage'), isNull);
  });

  testWidgets('every known stage paints without throwing', (tester) async {
    for (final stage in _knownStages) {
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(child: ArcStageBadge(stage)),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: '$stage threw while painting');
      expect(find.byType(ArcStageBadge), findsOneWidget);
      expect(find.byIcon(arcStageIcon(stage)!), findsOneWidget);
    }
  });

  testWidgets('an unrecognised stage renders nothing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: ArcStageBadge('not_a_stage')),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(Icon), findsNothing);
  });
}
