// Issue #626 (option B) — a passage built from placed nodes.
//
// Blank canvas promised "Place nodes yourself" and created a day with no
// passage, where no node could be placed. Now the first node placed on such a
// day starts a point-to-point passage with no start or end of its own; its
// route-through nodes are the whole route, ordered from the rail, and Generate
// solves first point to last through the ones between. The stored passage
// keeps every point in `via`, so each node still reads as routed through
// (ARCH D71's coordinate link).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/state/authoring_undo_provider.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

class _RecordingRoutingClient extends RoutingClient {
  _RecordingRoutingClient() : super('http://fake');

  final asked = <({Coord start, Coord? end, List<Coord> via, String shape})>[];

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
    asked.add((start: start, end: end, via: via, shape: shape));
    return Segment(
      id: 'ignored',
      mode: mode,
      shape: shape,
      start: start,
      end: end,
      via: via,
      geometry: LineString(coordinates: [start, ...via, if (end != null) end]),
      metrics: RouteMetrics(distanceM: 5000),
      solve: SolveProvenance(solvedAt: '2026-02-01T00:00:00Z', stale: false),
    );
  }
}

const _a = <double>[-105.27, 40.02];
const _b = <double>[-105.25, 40.04];
const _c = <double>[-105.23, 40.06];

Node _node(String id, Coord at) => Node(id: id, kind: NodeKind.waypoint, coord: at);

void main() {
  late _RecordingRoutingClient client;
  late ProviderContainer container;
  late CurrentTripNotifier notifier;

  setUp(() {
    client = _RecordingRoutingClient();
    container = ProviderContainer(overrides: [
      routingClientProvider.overrideWithValue(client),
      tripBboxProvider.overrideWith((ref) => TripBboxNotifier()
        ..set(const TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.1, maxLon: -105.2))),
    ]);
    notifier = container.read(currentTripProvider.notifier);
    notifier.open(Trip(
      id: 't1',
      title: 'Trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      modes: const {'cycling'},
      days: [Day(id: 'd1', index: 1)],
    ));
  });
  tearDown(() => container.dispose());

  Segment passage() => container.read(currentTripProvider).days.single.segments.single;

  test('the first node creates the passage in one undoable edit, and selects it', () async {
    var emissions = 0;
    container.listen(currentTripProvider, (_, _) => emissions++);
    notifier.addNodeOnNewPassage('d1', 'p1', 'cycling', _node('n1', _a), routeThrough: true);
    expect(emissions, 1, reason: 'the passage and its first node land in one state change');

    final p = passage();
    expect((p.id, p.mode, p.shape, p.start, p.end), ('p1', 'cycling', 'point_to_point', null, null));
    expect(p.via, [_a]);
    expect(routesFromNodes(p), isTrue);
    expect(container.read(selectedSegmentProvider), ('d1', 'p1'));

    await Future<void>.delayed(Duration.zero);
    expect(container.read(authoringUndoProvider).history, ['Add a place']);
    container.read(authoringUndoProvider.notifier).undo();
    expect(container.read(currentTripProvider).days.single.segments, isEmpty,
        reason: 'one undo removes the node and the passage it started');
  });

  test('later nodes append in placement order; the solve runs first to last', () async {
    notifier.addNodeOnNewPassage('d1', 'p1', 'cycling', _node('n1', _a), routeThrough: true);
    notifier.saveSegmentNode('d1', 'p1', _node('n2', _b), routeThrough: true);
    notifier.saveSegmentNode('d1', 'p1', _node('n3', _c), routeThrough: true);
    expect(passage().via, [_a, _b, _c]);
    expect(nodeRouteSolveInputs(passage()), isNotNull);

    await notifier.regenerateSegment('d1', 'p1');

    final asked = client.asked.single;
    expect(asked.start, _a);
    expect(asked.end, _c);
    expect(asked.via, [_b]);
    expect(asked.shape, 'point_to_point');

    // The stored passage stays node-built: every node still routes through.
    final p = passage();
    expect(p.geometry, isNotNull);
    expect((p.start, p.end), (null, null));
    expect(p.via, [_a, _b, _c]);
    for (final n in p.nodes) {
      expect(nodeRoutesThrough(p, n), isTrue, reason: n.id);
    }
  });

  test('one route-through point is not enough to solve between', () {
    notifier.addNodeOnNewPassage('d1', 'p1', 'cycling', _node('n1', _a), routeThrough: true);
    expect(nodeRouteSolveInputs(passage()), isNull);
    expect(() => notifier.regenerateSegment('d1', 'p1'), throwsStateError);
    expect(client.asked, isEmpty);
  });
}
