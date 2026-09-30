// Issue #421 — FR128 / A11's dismount/gate/ford now ride in the derived cue
// sheet as `constraint` cues. The Export preview used to insert its own rows
// from `segment.surfacedConstraints` on top of the sheet; with the sheet
// carrying them, doing both would list each constraint twice.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/export_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

class _FakeRoutingClient extends RoutingClient {
  _FakeRoutingClient(this.sheet) : super('http://fake');
  final CueSheet sheet;

  @override
  Future<String> ensureRegion(List<double> bboxWsen,
          {String networkType = 'bike', bool retry = false}) async =>
      'region-1';

  @override
  Future<CueSheet> cuesFor(Segment segment, {required String region}) async => sheet;
}

Future<void> _pump(WidgetTester tester, CueSheet sheet) async {
  final day = Day(id: 'day-1', index: 1, segments: [
    Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-105.3, 40.0],
      metrics: RouteMetrics(distanceM: 12000),
      surfacedConstraints: [
        SurfacedConstraint(
            from: 10, to: 11, flags: const ['bicycle=dismount'], distanceAlongM: 3500),
      ],
    ),
  ]);
  final container = ProviderContainer(overrides: [
    tripBboxProvider.overrideWith((ref) => TripBboxNotifier()
      ..set(const TripBbox(minLat: 39.9, minLon: -105.4, maxLat: 40.1, maxLon: -105.1))),
    routingClientProvider.overrideWithValue(_FakeRoutingClient(sheet)),
  ]);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(Trip(
        id: 't1',
        title: 'Trip',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        days: [day],
      ));
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) => ExportTab(trip: ref.watch(currentTripProvider)),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Cue _cue(String id, double at, String kind, String instruction) =>
    Cue(id: id, sequence: 0, distanceAlongM: at, kind: kind, instruction: instruction);

void main() {
  testWidgets('a sheet that carries the constraint lists it once, tagged ON ROUTE', (tester) async {
    await _pump(
      tester,
      CueSheet(generatedAt: '2026-01-01T00:00:00Z', cues: [
        _cue('c1', 0, 'start', 'Start'),
        _cue('c2', 3500, 'constraint', 'bicycle=dismount'),
        _cue('c3', 12000, 'finish', 'Finish'),
      ]),
    );

    expect(find.textContaining('dismount'), findsOneWidget,
        reason: 'the sheet and the segment must not both list it');
    expect(find.text('bicycle dismount'), findsOneWidget);
    expect(find.text('ON ROUTE'), findsOneWidget);
  });

  testWidgets('a sheet derived before 1.16.0 still gets the row from the segment', (tester) async {
    await _pump(
      tester,
      CueSheet(generatedAt: '2026-01-01T00:00:00Z', cues: [
        _cue('c1', 0, 'start', 'Start'),
        _cue('c3', 12000, 'finish', 'Finish'),
      ]),
    );

    expect(find.text('bicycle dismount'), findsOneWidget);
    expect(find.text('ON ROUTE'), findsOneWidget);
  });
}
