// Story A8 (issue #25) — the New Route flow's first solve (`generateSegment`)
// is where an Author most often sets a target distance for the first time,
// before ever touching `WeightsRail`'s own target-distance field
// (`current_trip_provider_target_distance_test.dart` covers that later-edit
// path). "Banded by default in explore mode" has to hold here too — the
// server's `/segments/generate` response only ever carries a bare `target_m`
// (`routing_client.dart`'s `_segmentFromSolveResponse`), never a band.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

/// Stands in for a real `/segments/generate` round trip — returns a fixed
/// `Segment` shaped the way `_segmentFromSolveResponse` would build one:
/// an unbanded `TargetDistance` when `targetM` was supplied, none otherwise.
class _FakeRoutingClient extends RoutingClient {
  _FakeRoutingClient() : super('http://fake');

  @override
  Future<String> ensureRegion(List<double> bboxWsen,
          {String networkType = 'bike', bool retry = false}) async =>
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
  }) async =>
      Segment(
        id: 'solved-1',
        mode: mode,
        shape: shape,
        start: start,
        end: end,
        via: via,
        targetDistance: targetM == null ? null : TargetDistance(valueM: targetM),
        metrics: RouteMetrics(distanceM: targetM ?? 12000),
      );
}

ProviderContainer _container() {
  final container = ProviderContainer(overrides: [
    routingClientProvider.overrideWithValue(_FakeRoutingClient()),
    tripBboxProvider.overrideWith((ref) => TripBboxNotifier()
      ..set(const TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.1, maxLon: -105.2))),
  ]);
  return container;
}

void main() {
  test('a fresh loop with a target distance is banded by default', () async {
    final container = _container();
    addTearDown(container.dispose);

    await container.read(currentTripProvider.notifier).generateSegment(
          start: const [-105.27, 40.02],
          shape: 'loop',
          targetM: 20000.0,
        );

    final segment = container.read(currentTripProvider).days.single.segments.single;
    expect(segment.targetDistance!.valueM, 20000.0);
    expect(segment.targetDistance!.minM, 18000.0);
    expect(segment.targetDistance!.maxM, 22000.0);
  });

  test('a fresh out_and_back with a target distance is banded too', () async {
    final container = _container();
    addTearDown(container.dispose);

    await container.read(currentTripProvider.notifier).generateSegment(
          start: const [-105.27, 40.02],
          shape: 'out_and_back',
          targetM: 10000.0,
        );

    final segment = container.read(currentTripProvider).days.single.segments.single;
    expect(segment.targetDistance!.minM, 9000.0);
    expect(segment.targetDistance!.maxM, 11000.0);
  });

  test('an out_and_back with a picked turnaround, no target, gets no band', () async {
    final container = _container();
    addTearDown(container.dispose);

    await container.read(currentTripProvider.notifier).generateSegment(
          start: const [-105.27, 40.02],
          end: const [-105.20, 40.05],
          shape: 'out_and_back',
          targetM: null,
        );

    final segment = container.read(currentTripProvider).days.single.segments.single;
    expect(segment.targetDistance, isNull);
  });

  test('a fresh point_to_point is never banded', () async {
    final container = _container();
    addTearDown(container.dispose);

    await container.read(currentTripProvider.notifier).generateSegment(
          start: const [-105.27, 40.02],
          end: const [-105.20, 40.05],
          shape: 'point_to_point',
          targetM: 20000.0, // advisory, if ever sent — not this story's concern
        );

    final segment = container.read(currentTripProvider).days.single.segments.single;
    expect(segment.targetDistance!.valueM, 20000.0);
    expect(segment.targetDistance!.minM, isNull);
    expect(segment.targetDistance!.maxM, isNull);
  });
}
