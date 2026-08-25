// FR2 (Story A1) — "peaks" terminology in the UI, 0.0-5.0 decimal precision,
// and that dragging the slider writes the climbing weight the way every
// other `WeightsRail` slider already does.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/weights_rail.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

Segment _segment({double? climbing}) => Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-105.27, 40.02],
      end: const [-105.2, 40.05],
      weights: climbing == null ? null : WeightProfile(name: 'custom', climbing: climbing),
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
  testWidgets('the climbing slider is labelled with "peaks" terminology', (tester) async {
    await _pump(tester, _segment());

    expect(find.text('Peaks — climbing'), findsOneWidget);
    expect(find.textContaining('peaks'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('with no authored preference, the slider opens on the indifferent '
      'midpoint (2.5)', (tester) async {
    await _pump(tester, _segment());

    final peaks = tester.widget<WeightSlider>(
      find.byWidgetPredicate((w) => w is WeightSlider && w.label == 'Peaks — climbing'),
    );
    expect(peaks.value, 2.5);
  });

  testWidgets('an authored value with decimal precision is preserved', (tester) async {
    await _pump(tester, _segment(climbing: 3.4));

    final peaks = tester.widget<WeightSlider>(
      find.byWidgetPredicate((w) => w is WeightSlider && w.label == 'Peaks — climbing'),
    );
    expect(peaks.value, 3.4);
  });

  testWidgets('the slider spans the full 0.0-5.0 range', (tester) async {
    await _pump(tester, _segment());

    final slider = tester.widget<Slider>(
      find.descendant(of: find.byType(WeightsRail), matching: find.byType(Slider)).first,
    );
    expect(slider.min, 0.0);
    expect(slider.max, 5.0);
  });

  testWidgets('dragging the peaks slider writes the climbing weight', (tester) async {
    await _pump(tester, _segment());

    final sliderFinder =
        find.descendant(of: find.byType(WeightsRail), matching: find.byType(Slider)).first;
    final slider = tester.widget<Slider>(sliderFinder);
    slider.onChanged!(4.75);
    await tester.pump();

    final container = ProviderScope.containerOf(tester.element(find.byType(WeightsRail)));
    final segment = container.read(currentTripProvider).days.single.segments.single;
    expect(segment.weights?.climbing, 4.75);
  });
}
