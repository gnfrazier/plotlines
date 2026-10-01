// Issue #213 / Story D1 (FR31) with FR16 — `metrics_rail.dart` is D1's dashboard
// (the Route tab's right rail) and it showed distance + climb only, with no time
// in it at all. It now carries a MOVING TIME stat card and an ELAPSED card,
// driven by `TripDashboard.fromTrip` (the client mirror of
// `plotlines_core.trips.dashboard.build_dashboard`), or by the server's own
// dashboard when one was computed for this exact trip. Since #563 each day
// lists its elapsed time (station holds included) and, once the Author gave it
// a start time, its ETA on the day's own clock.
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

Future<void> _pump(WidgetTester tester, List<Day> days,
    {List<Anchor> anchors = const [], TripDashboard? dashboard,
    DisplayFormat displayFormat = const DisplayFormat()}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: MetricsRail(
        trip: Trip(
          id: 'trip-1',
          title: 'Test trip',
          createdAt: '2026-08-25T00:00:00Z',
          updatedAt: '2026-08-25T00:00:00Z',
          days: days,
          anchors: anchors,
        ),
        selectedSegment: null,
        elevationCapability: const CapabilityStatus(ready: true),
        dashboard: dashboard,
        displayFormat: displayFormat,
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
    // MOVING TIME, ELAPSED (no holds) and the Day 1 row.
    expect(find.text('2h 0m'), findsNWidgets(3));
    expect(find.text('Pace: system default'), findsOneWidget);
    expect(find.text('ELAPSED'), findsOneWidget);
    // no start time on the day → no arrival, said plainly
    expect(find.text('no start time'), findsOneWidget);
    expect(find.textContaining('→'), findsNothing);
  });

  testWidgets('#563 — a day with a start time shows its ETA on its own clock, holds included',
      (tester) async {
    // 30 km cycling = 2 h moving + a 1 h 30 m station = 3 h 30 m elapsed;
    // 07:00 New York (11:00Z in July) + 3 h 30 m = 10:30 EDT.
    await _pump(
      tester,
      [
        Day(id: 'd1', index: 1, startAt: '2026-07-04T11:00:00Z', startTimezone: 'America/New_York',
            segments: [_leg('s1', 'cycling', 30000)]),
      ],
      anchors: [
        Anchor(id: 'st', title: 'Crag', coord: const [-79.8, 36.1], roles: [
          Role(
            id: 'r-st',
            kind: RoleKind.station,
            reveal: RevealPolicy.alwaysVisible,
            activity: StationActivity(activityType: 'climbing', durationS: 5400),
            dayId: 'd1',
          ),
        ]),
      ],
      displayFormat: const DisplayFormat(clockPref: ClockPref.hour24),
    );

    expect(find.text('2h 0m'), findsOneWidget); // moving
    expect(find.text('3h 30m'), findsNWidgets(2)); // ELAPSED card + Day 1 row
    expect(find.text('→ 10:30 EDT'), findsOneWidget);
    expect(find.text('incl. 1h 30m at stations'), findsOneWidget);
  });

  testWidgets('#563 — the server dashboard, when given, is what the rail shows', (tester) async {
    final server = TripDashboard(
      tripId: 'trip-1',
      tripTitle: 'Test trip',
      paceSource: paceSystemDefault,
      days: [
        DashboardDayLine(
          dayId: 'd1',
          index: 1,
          kind: 'route',
          metrics: RollUp(total: RouteMetrics(distanceM: 30000, movingTimeS: 7200, elapsedTimeS: 9000)),
          holdS: 1800,
          eta: '2026-07-04T13:30:00Z',
        ),
      ],
      tripTotal: RollUp(total: RouteMetrics(distanceM: 30000, movingTimeS: 7200, elapsedTimeS: 9000)),
    );
    await _pump(
      tester,
      [
        Day(id: 'd1', index: 1, startAt: '2026-07-04T11:00:00Z', startTimezone: 'America/New_York',
            segments: [_leg('s1', 'cycling', 30000)]),
      ],
      dashboard: server,
      displayFormat: const DisplayFormat(clockPref: ClockPref.hour24),
    );
    expect(find.text('2h 30m'), findsNWidgets(2));
    expect(find.text('→ 09:30 EDT'), findsOneWidget);
    expect(find.text('incl. 30m at stations'), findsOneWidget);
  });

  testWidgets('a trip with nothing paced (transit only) shows no time section', (tester) async {
    await _pump(tester, [
      Day(id: 'd1', index: 1, segments: [_leg('s1', 'transit', 40000)]),
    ]);

    expect(find.text('MOVING TIME'), findsNothing);
    expect(find.text('ELAPSED'), findsNothing);
  });

  testWidgets('an empty trip shows no time section', (tester) async {
    await _pump(tester, [Day(id: 'd1', index: 1, segments: const [])]);
    expect(find.text('MOVING TIME'), findsNothing);
  });
}
