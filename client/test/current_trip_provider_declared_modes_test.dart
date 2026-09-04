// FR144/N0 — "declaring is not a constraint: an Author may create a passage
// in an undeclared mode, and doing so adds that mode to the trip — no
// warning, no block, no confirmation." `_replaceDay` is the one place every
// day/segment mutation in `CurrentTripNotifier` funnels through (its own
// class doc comment), so that's what these tests exercise via
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
    String shape = 'loop',
    String theme = 'balanced',
    Map<String, double>? weights,
    double? targetM,
  }) async =>
      Segment(id: 'solved-1', mode: mode, shape: shape, start: start, end: end, via: via);
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
  group('setDeclaredModes', () {
    test('sets the declared set', () {
      final container = _container();
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).setDeclaredModes({'paddling'});

      expect(container.read(currentTripProvider).declaredModes, {'paddling'});
    });

    test('AC: "at least one is required" — an empty set is ignored, not accepted', () {
      final container = _container();
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).setDeclaredModes({'cycling'});

      container.read(currentTripProvider.notifier).setDeclaredModes(const {});

      expect(container.read(currentTripProvider).declaredModes, {'cycling'});
    });
  });

  group('toggleDeclaredMode', () {
    test('adds an absent mode and removes a present one', () {
      final container = _container();
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).setDeclaredModes({'cycling'});

      container.read(currentTripProvider.notifier).toggleDeclaredMode('hiking');
      expect(container.read(currentTripProvider).declaredModes, {'cycling', 'hiking'});

      container.read(currentTripProvider.notifier).toggleDeclaredMode('hiking');
      expect(container.read(currentTripProvider).declaredModes, {'cycling'});
    });

    test('never drops the last remaining declared mode', () {
      final container = _container();
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).setDeclaredModes({'cycling'});

      container.read(currentTripProvider.notifier).toggleDeclaredMode('cycling');

      expect(container.read(currentTripProvider).declaredModes, {'cycling'});
    });
  });

  group('generateSegment folding an undeclared mode into the trip', () {
    test('a passage in an undeclared mode succeeds, unblocked, and adds the mode', () async {
      final container = _container();
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).setDeclaredModes({'cycling'});

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
      expect(trip.declaredModes, {'cycling', 'hiking'});
    });

    test('a passage in an already-declared mode leaves the declared set unchanged', () async {
      final container = _container();
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).setDeclaredModes({'cycling', 'paddling'});

      await container.read(currentTripProvider.notifier).generateSegment(
            start: const [-105.27, 40.02],
            end: const [-105.20, 40.05],
            mode: 'cycling',
            shape: 'point_to_point',
          );

      expect(container.read(currentTripProvider).declaredModes, {'cycling', 'paddling'});
    });

    test('declared modes only grow this way — a second undeclared-mode passage adds again, '
        'and nothing already present is ever dropped', () async {
      final container = _container();
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).setDeclaredModes({'cycling'});

      final notifier = container.read(currentTripProvider.notifier);
      await notifier.generateSegment(
        start: const [-105.27, 40.02], end: const [-105.20, 40.05],
        mode: 'hiking', shape: 'point_to_point',
      );
      await notifier.generateSegment(
        start: const [-105.20, 40.05], end: const [-105.15, 40.06],
        mode: 'paddling', shape: 'point_to_point',
      );

      expect(container.read(currentTripProvider).declaredModes, {'cycling', 'hiking', 'paddling'});
    });
  });
}
