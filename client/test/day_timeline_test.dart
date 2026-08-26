// Story B3 (issue #32), FR12 — a day read as a Character reads it: passages
// and the mode changes between them, each mode change carrying the Author's
// instructions. `domain/day_timeline.dart`.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

Segment _passage(
  String id, {
  String mode = 'cycling',
  double? distanceM,
  Coord? start,
  Coord? end,
}) =>
    Segment(
      id: id,
      mode: mode,
      shape: 'point_to_point',
      start: start,
      end: end,
      metrics: distanceM == null ? null : RouteMetrics(distanceM: distanceM),
    );

Node _transitionNode({String? instructions, String? title, Coord coord = const [-105.29, 40.0]}) =>
    Node(
      id: 'n1',
      kind: NodeKind.transition,
      coord: coord,
      title: title,
      instructions: instructions,
    );

/// Built through `resequencePassages` rather than by hand, because that is how
/// every real day gets its transitions (B2) — a timeline test that invents its
/// own would not notice the two drifting apart.
Day _day(List<Segment> segments, {List<Transition> transitions = const []}) =>
    resequencePassages(
        Day(id: 'day-1', index: 1, segments: segments, transitions: transitions));

void main() {
  group('dayTimeline', () {
    test('interleaves passages and the junctions between them, in order', () {
      final day = _day([
        _passage('a', mode: 'cycling', distanceM: 12000),
        _passage('b', mode: 'paddling', distanceM: 8000),
        _passage('c', mode: 'hiking', distanceM: 3000),
      ]);

      final timeline = dayTimeline(day);

      expect(timeline.map((e) => e.runtimeType.toString()), [
        'PassageEntry',
        'ModeChangeEntry',
        'PassageEntry',
        'ModeChangeEntry',
        'PassageEntry',
      ]);
    });

    test('a mode change sits at the distance the passage before it ends', () {
      final day = _day([
        _passage('a', mode: 'cycling', distanceM: 12000),
        _passage('b', mode: 'paddling', distanceM: 8000),
        _passage('c', mode: 'hiking', distanceM: 3000),
      ]);

      final changes = dayModeChanges(day);

      expect(changes[0].distanceAlongDayM, 12000);
      expect(changes[1].distanceAlongDayM, 20000);
    });

    test('names both modes at the change', () {
      final day = _day([
        _passage('a', mode: 'cycling', distanceM: 1),
        _passage('b', mode: 'paddling', distanceM: 1),
      ]);
      final change = dayModeChanges(day).single;
      expect(change.fromMode, 'cycling');
      expect(change.toMode, 'paddling');
      expect(change.isModeChange, isTrue);
    });

    test('two passages of the same mode are a junction but not a mode change', () {
      final day = _day([
        _passage('a', mode: 'cycling', distanceM: 1),
        _passage('b', mode: 'cycling', distanceM: 1),
      ]);
      final change = dayModeChanges(day).single;
      expect(change.isModeChange, isFalse);
    });

    test('an unsolved passage stops the timeline claiming distances, never guesses', () {
      final day = _day([
        _passage('a', distanceM: 12000),
        _passage('b', mode: 'paddling'),
        _passage('c', mode: 'hiking', distanceM: 3000),
      ]);

      final timeline = dayTimeline(day);

      expect(timeline[0].distanceAlongDayM, 0);
      expect(timeline[1].distanceAlongDayM, 12000);
      expect(timeline[2].distanceAlongDayM, 12000);
      // Everything after the unsolved leg is honestly unknown, not 12000.
      expect(timeline[3].distanceAlongDayM, isNull);
      expect(timeline[4].distanceAlongDayM, isNull);
    });

    test('a rest day and an empty day have no sequence to read', () {
      expect(dayTimeline(Day(id: 'd', index: 1, kind: 'rest')), isEmpty);
      expect(dayTimeline(_day(const [])), isEmpty);
      expect(dayTimeline(_day([_passage('a')])).length, 1);
    });
  });

  group('FR12 — instructions on the timeline', () {
    Day dayWithInstruction(String instructions) => _day([
          _passage('a', mode: 'cycling', distanceM: 12000),
          _passage('b', mode: 'paddling', distanceM: 8000),
        ], transitions: [
          Transition(
            id: 'tab',
            fromSegmentId: 'a',
            toSegmentId: 'b',
            node: _transitionNode(instructions: instructions, title: 'Put-in at Lyons'),
          ),
        ]);

    test('a mode change carries the Author instructions attached to it', () {
      final change = dayModeChanges(dayWithInstruction('Stash the bikes behind the outhouse.'))
          .single;
      expect(change.instructions, 'Stash the bikes behind the outhouse.');
      expect(change.transition.node?.title, 'Put-in at Lyons');
      expect(change.hasNode, isTrue);
      expect(change.coord, const [-105.29, 40.0]);
    });

    test('a junction with no node is still on the timeline, with nothing to say', () {
      final day = _day([
        _passage('a', mode: 'cycling', distanceM: 1),
        _passage('b', mode: 'paddling', distanceM: 1),
      ]);
      final change = dayModeChanges(day).single;
      // The mode change happens whether or not anyone wrote about it.
      expect(change.hasNode, isFalse);
      expect(change.instructions, isNull);
    });

    test('instructedModeChanges names only the junctions carrying instructions', () {
      final day = _day([
        _passage('a', mode: 'cycling', distanceM: 1),
        _passage('b', mode: 'paddling', distanceM: 1),
        _passage('c', mode: 'hiking', distanceM: 1),
      ], transitions: [
        Transition(
          id: 'tbc',
          fromSegmentId: 'b',
          toSegmentId: 'c',
          node: _transitionNode(instructions: 'Take out river left, above the weir.'),
        ),
      ]);

      expect(dayModeChanges(day).length, 2);
      expect(instructedModeChanges(day).map((e) => e.transition.id), ['tbc']);
    });

    test('a node with no instructions is a placed pin, not an instructed junction', () {
      final day = _day([
        _passage('a', mode: 'cycling', distanceM: 1),
        _passage('b', mode: 'paddling', distanceM: 1),
      ], transitions: [
        Transition(id: 'tab', fromSegmentId: 'a', toSegmentId: 'b', node: _transitionNode()),
      ]);
      expect(dayModeChanges(day).single.hasNode, isTrue);
      expect(instructedModeChanges(day), isEmpty);
    });
  });

  group('B2 carried through', () {
    test('the gap warning reaches the timeline without re-measuring', () {
      final day = _day([
        _passage('a', mode: 'cycling', distanceM: 1,
            start: const [-105.30, 40.00], end: const [-105.30, 40.00]),
        _passage('b', mode: 'paddling', distanceM: 1,
            start: const [-105.29, 40.00], end: const [-105.25, 40.00]),
      ]);
      final change = dayModeChanges(day).single;
      expect(change.gapWarning, isTrue);
      expect(change.gapM, closeTo(852.0, 5.0));
    });
  });

  group('defaultTransitionCoord', () {
    test('is the preceding passage\'s end — where a Character is standing', () {
      final day = _day([
        _passage('a', start: const [-105.30, 40.00], end: const [-105.29, 40.00]),
        _passage('b', start: const [-105.25, 40.00], end: const [-105.20, 40.00]),
      ]);
      expect(defaultTransitionCoord(day, 1), const [-105.29, 40.00]);
    });

    test('falls back to the next passage\'s start when the first has no position', () {
      final day = _day([
        _passage('a'),
        _passage('b', start: const [-105.25, 40.00]),
      ]);
      expect(defaultTransitionCoord(day, 1), const [-105.25, 40.00]);
    });

    test('is null when neither passage has a position, and outside the day', () {
      final day = _day([_passage('a'), _passage('b')]);
      expect(defaultTransitionCoord(day, 1), isNull);
      expect(defaultTransitionCoord(day, 0), isNull);
      expect(defaultTransitionCoord(day, 5), isNull);
    });
  });

  group('Transition', () {
    test('copyWith needs clearNode to take a node off — never a bare null', () {
      final t = Transition(
        id: 't',
        fromSegmentId: 'a',
        toSegmentId: 'b',
        node: _transitionNode(instructions: 'Put in below the gauge.'),
      );
      expect(t.copyWith(fromMode: 'cycling').node, isNotNull);
      expect(t.copyWith(clearNode: true).node, isNull);
      expect(t.copyWith(clearNode: true).instructions, isNull);
    });
  });
}
