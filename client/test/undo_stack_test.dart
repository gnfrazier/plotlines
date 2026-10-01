// FR142(a) (Story K12) — the bounded, labelled, session-scoped undo history.
// What a step *captures* (payload, modes, roster, bbox) is the State layer's
// and is covered in `authoring_undo_provider_test.dart`; this is the ring.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

void main() {
  test('undo and redo with nothing recorded return null', () {
    final h = UndoHistory<String>();
    expect(h.canUndo, isFalse);
    expect(h.canRedo, isFalse);
    expect(h.undo('A'), isNull);
    expect(h.redo('A'), isNull);
  });

  test('record then undo restores the prior state and names the step', () {
    final h = UndoHistory<String>();
    h.record('Rename the trip', 'A');
    expect(h.undoLabel, 'Rename the trip');

    expect(h.undo('B'), 'A');
    expect(h.canUndo, isFalse);
    expect(h.redoLabel, 'Rename the trip');
    expect(h.redo('A'), 'B');
    expect(h.undoLabel, 'Rename the trip');
    expect(h.canRedo, isFalse);
  });

  test('recording a new action clears redo — no stale branch', () {
    final h = UndoHistory<String>()..record('one', 'A');
    h.undo('B');
    expect(h.canRedo, isTrue);
    h.record('two', 'C');
    expect(h.canRedo, isFalse);
  });

  test('depth is bounded, dropping the oldest step', () {
    final h = UndoHistory<String>(maxDepth: 2)
      ..record('a', 'A')
      ..record('b', 'B')
      ..record('c', 'C');
    expect(h.undoDepth, 2);
    expect(h.undoLabels, ['c', 'b']);
    expect(h.undo('D'), 'C');
    expect(h.undo('C'), 'B');
    expect(h.canUndo, isFalse);
  });

  test('clear discards both histories — trip close leaves nothing', () {
    final h = UndoHistory<String>()..record('a', 'A');
    h.undo('B');
    h.clear();
    expect(h.canUndo, isFalse);
    expect(h.canRedo, isFalse);
  });

  test('clearRedo drops only the redo branch', () {
    final h = UndoHistory<String>()
      ..record('a', 'A')
      ..record('b', 'B');
    h.undo('C');
    h.clearRedo();
    expect(h.canRedo, isFalse);
    expect(h.undoLabels, ['a']);
  });

  group('coalescing', () {
    late DateTime now;
    late UndoHistory<String> h;
    setUp(() {
      now = DateTime(2026, 10, 1, 12);
      h = UndoHistory<String>(clock: () => now);
    });

    test('an edit with the newest step\'s key inside the window folds into it', () {
      h.record('Edit a note', 'A', coalesceKey: 'note:1');
      now = now.add(const Duration(seconds: 1));
      expect(h.coalesces('note:1'), isTrue);
      // Continuous typing refreshes the clock, so it stays one step.
      now = now.add(const Duration(milliseconds: 1900));
      expect(h.coalesces('note:1'), isTrue);
      expect(h.undoDepth, 1);
    });

    test('a different key, no key, or a pause starts a new step', () {
      h.record('Edit a note', 'A', coalesceKey: 'note:1');
      expect(h.coalesces('note:2'), isFalse);
      expect(h.coalesces(null), isFalse);
      now = now.add(const Duration(seconds: 3));
      expect(h.coalesces('note:1'), isFalse);
    });

    test('never coalesces into a step while redo is pending', () {
      h.record('Edit a note', 'A', coalesceKey: 'note:1');
      h.record('Rename', 'B');
      h.undo('C');
      expect(h.coalesces('note:1'), isFalse);
    });
  });
}
