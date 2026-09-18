// FR144/N0, issue #319 — `Trip.modes` is the trip's one stored mode set:
// the entry prompt sets it, the Author adds to it from the planning page,
// and `_replaceDay` — the one place every day/segment mutation in
// `CurrentTripNotifier` funnels through (its own class doc comment) — keeps
// it a superset of what the segments use, silently and unconditionally, so
// a passage that arrives in a mode outside the set (a clone, an older
// payload, a caller bypassing the filtered picker) adds it rather than
// being blocked. The set never shrinks on its own: removing the last
// passage in a mode leaves the mode on the trip. Exercised via
// `generateSegment` — the same "fake routing client, real notifier" harness
// `current_trip_provider_generate_target_distance_test.dart` already uses.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

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
        id: 'solved-1', mode: mode, shape: shape, start: start, end: end, via: via,
        // A real solve, so `markSegmentStale` (which only marks a solved
        // segment) has something to mark — the stale-rule group needs it.
        solve: SolveProvenance(solvedAt: '2026-09-18T00:00:00Z', stale: false),
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
  group('setModes', () {
    test('sets the trip\'s mode set', () {
      final container = _container();
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).setModes({'paddling'});

      expect(container.read(currentTripProvider).modes, {'paddling'});
    });

    test('AC: "at least one is required" — an empty set is ignored, not accepted', () {
      final container = _container();
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).setModes({'cycling'});

      container.read(currentTripProvider.notifier).setModes(const {});

      expect(container.read(currentTripProvider).modes, {'cycling'});
    });
  });

  group('toggleMode', () {
    test('adds an absent mode and removes a present one', () {
      final container = _container();
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).setModes({'cycling'});

      container.read(currentTripProvider.notifier).toggleMode('hiking');
      expect(container.read(currentTripProvider).modes, {'cycling', 'hiking'});

      container.read(currentTripProvider.notifier).toggleMode('hiking');
      expect(container.read(currentTripProvider).modes, {'cycling'});
    });

    test('never drops the last remaining mode', () {
      final container = _container();
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).setModes({'cycling'});

      container.read(currentTripProvider.notifier).toggleMode('cycling');

      expect(container.read(currentTripProvider).modes, {'cycling'});
    });
  });

  group('the set is a superset of what the segments use', () {
    test('a passage in a mode outside the set succeeds, unblocked, and adds the mode', () async {
      final container = _container();
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).setModes({'cycling'});

      // No exception, no special-cased rejection — "no warning, no block,
      // no confirmation" — and it still produces the segment.
      await container.read(currentTripProvider.notifier).generateSegment(
            start: const [-105.27, 40.02],
            end: const [-105.20, 40.05],
            mode: 'hiking',
            shape: 'point_to_point',
          );

      final trip = container.read(currentTripProvider);
      expect(trip.days.single.segments.single.mode, 'hiking');
      expect(trip.modes, {'cycling', 'hiking'});
    });

    test('a passage in a mode already on the trip leaves the set unchanged', () async {
      final container = _container();
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).setModes({'cycling', 'paddling'});

      await container.read(currentTripProvider.notifier).generateSegment(
            start: const [-105.27, 40.02],
            end: const [-105.20, 40.05],
            mode: 'cycling',
            shape: 'point_to_point',
          );

      expect(container.read(currentTripProvider).modes, {'cycling', 'paddling'});
    });

    test('the set only grows this way — a second outside-mode passage adds again, '
        'and nothing already present is ever dropped', () async {
      final container = _container();
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).setModes({'cycling'});

      final notifier = container.read(currentTripProvider.notifier);
      await notifier.generateSegment(
        start: const [-105.27, 40.02], end: const [-105.20, 40.05],
        mode: 'hiking', shape: 'point_to_point',
      );
      await notifier.generateSegment(
        start: const [-105.20, 40.05], end: const [-105.15, 40.06],
        mode: 'paddling', shape: 'point_to_point',
      );

      expect(container.read(currentTripProvider).modes, {'cycling', 'hiking', 'paddling'});
    });

    test('#319 — removing the last passage in a mode does not remove the mode; '
        'only the Author does', () async {
      final container = _container();
      addTearDown(container.dispose);
      final notifier = container.read(currentTripProvider.notifier);
      notifier.setModes({'cycling'});
      await notifier.generateSegment(
        start: const [-105.27, 40.02], end: const [-105.20, 40.05],
        mode: 'hiking', shape: 'point_to_point',
      );
      final day = container.read(currentTripProvider).days.single;
      expect(container.read(currentTripProvider).modes, {'cycling', 'hiking'});

      notifier.removeSegment(day.id, day.segments.single.id);

      final trip = container.read(currentTripProvider);
      expect(trip.days.single.segments, isEmpty);
      expect(trip.modes, {'cycling', 'hiking'});

      // The Author's removal is the only path that shrinks it.
      notifier.toggleMode('hiking');
      expect(container.read(currentTripProvider).modes, {'cycling'});
    });

    test('#319 — dropping a mode the Author still uses on a passage folds it back in '
        'on the next day mutation rather than orphaning the passage', () async {
      final container = _container();
      addTearDown(container.dispose);
      final notifier = container.read(currentTripProvider.notifier);
      notifier.setModes({'cycling', 'hiking'});
      await notifier.generateSegment(
        start: const [-105.27, 40.02], end: const [-105.20, 40.05],
        mode: 'hiking', shape: 'point_to_point',
      );

      notifier.toggleMode('hiking');
      expect(container.read(currentTripProvider).modes, {'cycling'});

      final day = container.read(currentTripProvider).days.single;
      notifier.updateSegmentShape(day.id, day.segments.single.id, 'loop');
      expect(container.read(currentTripProvider).modes, {'cycling', 'hiking'});
    });
  });

  group('#319 stale rule — parent mode vs discipline', () {
    Future<(String, String)> solvedCyclingPassage(ProviderContainer container) async {
      final notifier = container.read(currentTripProvider.notifier);
      notifier.setModes({'cycling', 'hiking'});
      await notifier.generateSegment(
        start: const [-105.27, 40.02], end: const [-105.20, 40.05],
        mode: 'cycling', shape: 'point_to_point',
      );
      final day = container.read(currentTripProvider).days.single;
      final segment = day.segments.single;
      expect(segment.solve!.stale, isFalse);
      return (day.id, segment.id);
    }

    test('changing the parent mode marks the route stale', () async {
      final container = _container();
      addTearDown(container.dispose);
      final (dayId, segmentId) = await solvedCyclingPassage(container);

      container.read(currentTripProvider.notifier).updateSegmentMode(dayId, segmentId, 'hiking');

      final segment = container.read(currentTripProvider).days.single.segments.single;
      expect(segment.mode, 'hiking');
      expect(segment.solve!.stale, isTrue);
    });

    test('changing the discipline within the parent does not', () async {
      final container = _container();
      addTearDown(container.dispose);
      final (dayId, segmentId) = await solvedCyclingPassage(container);
      final notifier = container.read(currentTripProvider.notifier);

      notifier.updateSegmentDiscipline(dayId, segmentId, 'gravel');
      var segment = container.read(currentTripProvider).days.single.segments.single;
      expect(segment.discipline, 'gravel');
      expect(segment.solve!.stale, isFalse);

      notifier.updateSegmentDiscipline(dayId, segmentId, 'mountain');
      segment = container.read(currentTripProvider).days.single.segments.single;
      expect(segment.discipline, 'mountain');
      expect(segment.solve!.stale, isFalse);

      notifier.updateSegmentDiscipline(dayId, segmentId, null);
      segment = container.read(currentTripProvider).days.single.segments.single;
      expect(segment.discipline, isNull);
      expect(segment.solve!.stale, isFalse);
    });
  });
}
