// Story A9 (issue #26) — "a genuine loop rather than an out-and-back, with
// any road ridden twice reported." `RoutingClient` now parses the sidecar's
// overlap split onto `Segment.metrics`
// (`routing_client_via_anchor_metrics_test.dart`); this pins the other half
// — that `MetricsRail` actually surfaces it to the Author for a via-anchor
// segment, and stays quiet for a segment with no via-anchors or that cannot
// carry them (point_to_point).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/sidecar_manager.dart' show CapabilityStatus;
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/metrics_rail.dart';

Trip _tripWith(Segment segment) {
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
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: MetricsRail(
        trip: _tripWith(segment),
        selectedSegment: segment,
        elevationCapability: const CapabilityStatus(ready: true),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('a loop with via-anchors reports whether they were reached and the road ridden twice',
      (tester) async {
    final segment = Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'loop',
      start: const [-105.28, 40.02],
      via: const [
        [-105.275, 40.02],
      ],
      metrics: RouteMetrics(distanceM: 12000, overlapFrac: 0.08, overlapNearFrac: 0.06, overlapFarFrac: 0.02),
      solve: SolveProvenance(closed: true, hitVia: true),
    );

    await _pump(tester, segment);

    expect(find.text('VIA-ANCHOR ROUTE'), findsOneWidget);
    expect(find.text('Via-anchor reached: yes'), findsOneWidget);
    expect(find.text('Returns to start: yes'), findsOneWidget);
    // Reports `overlapFarFrac` (2%) — the number `loops.py` itself calls
    // out as "the number that must stay low" for a *genuine* loop —
    // alongside the separately-licensed near-via retrace (6%), not the
    // combined `overlapFrac` (8%) that cannot tell the two apart.
    expect(find.text('Road ridden twice: 2%'), findsOneWidget);
    expect(find.text('— near a via-anchor: 6%'), findsOneWidget);
  });

  testWidgets('a via-anchor loop that failed to close or reach a via says so, not "yes"',
      (tester) async {
    final segment = Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'loop',
      start: const [-105.28, 40.02],
      via: const [
        [-105.275, 40.02],
        [-105.29, 40.01],
      ],
      metrics: RouteMetrics(distanceM: 12000),
      solve: SolveProvenance(closed: false, hitVia: false),
    );

    await _pump(tester, segment);

    expect(find.text('Via-anchors reached: no'), findsOneWidget);
    expect(find.text('Returns to start: no'), findsOneWidget);
  });

  testWidgets('a segment with no via-anchors shows no via-anchor summary at all', (tester) async {
    final segment = Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'loop',
      start: const [-105.28, 40.02],
      metrics: RouteMetrics(distanceM: 12000),
      solve: SolveProvenance(closed: true),
    );

    await _pump(tester, segment);

    expect(find.text('VIA-ANCHOR ROUTE'), findsNothing);
  });

  testWidgets('a point_to_point segment never shows a via-anchor summary, even with via points',
      (tester) async {
    final segment = Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-105.28, 40.02],
      end: const [-105.2, 40.05],
      via: const [
        [-105.275, 40.02],
      ],
      metrics: RouteMetrics(distanceM: 12000),
    );

    await _pump(tester, segment);

    expect(find.text('VIA-ANCHOR ROUTE'), findsNothing);
  });
}
