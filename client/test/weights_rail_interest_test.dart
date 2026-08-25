// FR5 (Story A4) — the interest weight's rail UI: "Interest — good places"
// terminology, a 0.0-5.0 slider that opens on 0.0 (no bias) rather than the
// bipolar 2.5 midpoint every other slider defaults to, and ARCH §7.7's
// "inactive in compose" — the promoted anchors are already the spine, so
// the slider disables (but keeps showing) an authored value the same way
// `weights_rail_planning_mode_test.dart` already proved out for the mode
// toggle itself.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/weights_rail.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

const _label = 'Interest — good places';

Segment _segment({double? interest}) => Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-105.27, 40.02],
      end: const [-105.2, 40.05],
      weights: interest == null ? null : WeightProfile(name: 'custom', interest: interest),
    );

Trip _trip(Segment segment) {
  final day = Day(id: 'day-1', index: 1, segments: [segment]);
  return Trip(
    id: 'trip-1',
    title: 'Test trip',
    createdAt: '2026-08-25T00:00:00Z',
    updatedAt: '2026-08-25T00:00:00Z',
    days: [day],
  );
}

Future<void> _pump(WidgetTester tester, Segment segment) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentTripProvider.overrideWith((ref) => CurrentTripNotifier(ref)..open(_trip(segment))),
      ],
      child: MaterialApp(
        home: Scaffold(body: WeightsRail(dayId: 'day-1', segment: segment)),
      ),
    ),
  );
  await tester.pump();
}

WeightSlider _slider(WidgetTester tester) => tester.widget<WeightSlider>(
      find.byWidgetPredicate((w) => w is WeightSlider && w.label == _label),
    );

void main() {
  testWidgets('the interest slider is labelled with FR5\'s "good places" terminology, '
      'not "POI density"', (tester) async {
    await _pump(tester, _segment());

    expect(find.text(_label), findsOneWidget);
    expect(find.text('POI density'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('with no authored preference, the slider opens on 0.0 (no bias) — '
      'unlike the bipolar sliders, which open on 2.5', (tester) async {
    await _pump(tester, _segment());

    expect(_slider(tester).value, 0.0);
  });

  testWidgets('an authored value with decimal precision is preserved', (tester) async {
    await _pump(tester, _segment(interest: 3.5));

    expect(_slider(tester).value, 3.5);
  });

  testWidgets('the slider spans the full 0.0-5.0 range', (tester) async {
    await _pump(tester, _segment());

    final row = find.ancestor(of: find.text(_label), matching: find.byType(Column));
    final slider = tester.widget<Slider>(
      find.descendant(of: row.first, matching: find.byType(Slider)),
    );
    expect(slider.min, 0.0);
    expect(slider.max, 5.0);
  });

  testWidgets('dragging the interest slider writes the interest weight', (tester) async {
    await _pump(tester, _segment());

    final row = find.ancestor(of: find.text(_label), matching: find.byType(Column));
    final slider = tester.widget<Slider>(
      find.descendant(of: row.first, matching: find.byType(Slider)),
    );
    slider.onChanged!(4.0);
    await tester.pump();

    final container = ProviderScope.containerOf(tester.element(find.byType(WeightsRail)));
    final segment = container.read(currentTripProvider).days.single.segments.single;
    expect(segment.weights?.interest, 4.0);
  });

  testWidgets('switching to compose disables the slider without clearing the authored '
      'value (ARCH §7.7 — inactive, not deleted)', (tester) async {
    await _pump(tester, _segment(interest: 4.0));

    await tester.tap(find.text('COMPOSE'));
    await tester.pump();

    expect(_slider(tester).onChanged, isNull);
    expect(_slider(tester).value, 4.0);
    expect(find.textContaining('inactive in compose'), findsOneWidget);
  });

  testWidgets('switching back to explore re-enables the slider', (tester) async {
    await _pump(tester, _segment(interest: 4.0));

    await tester.tap(find.text('COMPOSE'));
    await tester.pump();
    await tester.tap(find.text('EXPLORE'));
    await tester.pump();

    expect(_slider(tester).onChanged, isNotNull);
  });
}
