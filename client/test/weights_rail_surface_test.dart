// FR4 (Story A3) — three independent surface sliders (paved/gravel/singletrack) in
// the weights rail, each 0.0-5.0 decimal precision, avoid<->indifferent<->seek, set
// independently rather than only relative to one another.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/weights_rail.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

Segment _segment({Map<String, double>? surface}) => Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-105.27, 40.02],
      end: const [-105.2, 40.05],
      weights: surface == null ? null : WeightProfile(name: 'custom', surface: surface),
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

WeightSlider _sliderFor(WidgetTester tester, String label) => tester.widget<WeightSlider>(
      find.byWidgetPredicate((w) => w is WeightSlider && w.label == label),
    );

void main() {
  testWidgets('all three surface classes get their own labelled slider', (tester) async {
    await _pump(tester, _segment());

    expect(find.text('Surface — paved'), findsOneWidget);
    expect(find.text('Surface — gravel'), findsOneWidget);
    expect(find.text('Surface — singletrack'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('with no authored preference, every surface slider opens on the '
      'indifferent midpoint (2.5)', (tester) async {
    await _pump(tester, _segment());

    for (final label in ['Surface — paved', 'Surface — gravel', 'Surface — singletrack']) {
      expect(_sliderFor(tester, label).value, 2.5);
    }
  });

  testWidgets('each class is set independently rather than only relative to the '
      'others', (tester) async {
    await _pump(
      tester,
      _segment(surface: const {'paved': 0.0, 'gravel': 5.0, 'singletrack': 2.5}),
    );

    expect(_sliderFor(tester, 'Surface — paved').value, 0.0);
    expect(_sliderFor(tester, 'Surface — gravel').value, 5.0);
    expect(_sliderFor(tester, 'Surface — singletrack').value, 2.5);
  });

  testWidgets('every surface slider spans the full 0.0-5.0 range', (tester) async {
    await _pump(tester, _segment());

    for (final label in ['Surface — paved', 'Surface — gravel', 'Surface — singletrack']) {
      final row = find.ancestor(of: find.text(label), matching: find.byType(Column));
      final slider =
          tester.widget<Slider>(find.descendant(of: row.first, matching: find.byType(Slider)));
      expect(slider.min, 0.0);
      expect(slider.max, 5.0);
    }
  });

  testWidgets('dragging the gravel slider to seek gravel writes only the gravel '
      "class, leaving paved and singletrack untouched", (tester) async {
    await _pump(tester, _segment());

    final row = find.ancestor(of: find.text('Surface — gravel'), matching: find.byType(Column));
    final slider =
        tester.widget<Slider>(find.descendant(of: row.first, matching: find.byType(Slider)));
    slider.onChanged!(5.0);
    await tester.pump();

    final container = ProviderScope.containerOf(tester.element(find.byType(WeightsRail)));
    final segment = container.read(currentTripProvider).days.single.segments.single;
    expect(segment.weights?.surface, {'gravel': 5.0});
  });

  testWidgets('setting singletrack to seek does not disturb an already-authored '
      'paved preference', (tester) async {
    await _pump(tester, _segment(surface: const {'paved': 4.0}));

    final row =
        find.ancestor(of: find.text('Surface — singletrack'), matching: find.byType(Column));
    final slider =
        tester.widget<Slider>(find.descendant(of: row.first, matching: find.byType(Slider)));
    slider.onChanged!(5.0);
    await tester.pump();

    final container = ProviderScope.containerOf(tester.element(find.byType(WeightsRail)));
    final segment = container.read(currentTripProvider).days.single.segments.single;
    expect(segment.weights?.surface, {'paved': 4.0, 'singletrack': 5.0});
  });
}
