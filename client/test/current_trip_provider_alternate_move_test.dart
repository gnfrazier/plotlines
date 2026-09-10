// Issue #344 — FR20 [AMENDED v2.0] / C4 + FR140 / Q3, Flow 11 §03–§04 and §06.
//
// The state half of moving an alternate: `updateAlternateGeometry` (the save at
// the end of `Move on the map`) and `regenerateAlternate` (`Re-solve this
// branch`), plus what `resolveAllStale` and the drop resolution do once an
// alternate can be a stale item on its own.
//
// The two clauses this file exists to pin, both from Flow 11 §06's third
// outcome — *neither refused nor asked, just stale*:
//
//   * nothing authored is lost, so nothing is confirmed; and
//   * nothing re-solves on its own (ARCH D52) — a re-solve is an explicit call.
library;

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

  /// Every solve asked for, as `(start, via, end, mode, shape)`, so a test can
  /// prove the alternate was solved along its own marks rather than the
  /// passage's endpoints.
  final calls = <({Coord start, List<Coord> via, Coord? end, String mode, String shape})>[];

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
  }) async {
    calls.add((start: start, via: via, end: end, mode: mode, shape: shape));
    return Segment(
      id: 'ignored',
      mode: mode,
      shape: shape,
      start: start,
      end: end,
      via: via,
      geometry: LineString(coordinates: const [
        [-105.3, 40.0],
        [-105.2, 40.04],
        [-105.1, 40.0],
      ]),
      metrics: RouteMetrics(distanceM: 24000, climbM: 300),
      elevation: Elevation(ascentM: 300, descentM: 300),
      solve: SolveProvenance(solvedAt: '2026-02-01T00:00:00Z', stale: false),
    );
  }
}

ProviderContainer _container(_FakeRoutingClient client) => ProviderContainer(overrides: [
      routingClientProvider.overrideWithValue(client),
      tripBboxProvider.overrideWith((ref) => TripBboxNotifier()
        ..set(const TripBbox(minLat: 39.9, minLon: -105.5, maxLat: 40.2, maxLon: -104.9))),
    ]);

const _route = <Coord>[
  [-105.4, 40.0],
  [-105.0, 40.0],
];

LineString _drawn(List<Coord> coords) =>
    LineString(coordinates: coords, source: 'authored');

/// A fully authored branch: everything deleting-and-redrawing would have
/// destroyed, which is the reason this method exists at all.
Alternate _branch({SolveProvenance? solve}) => Alternate(
      id: 'a1',
      kind: 'extension',
      intent: 'branch',
      label: 'Past the Sugarloaf mine',
      geometry: _drawn(const [
        [-105.3, 40.0],
        [-105.2, 40.05],
        [-105.1, 40.0],
      ]),
      divergesAtM: 8500.0,
      rejoinsAtM: 25500.0,
      solve: solve,
      note: 'Three miles of old tramway grade.',
      anchorIds: const ['anc-mine'],
      narration: Narration(triggerDistanceM: 150.0, text: 'The portal.'),
      reveal: 'on_arrival',
    );

Segment _passage({required List<Alternate> alternates, SolveProvenance? solve}) => Segment(
      id: 's1',
      mode: 'cycling',
      discipline: 'gravel',
      shape: 'point_to_point',
      start: _route.first,
      end: _route.last,
      geometry: LineString(coordinates: _route),
      metrics: RouteMetrics(distanceM: 34000),
      alternates: alternates,
      solve: solve,
    );

Trip _trip(Segment segment) => Trip(
      id: 't1',
      title: 'Trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: [Day(id: 'd1', index: 1, segments: [segment])],
    );

Alternate _read(ProviderContainer c) =>
    c.read(currentTripProvider).days.single.segments.single.alternates.single;

void main() {
  group('updateAlternateGeometry — the save at the end of Move on the map', () {
    test('moves the path and the marks and keeps every authored field', () async {
      final client = _FakeRoutingClient();
      final container = _container(client);
      addTearDown(container.dispose);
      container
          .read(currentTripProvider.notifier)
          .open(_trip(_passage(alternates: [_branch()])));

      container.read(currentTripProvider.notifier).updateAlternateGeometry(
            'd1',
            's1',
            'a1',
            geometry: _drawn(const [
              [-105.32, 40.0],
              [-105.2, 40.05],
              [-105.1, 40.0],
            ]),
            divergesAtM: 6800.0,
            rejoinsAtM: 25500.0,
          );

      final moved = _read(container);
      expect(moved.geometry.coordinates.first, const [-105.32, 40.0]);
      expect(moved.divergesAtM, 6800.0);
      // The whole point: none of this was lost, which is what deleting and
      // redrawing the alternate would have cost.
      expect(moved.label, 'Past the Sugarloaf mine');
      expect(moved.note, 'Three miles of old tramway grade.');
      expect(moved.anchorIds, ['anc-mine']);
      expect(moved.narration!.text, 'The portal.');
      expect(moved.reveal, 'on_arrival');
      expect(moved.intent, 'branch');
      expect(moved.kind, 'extension');
      // And nothing re-solved on its own (ARCH D52).
      expect(client.calls, isEmpty);
    });

    test('marks a solved alternate stale, and leaves its passage alone', () {
      final container = _container(_FakeRoutingClient());
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).open(_trip(_passage(
            alternates: [_branch(solve: SolveProvenance(solvedAt: 'x', stale: false))],
            solve: SolveProvenance(solvedAt: 'y', stale: false),
          )));

      container.read(currentTripProvider.notifier).updateAlternateGeometry(
            'd1', 's1', 'a1',
            geometry: _drawn(const [
              [-105.32, 40.0],
              [-105.1, 40.0],
            ]),
            divergesAtM: 6800.0,
            rejoinsAtM: 25500.0,
          );

      final trip = container.read(currentTripProvider);
      expect(_read(container).isStale, isTrue);
      // The passage was not touched, so it is not stale — a segment-level flag
      // would have dragged the day's own route into the stale list behind an
      // edit that never asked anything of it.
      expect(trip.days.single.segments.single.solve!.stale, isFalse);
      // Its solved_at survives: the numbers on screen are the ones that solve
      // produced, and the surface says which solve they came from.
      expect(_read(container).solve!.solvedAt, 'x');
      expect(tripStaleItems(trip).single.alternateId, 'a1');
    });

    test('an alternate that was never solved is not made stale by a move', () {
      final container = _container(_FakeRoutingClient());
      addTearDown(container.dispose);
      container
          .read(currentTripProvider.notifier)
          .open(_trip(_passage(alternates: [_branch()])));

      container.read(currentTripProvider.notifier).updateAlternateGeometry(
            'd1', 's1', 'a1',
            geometry: _drawn(const [
              [-105.32, 40.0],
              [-105.1, 40.0],
            ]),
            divergesAtM: 6800.0,
            rejoinsAtM: 25500.0,
          );

      expect(_read(container).solve, isNull);
      expect(tripReadyToExport(container.read(currentTripProvider)), isTrue);
    });

    test('a move that changes nothing is a no-op — looking is not editing', () {
      final container = _container(_FakeRoutingClient());
      addTearDown(container.dispose);
      final before = _branch(solve: SolveProvenance(stale: false));
      container.read(currentTripProvider.notifier).open(_trip(_passage(alternates: [before])));

      container.read(currentTripProvider.notifier).updateAlternateGeometry(
            'd1', 's1', 'a1',
            geometry: before.geometry,
            divergesAtM: before.divergesAtM,
            rejoinsAtM: before.rejoinsAtM,
          );

      expect(_read(container).isStale, isFalse);
    });
  });

  group('regenerateAlternate — Re-solve this branch', () {
    test('solves between the marks, through the points the Author shaped it with', () async {
      final client = _FakeRoutingClient();
      final container = _container(client);
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).open(_trip(_passage(
            alternates: [_branch(solve: SolveProvenance(solvedAt: 'x', stale: true))],
          )));

      await container
          .read(currentTripProvider.notifier)
          .regenerateAlternate('d1', 's1', 'a1');

      final call = client.calls.single;
      expect(call.start, const [-105.3, 40.0]);
      expect(call.end, const [-105.1, 40.0]);
      // The shaping points are what makes this path *this* path rather than
      // the shortest way between the two marks.
      expect(call.via, const [
        [-105.2, 40.05]
      ]);
      // Two fixed ends and points to hit: never a loop, never a target
      // distance — an alternate's length is an outcome of where the marks are.
      expect(call.shape, 'point_to_point');
      // On the parent passage's own mode, so a branch off a gravel day rides
      // like the day it leaves.
      expect(call.mode, 'cycling');
    });

    test('fills the derived half and clears staleness, and never overwrites the drawn line', () async {
      final client = _FakeRoutingClient();
      final container = _container(client);
      addTearDown(container.dispose);
      final drawnBefore = _branch().geometry.coordinates;
      container.read(currentTripProvider.notifier).open(_trip(_passage(
            alternates: [_branch(solve: SolveProvenance(solvedAt: 'x', stale: true))],
          )));

      await container
          .read(currentTripProvider.notifier)
          .regenerateAlternate('d1', 's1', 'a1');

      final solved = _read(container);
      expect(solved.metrics!.distanceM, 24000);
      expect(solved.elevation!.ascentM, 300);
      expect(solved.isStale, isFalse);
      expect(solved.solve!.solvedAt, '2026-02-01T00:00:00Z');
      // #324's rule holds: an alternate's geometry is the line the Author
      // drew. Overwriting it would also make the *next* re-solve send every
      // vertex of the solved line as a via-point, pinning the route to itself.
      expect(solved.geometry.coordinates, drawnBefore);
      expect(solved.geometry.source, 'authored');
      // Authored content survives a solve, exactly as it survives a move.
      expect(solved.note, 'Three miles of old tramway grade.');
      expect(solved.anchorIds, ['anc-mine']);
      expect(solved.reveal, 'on_arrival');
    });

    test('an alternate never solved before comes back solved', () async {
      final client = _FakeRoutingClient();
      final container = _container(client);
      addTearDown(container.dispose);
      container
          .read(currentTripProvider.notifier)
          .open(_trip(_passage(alternates: [_branch()])));

      expect(_read(container).isSolved, isFalse);
      await container
          .read(currentTripProvider.notifier)
          .regenerateAlternate('d1', 's1', 'a1');

      expect(_read(container).isSolved, isTrue);
      expect(_read(container).isStale, isFalse);
    });
  });

  group('the stale list resolves an alternate on its own terms', () {
    test('resolveAllStale re-solves a stale branch without touching a fresh passage', () async {
      final client = _FakeRoutingClient();
      final container = _container(client);
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).open(_trip(_passage(
            alternates: [_branch(solve: SolveProvenance(stale: true))],
            solve: SolveProvenance(stale: false),
          )));

      await container.read(currentTripProvider.notifier).resolveAllStale();

      // One solve, and it was the branch's: re-solving the passage would have
      // redone work nothing invalidated and still left the branch stale.
      expect(client.calls, hasLength(1));
      expect(client.calls.single.start, const [-105.3, 40.0]);
      expect(tripReadyToExport(container.read(currentTripProvider)), isTrue);
    });

    test('resolveAllStale re-solves the passage before the branches on it', () async {
      final client = _FakeRoutingClient();
      final container = _container(client);
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).open(_trip(_passage(
            alternates: [_branch(solve: SolveProvenance(stale: true))],
            solve: SolveProvenance(stale: true),
          )));

      await container.read(currentTripProvider.notifier).resolveAllStale();

      expect(client.calls, hasLength(2));
      // The passage first — its own endpoints — then the branch's marks.
      expect(client.calls.first.start, _route.first);
      expect(client.calls.last.start, const [-105.3, 40.0]);
      expect(tripReadyToExport(container.read(currentTripProvider)), isTrue);
    });

    test('dropStaleAlternate removes only the path, and the passage survives', () {
      final container = _container(_FakeRoutingClient());
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).open(_trip(_passage(
            alternates: [_branch(solve: SolveProvenance(stale: true))],
          )));

      container
          .read(currentTripProvider.notifier)
          .dropStaleAlternate('d1', 's1', 'a1');

      final trip = container.read(currentTripProvider);
      expect(trip.days.single.segments.single.alternates, isEmpty);
      expect(trip.days.single.segments.single.geometry, isNotNull);
      expect(tripReadyToExport(trip), isTrue);
    });
  });
}
