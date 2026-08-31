// Issue #213 / Story D1 (FR31) with FR16 — `metrics_rail.dart` is D1's dashboard
// (the Route tab's right rail) and it showed distance + climb only, with no time
// in it at all. It now carries a MOVING TIME stat card and an EST. ARRIVAL card,
// driven by `TripDashboard.fromTrip` (the client mirror of
// `plotlines_core.trips.dashboard.build_dashboard`). ETA needs a start time the
// trip payload does not carry yet, so the arrival card reads "—" from the mirror.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/sidecar_manager.dart' show CapabilityStatus;
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/metrics_rail.dart';

Segment _leg(String id, String mode, double distanceM) => Segment(
      id: id,
      mode: mode,
      shape: 'point_to_point',
      metrics: RouteMetrics(distanceM: distanceM),
    );

Future<void> _pump(WidgetTester tester, List<Day> days) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: MetricsRail(
        trip: Trip(
          id: 'trip-1',
          title: 'Test trip',
          createdAt: '2026-08-25T00:00:00Z',
          updatedAt: '2026-08-25T00:00:00Z',
          days: days,
        ),
        selectedSegment: null,
        elevationCapability: const CapabilityStatus(ready: true),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('a routed trip shows a MOVING TIME card from the FR16 pace model', (tester) async {
    // 30 km cycling at the 15 km/h system default = 2 h exactly.
    await _pump(tester, [
      Day(id: 'd1', index: 1, segments: [_leg('s1', 'cycling', 30000)]),
    ]);

    expect(find.text('MOVING TIME'), findsOneWidget);
    expect(find.text('2h 0m'), findsOneWidget);
    expect(find.text('Pace: system default'), findsOneWidget);
    // no start time on the payload → arrival is the muted em dash
    expect(find.text('EST. ARRIVAL'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('a trip with nothing paced (transit only) shows no time section', (tester) async {
    await _pump(tester, [
      Day(id: 'd1', index: 1, segments: [_leg('s1', 'transit', 40000)]),
    ]);

    expect(find.text('MOVING TIME'), findsNothing);
    expect(find.text('EST. ARRIVAL'), findsNothing);
  });

  testWidgets('an empty trip shows no time section', (tester) async {
    await _pump(tester, [Day(id: 'd1', index: 1, segments: const [])]);
    expect(find.text('MOVING TIME'), findsNothing);
  });
}
