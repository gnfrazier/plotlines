// Story B2 (issue #31), FR11 — ordering passages within a day and the
// adjacency gap warning. The pure half: `domain/passage_sequence.dart`.
//
// The numbers here are checked against `plotlines_core.trips.compose`'s, not
// merely against themselves — a client-side mirror of a server measurement is
// only worth having if the two agree on which side of the threshold a gap
// falls (see `core/tests/test_compose.py`'s gap tests, which use the same
// coordinates).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

Segment _passage(
  String id, {
  String mode = 'cycling',
  Coord? start,
  Coord? end,
  List<Coord>? geometry,
}) =>
    Segment(
      id: id,
      mode: mode,
      shape: 'point_to_point',
      start: start,
      end: end,
      geometry: geometry == null ? null : LineString(coordinates: geometry),
    );

Day _day(List<Segment> segments, {List<Transition> transitions = const []}) =>
    Day(id: 'day-1', index: 1, segments: segments, transitions: transitions);

void main() {
  group('haversineM', () {
    test('agrees with compose.py on a known separation', () {
      // One degree of latitude at the equator ≈ 111.19 km under this formula,
      // which is the number `compose.haversine_m` produces for the same pair.
      expect(haversineM(const [0, 0], const [0, 1]), closeTo(111194.9, 1.0));
      expect(haversineM(const [-105.27, 40.02], const [-105.27, 40.02]), 0.0);
    });
  });

  group('passageStart / passageEnd', () {
    test('prefer the solved geometry over the authored endpoints', () {
      final segment = _passage('s1',
          start: const [-105.30, 40.00],
          end: const [-105.20, 40.00],
          geometry: const [
            [-105.29, 40.00],
            [-105.21, 40.00],
          ]);
      expect(passageStart(segment), const [-105.29, 40.00]);
      expect(passageEnd(segment), const [-105.21, 40.00]);
    });

    test('a loop with no end ends where it began', () {
      final segment = _passage('s1', start: const [-105.30, 40.00]);
      expect(passageEnd(segment), const [-105.30, 40.00]);
    });

    test('a passage with no position at all measures nothing, never zero', () {
      expect(passageStart(_passage('s1')), isNull);
      expect(gapBetween(_passage('s1'), _passage('s2', start: const [0, 0])), isNull);
    });
  });

  group('resequencePassages', () {
    test('builds one transition per adjacent pair, carrying both modes', () {
      final day = _day([
        _passage('s1', mode: 'cycling', start: const [-105.30, 40.00], end: const [-105.29, 40.00]),
        _passage('s2', mode: 'paddling', start: const [-105.29, 40.00], end: const [-105.25, 40.00]),
        _passage('s3', mode: 'hiking', start: const [-105.25, 40.00], end: const [-105.24, 40.00]),
      ]);

      final sequenced = resequencePassages(day);

      expect(sequenced.transitions.length, 2);
      expect(sequenced.transitions[0].fromSegmentId, 's1');
      expect(sequenced.transitions[0].toSegmentId, 's2');
      expect(sequenced.transitions[0].fromMode, 'cycling');
      expect(sequenced.transitions[0].toMode, 'paddling');
      expect(sequenced.transitions[1].fromSegmentId, 's2');
      expect(sequenced.transitions[1].toSegmentId, 's3');
    });

    test('a day with fewer than two passages has no transitions to hold', () {
      expect(resequencePassages(_day([_passage('s1')])).transitions, isEmpty);
      expect(resequencePassages(_day(const [])).transitions, isEmpty);
    });

    test('endpoints that meet raise no warning', () {
      final day = _day([
        _passage('s1', start: const [-105.30, 40.00], end: const [-105.29, 40.00]),
        _passage('s2', start: const [-105.29, 40.00], end: const [-105.25, 40.00]),
      ]);
      final t = resequencePassages(day).transitions.single;
      expect(t.gapM, 0.0);
      expect(t.gapWarning, isFalse);
    });

    test('FR11: endpoints further apart than the threshold warn, with the gap measured', () {
      // ~0.01° of longitude at 40°N ≈ 852 m — comfortably over 500 m.
      final day = _day([
        _passage('s1', start: const [-105.30, 40.00], end: const [-105.30, 40.00]),
        _passage('s2', start: const [-105.29, 40.00], end: const [-105.25, 40.00]),
      ]);
      final t = resequencePassages(day).transitions.single;
      expect(t.gapWarning, isTrue);
      expect(t.gapM, closeTo(852.0, 5.0));
    });

    test('the threshold is 500 m, and only a gap over it warns', () {
      expect(kDefaultGapWarnM, 500.0);
      // `compose.py` compares `gap_m > gap_warn_m`, so the flag flips *above*
      // the threshold, not at it. Measured either side of the line rather than
      // exactly on it — an exact-500 m pair is not expressible in a float
      // without the comparison becoming a test of rounding.
      Transition at(double metres) {
        final day = _day([
          _passage('s1', start: const [0, 0], end: const [0, 0]),
          _passage('s2', start: [0.0, metres / 111194.926], end: const [0, 1]),
        ]);
        return resequencePassages(day).transitions.single;
      }

      expect(at(490.0).gapM, closeTo(490.0, 1.0));
      expect(at(490.0).gapWarning, isFalse);
      expect(at(510.0).gapWarning, isTrue);
    });

    test('the threshold is configurable, for the day-limit case that sets its own', () {
      final day = _day([
        _passage('s1', start: const [-105.30, 40.00], end: const [-105.30, 40.00]),
        _passage('s2', start: const [-105.29, 40.00], end: const [-105.25, 40.00]),
      ]);
      expect(resequencePassages(day, gapWarnM: 2000).transitions.single.gapWarning, isFalse);
      expect(resequencePassages(day, gapWarnM: 100).transitions.single.gapWarning, isTrue);
    });

    test('a gap that cannot be measured warns about nothing', () {
      final day = _day([_passage('s1'), _passage('s2')]);
      final t = resequencePassages(day).transitions.single;
      expect(t.gapM, isNull);
      expect(t.gapWarning, isNull);
    });

    test('preserves an existing transition\'s id and B3 node when the pair stays adjacent', () {
      final node = Node(
        id: 'n1',
        kind: NodeKind.transition,
        coord: const [-105.29, 40.00],
        instructions: 'Stash the bikes behind the outhouse.',
      );
      final day = _day([
        _passage('s1', start: const [-105.30, 40.00], end: const [-105.29, 40.00]),
        _passage('s2', start: const [-105.29, 40.00], end: const [-105.25, 40.00]),
      ], transitions: [
        Transition(id: 'authored', fromSegmentId: 's1', toSegmentId: 's2', node: node),
      ]);

      final t = resequencePassages(day).transitions.single;
      expect(t.id, 'authored');
      expect(t.node?.instructions, 'Stash the bikes behind the outhouse.');
      // ...and the derived half is filled in, which the authored one lacked.
      expect(t.gapM, 0.0);
    });

    test('drops a transition whose pair is no longer adjacent', () {
      // `compose_day` rejects one outright, so carrying it would produce a
      // payload the sidecar refuses.
      final day = _day([
        _passage('s2'),
        _passage('s1'),
      ], transitions: [
        Transition(id: 't', fromSegmentId: 's1', toSegmentId: 's2'),
      ]);
      final t = resequencePassages(day).transitions.single;
      expect(t.fromSegmentId, 's2');
      expect(t.toSegmentId, 's1');
    });

    test('is idempotent — running it twice changes nothing', () {
      final day = _day([
        _passage('s1', start: const [-105.30, 40.00], end: const [-105.29, 40.00]),
        _passage('s2', start: const [-105.28, 40.00], end: const [-105.25, 40.00]),
      ]);
      final once = resequencePassages(day);
      final twice = resequencePassages(once);
      expect(twice.transitions.map((t) => t.toJson()), once.transitions.map((t) => t.toJson()));
    });
  });

  group('reorderPassages', () {
    test('moves a passage later using the ReorderableListView index convention', () {
      final segments = [_passage('a'), _passage('b'), _passage('c')];
      expect(reorderPassages(segments, 0, 3).map((s) => s.id), ['b', 'c', 'a']);
      expect(reorderPassages(segments, 0, 2).map((s) => s.id), ['b', 'a', 'c']);
    });

    test('moves a passage earlier', () {
      final segments = [_passage('a'), _passage('b'), _passage('c')];
      expect(reorderPassages(segments, 2, 0).map((s) => s.id), ['c', 'a', 'b']);
    });

    test('leaves the source list untouched', () {
      final segments = [_passage('a'), _passage('b')];
      reorderPassages(segments, 0, 2);
      expect(segments.map((s) => s.id), ['a', 'b']);
    });

    test('rejects an index outside the day', () {
      final segments = [_passage('a'), _passage('b')];
      expect(() => reorderPassages(segments, 5, 0), throwsRangeError);
      expect(() => reorderPassages(segments, 0, 9), throwsRangeError);
    });
  });

  group('strandedInstructedTransitions', () {
    Day dayWithInstructedTransition() => _day([
          _passage('s1'),
          _passage('s2'),
          _passage('s3'),
        ], transitions: [
          Transition(
            id: 't12',
            fromSegmentId: 's1',
            toSegmentId: 's2',
            node: Node(
              id: 'n1',
              kind: NodeKind.transition,
              coord: const [0, 0],
              instructions: 'Put in below the gauge.',
            ),
          ),
        ]);

    test('names an authored transition a reorder would separate', () {
      final day = dayWithInstructedTransition();
      final stranded = strandedInstructedTransitions(day, reorderPassages(day.segments, 2, 1));
      expect(stranded.map((t) => t.id), ['t12']);
    });

    test('says nothing when the pair stays adjacent', () {
      final day = dayWithInstructedTransition();
      // Moving the third passage to the front leaves s1 → s2 intact.
      final stranded = strandedInstructedTransitions(day, reorderPassages(day.segments, 2, 0));
      expect(stranded, isEmpty);
    });

    test('FR139: a transition with no Author instructions is not worth a prompt', () {
      final day = _day([
        _passage('s1'),
        _passage('s2'),
      ], transitions: [
        Transition(id: 't12', fromSegmentId: 's1', toSegmentId: 's2'),
      ]);
      expect(strandedInstructedTransitions(day, [day.segments[1], day.segments[0]]), isEmpty);
    });
  });

  group('gapWarnings and transitionBefore', () {
    test('gapWarnings lists only the junctions over the threshold', () {
      final day = resequencePassages(_day([
        _passage('s1', start: const [-105.30, 40.00], end: const [-105.30, 40.00]),
        _passage('s2', start: const [-105.30, 40.00], end: const [-105.30, 40.00]),
        _passage('s3', start: const [-105.29, 40.00], end: const [-105.25, 40.00]),
      ]));
      expect(gapWarnings(day).map((t) => t.toSegmentId), ['s3']);
    });

    test('the first passage in a day joins nothing', () {
      final day = resequencePassages(_day([_passage('s1'), _passage('s2')]));
      expect(transitionBefore(day, 0), isNull);
      expect(transitionBefore(day, 1)?.fromSegmentId, 's1');
      expect(transitionBefore(day, 9), isNull);
    });
  });
}
