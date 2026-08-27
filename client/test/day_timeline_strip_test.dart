// Story O6 (issue #13) — arc distinguished on the timeline, and C3's "a day
// may close at a resolution-stage anchor rather than only at a distance
// threshold": a day that falls short of its distance band is exempt from
// the breach chip when its last node carries `arc_stage == "resolution"`,
// mirroring `trips.compose._ends_at_resolution` server-side. Running over
// the band is still flagged regardless.
//
// `Day.limits` keys are travel modes (the schema's own words), so every
// fixture here keys its limit by 'hiking' — the mode `_segment()` below
// actually uses — rather than a blended, mode-agnostic key.
// `day_timeline_strip_per_mode_breach_test.dart` covers C3's per-mode
// behaviour (a day mixing two modes, each with its own band) that this
// file's single-mode fixtures don't exercise.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/day_timeline_strip.dart';

Future<void> _pump(WidgetTester tester, Trip trip) => tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: DayTimelineStrip(trip: trip, activeDayId: trip.days.single.id, onSelectDay: (_) {}),
          ),
        ),
      ),
    );

Trip _tripWithDay(Day day) => Trip(
      id: 't1',
      title: 'Test trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: [day],
    );

Segment _segment({required double distanceM, List<Node> nodes = const [], String? arcStage}) => Segment(
      id: 'seg-1',
      mode: 'hiking',
      shape: 'point_to_point',
      metrics: RouteMetrics(distanceM: distanceM),
      nodes: nodes,
      arcStage: arcStage,
    );

Node _node({required double distanceAlongM, String? arcStage}) => Node(
      id: 'n1',
      kind: NodeKind.poi,
      coord: const [0.0, 0.1],
      distanceAlongM: distanceAlongM,
      arcStage: arcStage,
    );

void main() {
  testWidgets('a segment with an arc stage shows it as a badge on the timeline', (tester) async {
    final day = Day(id: 'day-1', index: 1, segments: [_segment(distanceM: 10000, arcStage: 'crux')]);
    await _pump(tester, _tripWithDay(day));
    // PlotBadge uppercases its label.
    expect(find.text('CRUX'), findsOneWidget);
  });

  testWidgets('a segment with no arc stage shows no arc badge', (tester) async {
    final day = Day(id: 'day-1', index: 1, segments: [_segment(distanceM: 10000)]);
    await _pump(tester, _tripWithDay(day));
    expect(find.text('CRUX'), findsNothing);
    expect(find.text('RISING'), findsNothing);
  });

  testWidgets('a day short of the min distance band shows the breach chip', (tester) async {
    final day = Day(
      id: 'day-1',
      index: 1,
      segments: [_segment(distanceM: 10000)],
      limits: {'hiking': DayLimit(minM: 20000)},
    );
    await _pump(tester, _tripWithDay(day));
    expect(find.textContaining('below'), findsOneWidget);
  });

  testWidgets('a day short of the min band but closing at a resolution-stage anchor is exempt', (tester) async {
    final day = Day(
      id: 'day-1',
      index: 1,
      segments: [_segment(distanceM: 10000, nodes: [_node(distanceAlongM: 10000, arcStage: 'resolution')])],
      limits: {'hiking': DayLimit(minM: 20000)},
    );
    await _pump(tester, _tripWithDay(day));
    expect(find.textContaining('below'), findsNothing);
  });

  testWidgets('an over-length day is still flagged even when it closes at a resolution-stage anchor', (tester) async {
    final day = Day(
      id: 'day-1',
      index: 1,
      segments: [_segment(distanceM: 50000, nodes: [_node(distanceAlongM: 50000, arcStage: 'resolution')])],
      limits: {'hiking': DayLimit(minM: 20000, maxM: 40000)},
    );
    await _pump(tester, _tripWithDay(day));
    expect(find.textContaining('above'), findsOneWidget);
  });

  testWidgets('a resolution beat earlier on the route (not the terminal node) does not exempt the day', (tester) async {
    final day = Day(
      id: 'day-1',
      index: 1,
      segments: [
        _segment(distanceM: 10000, nodes: [
          _node(distanceAlongM: 1000, arcStage: 'resolution'),
          _node(distanceAlongM: 10000, arcStage: 'rising'),
        ]),
      ],
      limits: {'hiking': DayLimit(minM: 20000)},
    );
    await _pump(tester, _tripWithDay(day));
    expect(find.textContaining('below'), findsOneWidget);
  });
}
