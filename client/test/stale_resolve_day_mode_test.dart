// Issue #654 — the stale list re-solved every item in Explore, whatever the
// day's planning mode: its row called `regenerateSegment` with no mode and
// *Re-solve all* called `resolveAllStale()`, both defaulting to explore. The
// mode changes the solve (compose drops `interest` and never sends
// `target_m`, ARCH §7.7), so a stale passage on a Compose day came back
// different from what the rail's own Regenerate gives. Every re-solve that
// isn't handed a mode now reads its own day's.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/widgets/stale_list_dialog.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

typedef _Call = ({Coord start, Map<String, double>? weights, double? targetM});

class _RecordingRoutingClient extends RoutingClient {
  _RecordingRoutingClient() : super('http://fake');
  final calls = <_Call>[];

  @override
  Future<String> ensureRegion(List<double> bboxWsen, {String networkType = 'bike', bool retry = false}) async =>
      'region-1';

  @override
  Future<Segment> generateSegment({
    required String region,
    required Coord start,
    Coord? end,
    List<Coord> via = const [],
    String mode = 'cycling',
    String? discipline,
    String shape = 'loop',
    String theme = 'balanced',
    Map<String, double>? weights,
    double? targetM,
  }) async {
    calls.add((start: start, weights: weights, targetM: targetM));
    return Segment(
      id: 'x',
      mode: mode,
      shape: shape,
      start: start,
      end: end,
      via: via,
      geometry: LineString(coordinates: [start, end ?? start]),
      metrics: RouteMetrics(distanceM: 5000),
      solve: SolveProvenance(solvedAt: '2026-10-08T00:00:00Z'),
    );
  }
}

const _composeStart = [-105.27, 40.02];
const _exploreStart = [-105.29, 40.04];

Segment _stale(String id, Coord start, {List<Alternate> alternates = const []}) => Segment(
      id: id,
      mode: 'cycling',
      shape: 'point_to_point',
      start: start,
      end: const [-105.20, 40.06],
      weights: WeightProfile(name: 'custom', interest: 4.0, traffic: 1.0),
      targetDistance: TargetDistance(valueM: 20000),
      alternates: alternates,
      solve: SolveProvenance(solvedAt: '2026-01-01T00:00:00Z', stale: true),
    );

ProviderContainer _container(_RecordingRoutingClient client, {List<Alternate> alternates = const []}) {
  final container = ProviderContainer(overrides: [
    routingClientProvider.overrideWithValue(client),
    tripBboxProvider.overrideWith((ref) => TripBboxNotifier()
      ..set(const TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.1, maxLon: -105.2))),
  ]);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(Trip(
        id: 't',
        title: 'Trip',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        days: [
          Day(id: 'd1', index: 1, segments: [_stale('s1', _composeStart, alternates: alternates)]),
          Day(id: 'd2', index: 2, segments: [_stale('s2', _exploreStart)]),
        ],
      ));
  container.read(dayPlanningModeProvider('d1').notifier).state = PlanningMode.compose;
  return container;
}

_Call _callFrom(_RecordingRoutingClient client, Coord start) =>
    client.calls.firstWhere((c) => c.start[0] == start[0] && c.start[1] == start[1]);

void main() {
  test('Re-solve all solves a Compose day as Compose and an Explore day as Explore', () async {
    final client = _RecordingRoutingClient();
    final container = _container(client);

    await container.read(currentTripProvider.notifier).resolveAllStale();

    final compose = _callFrom(client, _composeStart);
    expect(compose.targetM, isNull);
    expect(compose.weights!.containsKey('interest'), isFalse);
    final explore = _callFrom(client, _exploreStart);
    expect(explore.targetM, 20000);
    expect(explore.weights!.containsKey('interest'), isTrue);
  });

  test('a re-solve with no mode named reads its own day\'s', () async {
    final client = _RecordingRoutingClient();
    final container = _container(client);

    await container.read(currentTripProvider.notifier).regenerateSegment('d1', 's1');

    expect(client.calls.single.targetM, isNull);
    expect(client.calls.single.weights!.containsKey('interest'), isFalse);
  });

  test('a stale alternate on a Compose day re-solves without interest', () async {
    final client = _RecordingRoutingClient();
    final alternate = Alternate(
      id: 'a1',
      kind: 'extension',
      intent: 'branch',
      geometry: LineString(
          coordinates: const [[-105.26, 40.03], [-105.24, 40.05], [-105.22, 40.04]], source: 'authored'),
      solve: SolveProvenance(solvedAt: '2026-01-01T00:00:00Z', stale: true),
    );
    final container = _container(client, alternates: [alternate]);

    await container.read(currentTripProvider.notifier).regenerateAlternate('d1', 's1', 'a1');

    expect(client.calls.single.weights!.containsKey('interest'), isFalse);
  });

  testWidgets('the stale list\'s own row re-solves a Compose day\'s passage as Compose',
      (tester) async {
    final client = _RecordingRoutingClient();
    final container = _container(client);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showStaleList(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The Day 1 row is the first; its re-solve is the row's own action.
    await tester.tap(find.widgetWithText(TextButton, 'Re-solve').first);
    await tester.pumpAndSettle();

    final compose = _callFrom(client, _composeStart);
    expect(compose.targetM, isNull);
    expect(compose.weights!.containsKey('interest'), isFalse);
  });
}
