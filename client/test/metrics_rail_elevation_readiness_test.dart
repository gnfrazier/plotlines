// Story N2 (issue #2), FR121/FR91 — "elevation enrichment runs in the
// background... routing and elevation-dependent metrics are visibly
// disabled with a stated reason and an honest progress estimate until it
// completes... no control silently fails." `climb_m`/`elevation.ascent_m`
// are always real-looking numbers from the sidecar (defaulted to 0.0, never
// null — `route_metrics.dart`'s doc comment) even though production regions
// never carry node elevation until FR87/#148 ships (`graph/regions.py`'s
// `ensure_graph` bakes none in). Before this story `MetricsRail` showed
// "↑ 0 m" regardless, which reads as a real measurement of "no climb" —
// these tests pin the honest alternative: a muted placeholder plus the same
// `CapabilityWarmingNotice` M12a already built for the routing case.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

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

Segment _segmentWithClimbAndProfile() => Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-105.28, 40.02],
      end: const [-105.2, 40.05],
      metrics: RouteMetrics(distanceM: 12000, climbM: 340),
      elevation: Elevation(ascentM: 340, samples: const [100, 110, 130, 105]),
    );

Future<void> _pump(
  WidgetTester tester, {
  required Segment segment,
  required CapabilityStatus elevationCapability,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: MetricsRail(
        trip: _tripWith(segment),
        selectedSegment: segment,
        elevationCapability: elevationCapability,
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('elevation ready: total climb and the profile show the real numbers',
      (tester) async {
    await _pump(
      tester,
      segment: _segmentWithClimbAndProfile(),
      elevationCapability: const CapabilityStatus(ready: true),
    );

    expect(find.text('↑ 340 m'), findsOneWidget);
    expect(find.byType(ElevationProfile), findsOneWidget);
    expect(find.textContaining('Elevation'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'elevation still loading: climb reads as unknown, not a bogus 0, and states the estimate',
      (tester) async {
    await _pump(
      tester,
      segment: _segmentWithClimbAndProfile(),
      elevationCapability: const CapabilityStatus(
        ready: false,
        reason: 'terrain data loading',
        progress: 0.4,
        etaS: 125,
      ),
    );

    // Never the misleading real-looking value, and never a bare "0 m".
    expect(find.text('↑ 340 m'), findsNothing);
    expect(find.text('↑ 0 m'), findsNothing);
    expect(find.text('↑ —'), findsOneWidget);

    // Honest, specific reason + estimate — never a silent gap — for both
    // the stat card and the profile section below it.
    expect(find.text('Elevation loading — available in about 3 minutes'), findsOneWidget);
    expect(find.text('Elevation profile loading — available in about 3 minutes'), findsOneWidget);

    // The profile itself never renders half-loaded/fake data.
    expect(find.byType(ElevationProfile), findsNothing);
    expect(find.text('Select a segment to see its elevation profile'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'elevation not configured (never loading): states the fixed reason, not a spinner or 0 m',
      (tester) async {
    await _pump(
      tester,
      segment: _segmentWithClimbAndProfile(),
      elevationCapability: const CapabilityStatus(
        ready: false,
        reason: 'elevation_source_not_configured:tracked_in_148',
      ),
    );

    expect(find.text('↑ —'), findsOneWidget);
    expect(
      find.text('Elevation unavailable — elevation_source_not_configured:tracked_in_148'),
      findsOneWidget,
    );
    expect(
      find.text('Elevation profile unavailable — elevation_source_not_configured:tracked_in_148'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'elevation not ready with no segment selected still states the reason, not the selection hint',
      (tester) async {
    final segment = _segmentWithClimbAndProfile();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MetricsRail(
          trip: _tripWith(segment),
          selectedSegment: null,
          elevationCapability: const CapabilityStatus(ready: false, reason: 'terrain data loading'),
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('Select a segment to see its elevation profile'), findsNothing);
    expect(find.text('Elevation profile unavailable — terrain data loading'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('elevation ready but no segment selected: unaffected — keeps the selection hint',
      (tester) async {
    final segment = _segmentWithClimbAndProfile();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MetricsRail(
          trip: _tripWith(segment),
          selectedSegment: null,
          elevationCapability: const CapabilityStatus(ready: true),
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('Select a segment to see its elevation profile'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
