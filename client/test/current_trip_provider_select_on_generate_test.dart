// Issue #323 — nothing but an explicit tap on a segment card ever wrote
// `selectedSegmentProvider`, so a freshly generated (or re-solved) route
// drew its line on the map while the segment card, the planning rail and
// the weights rail all stayed unbound — the Author's read was that Generate
// had done nothing. `generateSegment`/`regenerateSegment` now select the
// segment the solve produced. These assertions fail against the pre-#323
// code, where the provider stayed at whatever an earlier tap had left it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

/// Stands in for a real `/segments/generate` round trip — same idiom as
/// `current_trip_provider_band_violations_test.dart`'s fake. Returns a
/// fixed-id `Segment` so the test can name the id it expects selected.
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
    String? discipline,
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
        geometry: LineString(
          coordinates: [start, if (end != null) end, start],
          source: 'solved',
        ),
        metrics: RouteMetrics(distanceM: targetM ?? 12000),
      );
}

ProviderContainer _container() {
  final container = ProviderContainer(overrides: [
    routingClientProvider.overrideWithValue(_FakeRoutingClient()),
    tripBboxProvider.overrideWith((ref) => TripBboxNotifier()
      ..set(const TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.1, maxLon: -105.2))),
  ]);
  addTearDown(container.dispose);
  return container;
}

Trip _tripWithSegment() {
  final segment = Segment(
    id: 'seg-1',
    mode: 'cycling',
    shape: 'point_to_point',
    start: const [-105.27, 40.02],
    end: const [-105.2, 40.05],
  );
  return Trip(
    id: 'trip-1',
    title: 'T',
    createdAt: '2026-09-08T00:00:00Z',
    updatedAt: '2026-09-08T00:00:00Z',
    days: [Day(id: 'day-1', index: 1, segments: [segment])],
  );
}

void main() {
  test('generateSegment selects the segment it just produced', () async {
    final container = _container();
    expect(container.read(selectedSegmentProvider), isNull);

    await container.read(currentTripProvider.notifier).generateSegment(
          start: const [-105.27, 40.02],
          shape: 'loop',
          targetM: 20000.0,
        );

    final day = container.read(currentTripProvider).days.single;
    expect(container.read(selectedSegmentProvider), (day.id, 'solved-1'));
  });

  test('generateSegment onto an existing day selects the new segment on that day', () async {
    final container = _container();
    container.read(currentTripProvider.notifier).open(_tripWithSegment());
    // A prior tap left Day 1's original segment selected.
    container.read(selectedSegmentProvider.notifier).state = ('day-1', 'seg-1');

    await container.read(currentTripProvider.notifier).generateSegment(
          dayId: 'day-1',
          start: const [-105.27, 40.02],
          end: const [-105.2, 40.05],
          shape: 'point_to_point',
        );

    expect(container.read(selectedSegmentProvider), ('day-1', 'solved-1'));
  });

  test('regenerateSegment selects the re-solved segment', () async {
    final container = _container();
    container.read(currentTripProvider.notifier).open(_tripWithSegment());
    // Selection sitting on some other, unrelated target before the re-solve.
    container.read(selectedSegmentProvider.notifier).state = ('day-9', 'seg-9');

    await container.read(currentTripProvider.notifier).regenerateSegment('day-1', 'seg-1');

    expect(container.read(selectedSegmentProvider), ('day-1', 'seg-1'));
  });
}
