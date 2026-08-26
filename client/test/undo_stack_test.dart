// FR142(a) (Story K12) — bounded, session-scoped undo/redo over Trip
// snapshots.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

void main() {
  Trip trip(String title, {List<Day> days = const []}) => Trip(
        id: 't1',
        title: title,
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        days: days,
      );

  test('undo with nothing recorded returns null and does not change canUndo', () {
    final stack = TripUndoStack();
    expect(stack.canUndo, isFalse);
    expect(stack.undo(trip('A')), isNull);
  });

  test('redo with nothing to redo returns null', () {
    final stack = TripUndoStack();
    expect(stack.canRedo, isFalse);
    expect(stack.redo(trip('A')), isNull);
  });

  test('record then undo restores the prior snapshot and enables redo', () {
    final stack = TripUndoStack();
    final before = trip('A');
    final after = trip('B');

    stack.record(before);
    expect(stack.canUndo, isTrue);
    expect(stack.undoDepth, 1);

    final restored = stack.undo(after);
    expect(restored, isNotNull);
    expect(restored!.title, 'A');
    expect(stack.canUndo, isFalse);
    expect(stack.canRedo, isTrue);
  });

  test('undo then redo returns to the state before the undo', () {
    final stack = TripUndoStack();
    stack.record(trip('A'));
    final undone = stack.undo(trip('B'))!;
    final redone = stack.redo(undone);
    expect(redone, isNotNull);
    expect(redone!.title, 'B');
    expect(stack.canRedo, isFalse);
  });

  test('recording a new action clears the redo stack — no stale branch', () {
    final stack = TripUndoStack();
    stack.record(trip('A'));
    stack.undo(trip('B'));
    expect(stack.canRedo, isTrue);

    stack.record(trip('C'));
    expect(stack.canRedo, isFalse);
  });

  test('depth is bounded to maxDepth, dropping the oldest entry', () {
    final stack = TripUndoStack(maxDepth: 2);
    stack.record(trip('A'));
    stack.record(trip('B'));
    stack.record(trip('C'));
    expect(stack.undoDepth, 2);

    // Oldest ('A') should have been evicted; only 'C' then 'B' are reachable.
    var current = trip('D');
    current = stack.undo(current)!;
    expect(current.title, 'C');
    current = stack.undo(current)!;
    expect(current.title, 'B');
    expect(stack.canUndo, isFalse);
  });

  test('clear discards both stacks — trip close leaves nothing to undo or redo', () {
    final stack = TripUndoStack();
    stack.record(trip('A'));
    stack.undo(trip('B'));
    expect(stack.canRedo, isTrue);

    stack.clear();
    expect(stack.canUndo, isFalse);
    expect(stack.canRedo, isFalse);
  });

  test('undo restores day content, not just top-level scalar fields', () {
    final stack = TripUndoStack();
    final before = trip('A', days: [Day(id: 'd1', index: 1)]);
    final after = trip('A', days: [Day(id: 'd1', index: 1), Day(id: 'd2', index: 2)]);

    stack.record(before);
    final restored = stack.undo(after)!;
    expect(restored.days.map((d) => d.id), ['d1']);
  });
}
