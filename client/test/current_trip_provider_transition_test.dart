// Story B3 (issue #32), FR12 — placing a transition node between two
// passages and attaching Author instructions to it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

Segment _passage(String id, {String mode = 'cycling', Coord? start, Coord? end}) =>
    Segment(id: id, mode: mode, shape: 'point_to_point', start: start, end: end);

ProviderContainer _container(List<Segment> segments) {
  final container = ProviderContainer();
  container.read(currentTripProvider.notifier).open(
        Trip(
          id: 't1',
          title: 'Test trip',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          days: [Day(id: 'day-1', index: 1, segments: segments)],
        ),
      );
  return container;
}

Day _day(ProviderContainer c) => c.read(currentTripProvider).days.single;
Transition _only(ProviderContainer c) => _day(c).transitions.single;

ProviderContainer _rideToPaddle() => _container([
      _passage('a', mode: 'cycling', start: const [-105.30, 40.00], end: const [-105.29, 40.00]),
      _passage('b', mode: 'paddling', start: const [-105.29, 40.00], end: const [-105.25, 40.00]),
    ]);

void main() {
  group('setTransitionNode', () {
    test('attaches Author instructions to the junction between two passages', () {
      final container = _rideToPaddle();
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).setTransitionNode(
            'day-1',
            _only(container).id,
            title: 'Put-in at Lyons',
            instructions: 'Stash the bikes behind the outhouse; put in below the bridge.',
          );

      final t = _only(container);
      expect(t.node?.kind, NodeKind.transition);
      expect(t.node?.title, 'Put-in at Lyons');
      expect(t.instructions, 'Stash the bikes behind the outhouse; put in below the bridge.');
    });

    test('places the node at the junction when the Author picks no point', () {
      final container = _rideToPaddle();
      addTearDown(container.dispose);

      container
          .read(currentTripProvider.notifier)
          .setTransitionNode('day-1', _only(container).id, instructions: 'Put in here.');

      // The preceding passage's end — where a Character finishes the ride.
      expect(_only(container).node?.coord, const [-105.29, 40.00]);
    });

    test('takes an explicit coordinate when the Author places one', () {
      final container = _rideToPaddle();
      addTearDown(container.dispose);

      container.read(currentTripProvider.notifier).setTransitionNode(
            'day-1',
            _only(container).id,
            instructions: 'Park in the gravel pull-out, not the lot.',
            coord: const [-105.285, 40.001],
          );

      expect(_only(container).node?.coord, const [-105.285, 40.001]);
    });

    test('revising keeps the node id, so nothing referencing it breaks', () {
      final container = _rideToPaddle();
      addTearDown(container.dispose);
      final notifier = container.read(currentTripProvider.notifier);
      final transitionId = _only(container).id;

      notifier.setTransitionNode('day-1', transitionId, instructions: 'First draft.');
      final firstId = _only(container).node!.id;
      notifier.setTransitionNode('day-1', transitionId, instructions: 'Second draft.');

      expect(_only(container).node!.id, firstId);
      expect(_only(container).instructions, 'Second draft.');
    });

    test('blank instructions clear them rather than storing an empty string', () {
      final container = _rideToPaddle();
      addTearDown(container.dispose);
      final notifier = container.read(currentTripProvider.notifier);
      final transitionId = _only(container).id;

      notifier.setTransitionNode('day-1', transitionId, instructions: 'Something.');
      notifier.setTransitionNode('day-1', transitionId, instructions: '   ');

      expect(_only(container).instructions, isNull);
      // The node stays — the Author cleared the text, not the pin.
      expect(_only(container).node, isNotNull);
    });

    test('the node belongs to the day, never to either passage', () {
      // A transition duplicated onto a passage would reach the cue sheet twice
      // and vanish when that passage was removed.
      final container = _rideToPaddle();
      addTearDown(container.dispose);

      container
          .read(currentTripProvider.notifier)
          .setTransitionNode('day-1', _only(container).id, instructions: 'Put in here.');

      final day = _day(container);
      expect(day.segments.every((s) => s.nodes.isEmpty), isTrue);
      expect(day.nodes, isEmpty);
    });

    test('does nothing for a junction that is not there', () {
      final container = _rideToPaddle();
      addTearDown(container.dispose);

      final written = container
          .read(currentTripProvider.notifier)
          .setTransitionNode('day-1', 'no-such-transition', instructions: 'x');

      expect(written, isNull);
      expect(_only(container).node, isNull);
    });

    test('does nothing when neither passage has a position to place it at', () {
      final container = _container([_passage('a'), _passage('b')]);
      addTearDown(container.dispose);

      final written = container
          .read(currentTripProvider.notifier)
          .setTransitionNode('day-1', _only(container).id, instructions: 'x');

      expect(written, isNull);
    });
  });

  group('removeTransitionNode', () {
    test('takes the node off but leaves the junction itself', () {
      final container = _rideToPaddle();
      addTearDown(container.dispose);
      final notifier = container.read(currentTripProvider.notifier);
      final transitionId = _only(container).id;
      notifier.setTransitionNode('day-1', transitionId, instructions: 'Put in here.');

      notifier.removeTransitionNode('day-1', transitionId);

      // Two passages still meet here; the junction simply carries nothing.
      expect(_only(container).node, isNull);
      expect(_only(container).fromSegmentId, 'a');
      expect(_only(container).toSegmentId, 'b');
    });

    test('is a no-op for a junction that is not there', () {
      final container = _rideToPaddle();
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).removeTransitionNode('day-1', 'nope');
      expect(_day(container).transitions.length, 1);
    });
  });

  group('instructions survive the edits that keep the junction', () {
    test('a reorder that keeps the pair adjacent keeps the instructions', () {
      final container = _container([
        _passage('a', start: const [-105.30, 40.00], end: const [-105.29, 40.00]),
        _passage('b', mode: 'paddling', start: const [-105.29, 40.00], end: const [-105.25, 40.00]),
        _passage('c', mode: 'hiking', start: const [-105.25, 40.00], end: const [-105.24, 40.00]),
      ]);
      addTearDown(container.dispose);
      final notifier = container.read(currentTripProvider.notifier);
      final ab = _day(container).transitions.first;
      notifier.setTransitionNode('day-1', ab.id, instructions: 'Put in below the bridge.');

      notifier.movePassage('day-1', 'c', by: -2);

      expect(_day(container).segments.map((s) => s.id), ['c', 'a', 'b']);
      final kept = _day(container).transitions.firstWhere((t) => t.toSegmentId == 'b');
      expect(kept.instructions, 'Put in below the bridge.');
    });

    test('moving an endpoint re-measures the gap without disturbing the instructions', () {
      final container = _rideToPaddle();
      addTearDown(container.dispose);
      final notifier = container.read(currentTripProvider.notifier);
      notifier.setTransitionNode('day-1', _only(container).id,
          instructions: 'Take out river left.');

      notifier.updateSegmentEndpoints('day-1', 'a', end: const [-105.20, 40.00]);

      expect(_only(container).instructions, 'Take out river left.');
      expect(_only(container).gapWarning, isTrue);
    });

    test('a transition node round-trips through the payload', () {
      final container = _rideToPaddle();
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).setTransitionNode(
          'day-1', _only(container).id,
          title: 'Put-in', instructions: 'Below the gauge.');

      final wire = container.read(currentTripProvider).toJson();
      final reopened = Trip.fromJson(wire);

      final t = reopened.days.single.transitions.single;
      expect(t.node?.kind, NodeKind.transition);
      expect(t.node?.title, 'Put-in');
      expect(t.instructions, 'Below the gauge.');
    });
  });
}
