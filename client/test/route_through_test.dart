// Issue #589 (ARCH D71) — "Route through this": a node's coordinate in
// `Segment.via`, kept in step with the node by the notifier.
//
// Before #589 a placed node never reached `via`, so an Explore Author who added
// a rest stop after generating a route had no way to make the route go there.
// These pin the pure ordering/reach helpers (`domain/route_through.dart`) and
// every notifier path that has to keep `via` and the node together: turn on,
// turn off, move, delete, the stale mark, the A9a advisory flag, and that an
// annotation node changes nothing.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/authoring_undo_provider.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

const _start = <double>[-105.40, 40.0];
const _end = <double>[-105.00, 40.0];

Segment _p2p({List<Coord> via = const [], bool solved = true, List<Node> nodes = const []}) =>
    Segment(
      id: 's1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: _start,
      end: _end,
      via: via,
      nodes: nodes,
      geometry: solved ? LineString(coordinates: const [_start, _end]) : null,
      solve: solved ? SolveProvenance(stale: false) : null,
    );

Node _node(String id, Coord coord, {NodeKind kind = NodeKind.restStop, String? title}) =>
    Node(id: id, kind: kind, coord: coord, title: title);

Trip _trip(Segment s) => Trip(
      id: 't1',
      title: 'Trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: [Day(id: 'd1', index: 1, segments: [s])],
    );

(ProviderContainer, CurrentTripNotifier) _open(Segment s) {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  final notifier = container.read(currentTripProvider.notifier)..open(_trip(s));
  return (container, notifier);
}

Segment _seg(ProviderContainer c) => c.read(currentTripProvider).days.single.segments.single;

void main() {
  group('viaWithInserted — where a new point goes', () {
    test('orders by distance along the solved line', () {
      final s = _p2p(via: const [
        [-105.30, 40.0],
        [-105.10, 40.0],
      ]);
      expect(viaWithInserted(s, const [-105.20, 40.001]), const [
        [-105.30, 40.0],
        [-105.20, 40.001],
        [-105.10, 40.0],
      ]);
      expect(viaWithInserted(s, const [-105.35, 40.0]).first, const [-105.35, 40.0]);
      expect(viaWithInserted(s, const [-105.05, 40.0]).last, const [-105.05, 40.0]);
    });

    test('unsolved point-to-point orders along the start→end chord', () {
      final s = _p2p(solved: false, via: const [
        [-105.10, 40.0],
      ]);
      expect(viaWithInserted(s, const [-105.30, 40.02]).first, const [-105.30, 40.02]);
    });

    test('an unsolved loop has nothing to measure along, so the point appends', () {
      final s = Segment(id: 's1', mode: 'cycling', shape: 'loop', start: _start, via: const [
        [-105.10, 40.0],
      ]);
      expect(viaWithInserted(s, const [-105.30, 40.0]).last, const [-105.30, 40.0]);
    });

    test('keeps an Author reordering of the points already there', () {
      // Deliberately out of line order: the Author put the far point first.
      final s = _p2p(via: const [
        [-105.10, 40.0],
        [-105.30, 40.0],
      ]);
      final via = viaWithInserted(s, const [-105.05, 40.0]);
      expect(via.sublist(0, 2), s.via);
    });

    test('a point already in the list is not added twice', () {
      final s = _p2p(via: const [
        [-105.20, 40.0],
      ]);
      expect(viaWithInserted(s, const [-105.20, 40.0]), s.via);
    });
  });

  group('viaReach — did the line reach each point, by name', () {
    test('names a node by its title, else its kind; a bare tap by position', () {
      final s = _p2p(
        via: const [
          [-105.30, 40.0],
          [-105.20, 40.0],
          [-105.10, 40.0],
        ],
        nodes: [
          _node('n1', const [-105.30, 40.0], title: 'Lunch'),
          _node('n2', const [-105.20, 40.0], kind: NodeKind.waypoint),
        ],
      );
      expect([for (final r in viaReach(s)) r.label], ['Lunch', 'Waypoint', 'Point 3']);
    });

    test('a point on the line is reached; one far off is missed, with its distance', () {
      final s = _p2p(via: const [
        [-105.20, 40.0],
        [-105.20, 40.01], // ~1.1 km north of the line
      ]);
      final reach = viaReach(s);
      expect(reach[0].reached, isTrue);
      expect(reach[1].reached, isFalse);
      expect(reach[1].offsetM, closeTo(1112, 5));
    });

    test('no solved line means no measurement, not a miss', () {
      final r = viaReach(_p2p(solved: false, via: const [
        [-105.20, 40.0],
      ])).single;
      expect(r.offsetM, isNull);
      expect(r.reached, isFalse);
    });
  });

  group('CurrentTripNotifier keeps via in step with its nodes', () {
    test('a new node saved with Route through this joins via and marks stale', () {
      final (c, n) = _open(_p2p());
      n.saveSegmentNode('d1', 's1', _node('n1', const [-105.2, 40.0]), routeThrough: true);
      final s = _seg(c);
      expect(s.nodes.single.id, 'n1');
      expect(s.via, const [
        [-105.2, 40.0],
      ]);
      expect(s.solve!.stale, isTrue);
    });

    test('an annotation node changes nothing about the route', () {
      final (c, n) = _open(_p2p());
      n.saveSegmentNode('d1', 's1', _node('n1', const [-105.2, 40.0]), routeThrough: false);
      final s = _seg(c);
      expect(s.nodes, hasLength(1));
      expect(s.via, isEmpty);
      expect(s.solve!.stale, isFalse);
    });

    test('setNodeRouteThrough on, then off: the node stays, the via point goes', () {
      final node = _node('n1', const [-105.2, 40.0]);
      final (c, n) = _open(_p2p(nodes: [node]));

      n.setNodeRouteThrough('d1', 's1', 'n1', true);
      expect(_seg(c).via, const [
        [-105.2, 40.0],
      ]);
      expect(_seg(c).solve!.stale, isTrue);

      n.setNodeRouteThrough('d1', 's1', 'n1', false);
      expect(_seg(c).via, isEmpty);
      expect(_seg(c).nodes.single.coord, const [-105.2, 40.0]);
    });

    test('moving a routed-through node moves its via point in place', () {
      final a = _node('a', const [-105.3, 40.0]);
      final b = _node('b', const [-105.1, 40.0]);
      final (c, n) = _open(_p2p(nodes: [a, b], via: [a.coord, b.coord]));

      final moved = _node('a', const [-105.05, 40.002]);
      n.replaceNodeInSegment('d1', 's1', moved);

      // Still first: the Author's order is kept, the point just moves.
      expect(_seg(c).via, [moved.coord, b.coord]);
      expect(_seg(c).solve!.stale, isTrue);
    });

    test('retitling a routed-through node leaves via and the solve alone', () {
      final a = _node('a', const [-105.3, 40.0]);
      final (c, n) = _open(_p2p(nodes: [a], via: [a.coord]));
      n.saveSegmentNode('d1', 's1', _node('a', a.coord, title: 'Lunch'), routeThrough: true);
      expect(_seg(c).via, [a.coord]);
      expect(_seg(c).solve!.stale, isFalse);
    });

    test('deleting a routed-through node removes its via point and marks stale', () {
      final a = _node('a', const [-105.3, 40.0]);
      final (c, n) = _open(_p2p(nodes: [a], via: [a.coord, const [-105.1, 40.0]]));
      n.removeNodesById({'a'});
      expect(_seg(c).nodes, isEmpty);
      expect(_seg(c).via, const [
        [-105.1, 40.0],
      ]);
      expect(_seg(c).solve!.stale, isTrue);
    });

    test('deleting an annotation node leaves via and the solve alone', () {
      final a = _node('a', const [-105.3, 40.0]);
      final (c, n) = _open(_p2p(nodes: [a], via: const [
        [-105.1, 40.0],
      ]));
      n.removeNodesById({'a'});
      expect(_seg(c).via, const [
        [-105.1, 40.0],
      ]);
      expect(_seg(c).solve!.stale, isFalse);
    });

    test('one state change: undo restores the node and its via point together', () async {
      // K12's undo (#118) snapshots the trip per action, so the node and its
      // via point have to land in one state change, and one undo step, or
      // an undo could split them.
      final (c, n) = _open(_p2p());
      var emissions = 0;
      c.listen(currentTripProvider, (_, _) => emissions++);

      n.saveSegmentNode('d1', 's1', _node('n1', const [-105.2, 40.0]), routeThrough: true);
      expect(emissions, 1);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(authoringUndoProvider).history, ['Add a place']);

      c.read(authoringUndoProvider.notifier).undo();
      final s = _seg(c);
      expect(s.nodes, isEmpty);
      expect(s.via, isEmpty);
      expect(s.solve!.stale, isFalse);
    });

    test('turning route-through off is its own undo step and puts the via point back', () async {
      final a = _node('a', const [-105.3, 40.0]);
      final (c, n) = _open(_p2p(nodes: [a], via: [a.coord]));
      n.setNodeRouteThrough('d1', 's1', 'a', false);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(authoringUndoProvider).history, ['Stop routing through a place']);

      c.read(authoringUndoProvider.notifier).undo();
      expect(_seg(c).via, [a.coord]);
    });

    test('a third routed-through node makes a banded loop target advisory (A9a)', () {
      final loop = Segment(
        id: 's1',
        mode: 'cycling',
        shape: 'loop',
        start: _start,
        via: const [
          [-105.3, 40.0],
          [-105.2, 40.0],
        ],
        targetDistance: TargetDistance(valueM: 20000, minM: 18000, maxM: 22000),
      );
      final (c, n) = _open(loop);
      n.saveSegmentNode('d1', 's1', _node('n3', const [-105.1, 40.0]), routeThrough: true);
      expect(_seg(c).via, hasLength(3));
      expect(_seg(c).targetDistance!.advisory, isTrue);

      n.setNodeRouteThrough('d1', 's1', 'n3', false);
      expect(_seg(c).targetDistance!.advisory, isFalse);
    });
  });
}
