/// FR142(a) (Story K12) — undo/redo for authoring actions (promotion,
/// removal, edits, arrangement, reveal changes, group assignment, day
/// restructuring), implemented as bounded snapshots of the canonical trip
/// payload. Session-scoped: this stack lives in memory only and is never
/// persisted, so it is inherently cleared on trip close (a fresh
/// [TripUndoStack] per open trip) as well as by an explicit [clear] call.
///
/// Not part of the trip payload schema — this describes editing session
/// state, not trip content (cf. `diagnosis.dart`).
///
/// FR142(a)'s exclusions fall out of what a snapshot *is* rather than needing
/// their own code path: a snapshot is [Trip.toJson], and Author-note deletion
/// (FR135a) and Character-layer state are not fields on [Trip] — `FieldNote`
/// and `Amendment` are account/group-relay layers that never live inside
/// `trip.payload` (see `domain/README.md`) — so recording a trip snapshot can
/// never capture or restore either. Callers simply never call [record] around
/// an already-synced destructive action.
library;

import 'trip.dart';

/// A bounded undo/redo stack of [Trip] snapshots for one open trip's editing
/// session. [maxDepth] is the "stated depth" FR142(a) requires be visible to
/// the Author.
class TripUndoStack {
  TripUndoStack({this.maxDepth = 20}) : assert(maxDepth > 0, 'maxDepth must be positive');

  final int maxDepth;

  final List<Map<String, dynamic>> _undoStack = [];
  final List<Map<String, dynamic>> _redoStack = [];

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  /// How many steps back an Author could currently undo, for the "visible
  /// affordance" half of FR142(a) — e.g. a disabled/enabled state or a count
  /// badge on the undo control.
  int get undoDepth => _undoStack.length;
  int get redoDepth => _redoStack.length;

  /// Records [before] as the state to return to if the action about to be
  /// applied is undone. Call this immediately before applying an authoring
  /// action. Starting a new action clears the redo stack — redo only replays
  /// actions undone since the last recorded action, never a stale branch.
  void record(Trip before) {
    _undoStack.add(before.toJson());
    if (_undoStack.length > maxDepth) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  /// Steps back one recorded action. [current] is the live trip, captured
  /// onto the redo stack so [redo] can step forward again. Returns `null`
  /// when [canUndo] is false.
  Trip? undo(Trip current) {
    if (_undoStack.isEmpty) return null;
    final previous = _undoStack.removeLast();
    _redoStack.add(current.toJson());
    return Trip.fromJson(previous);
  }

  /// Steps forward one previously-undone action. Returns `null` when
  /// [canRedo] is false.
  Trip? redo(Trip current) {
    if (_redoStack.isEmpty) return null;
    final next = _redoStack.removeLast();
    _undoStack.add(current.toJson());
    return Trip.fromJson(next);
  }

  /// Discards all undo/redo history. Called on trip close; also correct to
  /// call whenever a trip is re-solved from scratch, since FR142(a) draws
  /// undo's boundary at authored work and derived work is re-solved instead
  /// (Q3/FR140), never undone.
  void clear() {
    _undoStack.clear();
    _redoStack.clear();
  }
}
