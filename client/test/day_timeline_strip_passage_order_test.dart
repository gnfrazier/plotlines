// Story B2 (issue #31), FR11 — the day timeline is where a day's passage
// order is set and where the adjacency gap warning lands.
//
// `day_timeline_strip_test.dart` covers O6's arc badge and C3's breach chip
// on the same widget; this file is scoped to B2's two additions so neither
// story's expectations sit inside the other's file.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/day_timeline_strip.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';

Segment _passage(String id, {String mode = 'cycling', Coord? start, Coord? end}) =>
    Segment(
      id: id,
      mode: mode,
      shape: 'point_to_point',
      start: start,
      end: end,
      metrics: RouteMetrics(distanceM: 12000),
    );

/// Pumps the strip against a real `currentTripProvider`, since B2's controls
/// write through it — a fixture trip passed in as a widget argument alone
/// would let a reorder "pass" without any state actually moving.
Future<ProviderContainer> _pump(WidgetTester tester, List<Segment> segments,
    {String? selectedId}) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(
        Trip(
          id: 't1',
          title: 'Test trip',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          days: [Day(id: 'day-1', index: 1, segments: segments)],
        ),
      );
  if (selectedId != null) {
    container.read(selectedSegmentProvider.notifier).state = ('day-1', selectedId);
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => DayTimelineStrip(
              trip: ref.watch(currentTripProvider),
              activeDayId: 'day-1',
              onSelectDay: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  return container;
}

List<String> _order(ProviderContainer c) =>
    c.read(currentTripProvider).days.single.segments.map((s) => s.id).toList();

void main() {
  testWidgets('adjacent endpoints more than 500 m apart show the gap, measured', (tester) async {
    await _pump(tester, [
      _passage('a', start: const [-105.30, 40.00], end: const [-105.30, 40.00]),
      _passage('b', start: const [-105.29, 40.00], end: const [-105.25, 40.00]),
    ]);

    // PlotBadge uppercases; the distance is stated, not merely flagged.
    expect(find.text('GAP 852 M'), findsOneWidget);
    expect(find.text('TRANSITION'), findsNothing);
  });

  testWidgets('a gap of a kilometre or more reads in km', (tester) async {
    await _pump(tester, [
      _passage('a', start: const [-105.30, 40.00], end: const [-105.30, 40.00]),
      _passage('b', start: const [-105.25, 40.00], end: const [-105.20, 40.00]),
    ]);
    expect(find.text('GAP 4.3 KM'), findsOneWidget);
  });

  testWidgets('passages that meet show an ordinary transition, no warning', (tester) async {
    await _pump(tester, [
      _passage('a', start: const [-105.30, 40.00], end: const [-105.29, 40.00]),
      _passage('b', start: const [-105.29, 40.00], end: const [-105.25, 40.00]),
    ]);

    expect(find.text('TRANSITION'), findsOneWidget);
    expect(find.textContaining('GAP'), findsNothing);
  });

  testWidgets('a mode change into paddling reads as a portage, not a generic transition',
      (tester) async {
    await _pump(tester, [
      _passage('a', start: const [-105.30, 40.00], end: const [-105.29, 40.00]),
      _passage('b', mode: 'paddling', start: const [-105.29, 40.00], end: const [-105.25, 40.00]),
    ]);
    expect(find.text('PORTAGE'), findsOneWidget);
  });

  testWidgets('the selected passage carries reorder arrows, and they move it', (tester) async {
    final container = await _pump(
      tester,
      [_passage('a'), _passage('b'), _passage('c')],
      selectedId: 'b',
    );

    expect(find.byTooltip('Move earlier in the day'), findsOneWidget);
    expect(find.byTooltip('Move later in the day'), findsOneWidget);

    await tester.tap(find.byTooltip('Move earlier in the day'));
    await tester.pump();
    expect(_order(container), ['b', 'a', 'c']);

    await tester.tap(find.byTooltip('Move later in the day'));
    await tester.pump();
    expect(_order(container), ['a', 'b', 'c']);
  });

  testWidgets('the arrow that would do nothing is not shown at all', (tester) async {
    await _pump(tester, [_passage('a'), _passage('b')], selectedId: 'a');
    expect(find.byTooltip('Move earlier in the day'), findsNothing);
    expect(find.byTooltip('Move later in the day'), findsOneWidget);
  });

  testWidgets('an unselected passage shows no reorder controls', (tester) async {
    await _pump(tester, [_passage('a'), _passage('b')]);
    expect(find.byTooltip('Move earlier in the day'), findsNothing);
    expect(find.byTooltip('Move later in the day'), findsNothing);
  });

  testWidgets('a lone passage has nothing to reorder against', (tester) async {
    await _pump(tester, [_passage('a')], selectedId: 'a');
    expect(find.byTooltip('Move later in the day'), findsNothing);
    expect(find.textContaining('GAP'), findsNothing);
  });

  testWidgets('reordering moves the warning with the passage', (tester) async {
    // a ends where c starts; b sits 850 m away. a-b-c has two gaps; a-c-b has one.
    final container = await _pump(
      tester,
      [
        _passage('a', start: const [-105.30, 40.00], end: const [-105.30, 40.00]),
        _passage('b', start: const [-105.29, 40.00], end: const [-105.29, 40.00]),
        _passage('c', start: const [-105.30, 40.00], end: const [-105.30, 40.00]),
      ],
      selectedId: 'c',
    );
    expect(find.textContaining('GAP'), findsNWidgets(2));

    await tester.tap(find.byTooltip('Move earlier in the day'));
    await tester.pump();

    expect(_order(container), ['a', 'c', 'b']);
    expect(find.textContaining('GAP'), findsOneWidget);
  });

  testWidgets('the passage chip names its mode with the shared label', (tester) async {
    await _pump(tester, [_passage('a', mode: 'mountain_biking')]);
    expect(find.text('MTB'), findsOneWidget);
  });
}
