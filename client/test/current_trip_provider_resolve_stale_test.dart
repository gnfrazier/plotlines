// Story Q3 (issue #123), FR140 — "re-solve-all as one unconfirmed action":
// resolveAllStale re-solves every currently-stale segment in the trip and
// clears its staleness, the same as calling `regenerateSegment` on each in
// turn. `dropStaleSegment` is the list's "drop it instead" resolution,
// reusing `removeSegment` (Q2) so a dropped route's nodes still survive
// unattached rather than disappearing.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

/// Always resolves cleanly with a fresh (non-stale) solve, echoing back
/// whatever start/end/mode/shape it was asked to solve — enough for
/// `resolveAllStale` to verify each call actually reaches the segment it
/// was meant for.
class _FakeRoutingClient extends RoutingClient {
  _FakeRoutingClient() : super('http://fake');

  final calls = <String>[];

  @override
  Future<String> ensureRegion(List<double> bboxWsen, {String networkType = 'bike'}) async =>
      'region-1';

  @override
  Future<Segment> generateSegment({
    required String region,
    required Coord start,
    Coord? end,
    List<Coord> via = const [],
    String mode = 'cycling',
    String shape = 'loop',
    String theme = 'balanced',
    Map<String, double>? weights,
    double? targetM,
  }) async {
    calls.add('$mode:$shape');
    return Segment(
      id: 'ignored', // regenerateSegment rebuilds with the old segment's id.
      mode: mode,
      shape: shape,
      start: start,
      end: end,
      via: via,
      metrics: RouteMetrics(distanceM: 5000),
      solve: SolveProvenance(solvedAt: '2026-02-01T00:00:00Z', stale: false),
    );
  }
}

ProviderContainer _container(_FakeRoutingClient client) {
  return ProviderContainer(overrides: [
    routingClientProvider.overrideWithValue(client),
    tripBboxProvider.overrideWith((ref) => TripBboxNotifier()
      ..set(const TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.1, maxLon: -105.2))),
  ]);
}

void main() {
  Segment staleSegment(String id, {required Coord start}) => Segment(
        id: id,
        mode: 'cycling',
        shape: 'loop',
        start: start,
        solve: SolveProvenance(solvedAt: '2026-01-01T00:00:00Z', stale: true),
      );

  test('resolveAllStale re-solves every stale segment across every day and clears staleness', () async {
    final client = _FakeRoutingClient();
    final container = _container(client);
    addTearDown(container.dispose);

    final day1 = Day(id: 'd1', index: 1, segments: [
      staleSegment('s1', start: const [-105.27, 40.02]),
      Segment(id: 's2', mode: 'cycling', shape: 'loop', start: const [-105.28, 40.03]), // not stale
    ]);
    final day2 = Day(id: 'd2', index: 2, segments: [staleSegment('s3', start: const [-105.29, 40.04])]);
    container.read(currentTripProvider.notifier).open(Trip(
          id: 't1',
          title: 'Trip',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          days: [day1, day2],
        ));

    await container.read(currentTripProvider.notifier).resolveAllStale();

    final trip = container.read(currentTripProvider);
    expect(tripStaleItems(trip), isEmpty);
    expect(tripReadyToExport(trip), isTrue);
    // Only the two originally-stale segments were re-solved.
    expect(client.calls, hasLength(2));
    // Segment ids are preserved by regenerateSegment even though the fake
    // client returns a different one.
    expect(trip.days[0].segments.map((s) => s.id), ['s1', 's2']);
    expect(trip.days[1].segments.single.id, 's3');
  });

  test('resolveAllStale is a no-op on a trip with nothing stale', () async {
    final client = _FakeRoutingClient();
    final container = _container(client);
    addTearDown(container.dispose);

    container.read(currentTripProvider.notifier).open(Trip(
          id: 't1',
          title: 'Trip',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
        ));

    await container.read(currentTripProvider.notifier).resolveAllStale();

    expect(client.calls, isEmpty);
  });

  test('dropStaleSegment removes the segment but its nodes survive unattached on the day', () {
    final client = _FakeRoutingClient();
    final container = _container(client);
    addTearDown(container.dispose);

    final node = Node(id: 'n1', kind: NodeKind.poi, coord: const [0, 0]);
    final segment = Segment(
      id: 's1',
      mode: 'cycling',
      shape: 'loop',
      nodes: [node],
      solve: SolveProvenance(stale: true),
    );
    final day = Day(id: 'd1', index: 1, segments: [segment]);
    container.read(currentTripProvider.notifier).open(Trip(
          id: 't1',
          title: 'Trip',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          days: [day],
        ));

    container.read(currentTripProvider.notifier).dropStaleSegment('d1', 's1');

    final trip = container.read(currentTripProvider);
    expect(trip.days.single.segments, isEmpty);
    expect(trip.days.single.nodes.map((n) => n.id), ['n1']);
    expect(tripStaleItems(trip), isEmpty);
  });
}
