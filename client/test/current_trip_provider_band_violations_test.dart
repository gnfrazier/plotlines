// FR9 (Story A6) — `regenerateSegment` populates `Segment.violations` from
// the metrics the just-completed solve returned, synchronous with that
// solve (the half of A6's AC that isn't the async diagnose round trip).
// Explore mode only: compose's own band is judged through A0a instead
// (`current_trip_provider_compose_deviation_test.dart`), never this surface
// (ARCH D53).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

/// Stands in for a real `/segments/generate` round trip, same idiom as
/// `weights_rail_add_band_test.dart`'s fake — `RoutingClient` talks HTTP
/// directly, so subclassing and overriding is the one seam available.
class _FakeRoutingClient extends RoutingClient {
  _FakeRoutingClient({required this.metrics}) : super('http://fake');

  final RouteMetrics metrics;

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
    String shape = 'point_to_point',
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
        geometry: LineString(coordinates: [start, if (end != null) end], source: 'solved'),
        metrics: metrics,
      );
}

Segment _segment({required List<Band> bands}) => Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-105.27, 40.02],
      end: const [-105.2, 40.05],
      bands: bands,
    );

ProviderContainer _container(Segment segment, RouteMetrics metrics) {
  final day = Day(id: 'day-1', index: 1, segments: [segment]);
  final trip = Trip(
    id: 'trip-1',
    title: 'Test trip',
    createdAt: '2026-08-25T00:00:00Z',
    updatedAt: '2026-08-25T00:00:00Z',
    days: [day],
  );
  final container = ProviderContainer(overrides: [
    routingClientProvider.overrideWithValue(_FakeRoutingClient(metrics: metrics)),
    tripBboxProvider.overrideWith((ref) => TripBboxNotifier()
      ..set(const TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.1, maxLon: -105.2))),
  ]);
  container.read(currentTripProvider.notifier).open(trip);
  return container;
}

Segment _resegment(ProviderContainer container) =>
    container.read(currentTripProvider).days.single.segments.single;

void main() {
  test('explore mode: a band the solve misses shows up as a violation', () async {
    final bands = [Band(attribute: 'climb_m', min: 280)];
    final container = _container(_segment(bands: bands), RouteMetrics(climbM: 210));
    addTearDown(container.dispose);

    await container
        .read(currentTripProvider.notifier)
        .regenerateSegment('day-1', 'seg-1', mode: PlanningMode.explore);

    final violations = _resegment(container).violations;
    expect(violations, hasLength(1));
    expect(violations.single.attribute, 'climb_m');
    expect(violations.single.realised, 210);
  });

  test('explore mode: a band the solve satisfies reports no violation', () async {
    final bands = [Band(attribute: 'climb_m', min: 280)];
    final container = _container(_segment(bands: bands), RouteMetrics(climbM: 320));
    addTearDown(container.dispose);

    await container
        .read(currentTripProvider.notifier)
        .regenerateSegment('day-1', 'seg-1', mode: PlanningMode.explore);

    expect(_resegment(container).violations, isEmpty);
  });

  test('explore mode with no bands set: nothing to violate', () async {
    final container = _container(_segment(bands: const []), RouteMetrics(climbM: 10));
    addTearDown(container.dispose);

    await container
        .read(currentTripProvider.notifier)
        .regenerateSegment('day-1', 'seg-1', mode: PlanningMode.explore);

    expect(_resegment(container).violations, isEmpty);
  });

  test('compose mode never reports A6 violations — FR118/A0a is its own '
      'surface, kept out of M13 (ARCH D53)', () async {
    final bands = [Band(attribute: 'climb_m', min: 280)];
    final container = _container(_segment(bands: bands), RouteMetrics(climbM: 210));
    addTearDown(container.dispose);

    await container
        .read(currentTripProvider.notifier)
        .regenerateSegment('day-1', 'seg-1', mode: PlanningMode.compose);

    expect(_resegment(container).violations, isEmpty);
  });
}
