// FR3 (Story A2) — "cars" terminology in the UI, 0.0-5.0 decimal precision, and
// that dragging the slider writes the traffic weight the way every other
// `WeightsRail` slider already does.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/weights_rail.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

Segment _segment({double? traffic}) => Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-105.27, 40.02],
      end: const [-105.2, 40.05],
      weights: traffic == null ? null : WeightProfile(name: 'custom', traffic: traffic),
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

void main() {
  testWidgets('the traffic slider is labelled with "cars" terminology', (tester) async {
    await _pump(tester, _segment());

    expect(find.text('Cars — traffic tolerance'), findsOneWidget);
    expect(find.textContaining('cars'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('with no authored preference, the slider opens on the indifferent '
      'midpoint (2.5)', (tester) async {
    await _pump(tester, _segment());

    final traffic = tester.widget<WeightSlider>(
      find.byWidgetPredicate((w) => w is WeightSlider && w.label == 'Cars — traffic tolerance'),
    );
    expect(traffic.value, 2.5);
  });

  testWidgets('an authored value with decimal precision is preserved', (tester) async {
    await _pump(tester, _segment(traffic: 1.2));

    final traffic = tester.widget<WeightSlider>(
      find.byWidgetPredicate((w) => w is WeightSlider && w.label == 'Cars — traffic tolerance'),
    );
    expect(traffic.value, 1.2);
  });

  testWidgets('the slider spans the full 0.0-5.0 range', (tester) async {
    await _pump(tester, _segment());

    final sliderFinder =
        find.descendant(of: find.byType(WeightsRail), matching: find.byType(Slider));
    final trafficSliderRow = find.ancestor(
      of: find.text('Cars — traffic tolerance'),
      matching: find.byType(Column),
    );
    final slider = tester.widget<Slider>(
      find.descendant(of: trafficSliderRow.first, matching: find.byType(Slider)),
    );
    expect(sliderFinder, findsWidgets);
    expect(slider.min, 0.0);
    expect(slider.max, 5.0);
  });

  testWidgets('dragging the traffic slider writes the traffic weight', (tester) async {
    await _pump(tester, _segment());

    final trafficSliderRow = find.ancestor(
      of: find.text('Cars — traffic tolerance'),
      matching: find.byType(Column),
    );
    final sliderFinder = find.descendant(of: trafficSliderRow.first, matching: find.byType(Slider));
    final slider = tester.widget<Slider>(sliderFinder);
    slider.onChanged!(0.75);
    await tester.pump();

    final container = ProviderScope.containerOf(tester.element(find.byType(WeightsRail)));
    final segment = container.read(currentTripProvider).days.single.segments.single;
    expect(segment.weights?.traffic, 0.75);
  });
}
