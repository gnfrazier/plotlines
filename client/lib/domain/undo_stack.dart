/// FR142(a) (Story K12) — undo/redo for authoring actions (promotion,
/// removal, edits, arrangement, reveal changes, group assignment, day
/// restructuring), implemented as a bounded ring of snapshots rather than a
/// command stack (ARCH §10.4): D28 already made `trip.payload` one canonical,
/// serializable blob, so a step is "the state before", never an inverse
/// operation per feature.
///
/// Session-scoped: the history lives in memory only and is never persisted,
/// so it is cleared on trip close (`AuthoringUndoController.clear`) and gone
/// on restart.
///
/// The snapshot type is the caller's — this file knows nothing about what a
/// step captures. `state/authoring_undo_provider.dart` captures the payload,
/// the trip's mode set, the roster and the bbox, and is where FR142(a)'s
/// exclusions are enforced: Author-note deletion (FR135a) is never restored,
/// and derived work (FR140) is re-solved rather than undone.
///
/// Not part of the trip payload schema — this describes editing session
/// state, not trip content (cf. `diagnosis.dart`).
library;

/// One undoable step: what to show the Author ([label]) and the state the
/// step returns to ([snapshot]).
class UndoStep<S> {
  UndoStep(this.label, this.snapshot, {this.coalesceKey, required this.at});

  /// Sentence-case description of the action, e.g. "Remove an anchor" — the
  /// undo control reads "Undo: <label>".
  final String label;
  final S snapshot;

  /// Edits sharing a key within [UndoHistory.coalesceWindow] of each other
  /// fold into one step — typing a note is one step, not one per keystroke.
  final String? coalesceKey;
  DateTime at;
}

/// A bounded undo/redo history of labelled snapshots for one open trip's
/// editing session. [maxDepth] is the "stated depth" FR142(a) requires be
/// visible to the Author.
class UndoHistory<S> {
  UndoHistory({
    this.maxDepth = 30,
    this.coalesceWindow = const Duration(seconds: 2),
    DateTime Function()? clock,
  })  : assert(maxDepth > 0, 'maxDepth must be positive'),
        _clock = clock ?? DateTime.now;

  final int maxDepth;
  final Duration coalesceWindow;
  final DateTime Function() _clock;

  final List<UndoStep<S>> _undo = [];
  final List<UndoStep<S>> _redo = [];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get undoDepth => _undo.length;
  int get redoDepth => _redo.length;

  /// What [undo] would reverse, or null.
  String? get undoLabel => _undo.isEmpty ? null : _undo.last.label;

  /// What [redo] would replay, or null.
  String? get redoLabel => _redo.isEmpty ? null : _redo.last.label;

  /// Every undoable step's label, newest first — the session list the undo
  /// menu shows.
  List<String> get undoLabels => [for (final s in _undo.reversed) s.label];

  /// True when an edit keyed [coalesceKey] belongs to the newest step rather
  /// than starting one, and refreshes that step's clock so continuous typing
  /// stays one step. Never true with redo pending: the edit is a new branch.
  bool coalesces(String? coalesceKey) {
    if (coalesceKey == null || _undo.isEmpty || _redo.isNotEmpty) return false;
    final top = _undo.last;
    final now = _clock();
    if (top.coalesceKey != coalesceKey || now.difference(top.at) > coalesceWindow) {
      return false;
    }
    top.at = now;
    return true;
  }

  /// Records [before] as the state to return to if the action just applied
  /// is undone. Starting a new action clears the redo history — redo only
  /// replays actions undone since the last recorded action, never a stale
  /// branch.
  void record(String label, S before, {String? coalesceKey}) {
    _undo.add(UndoStep(label, before, coalesceKey: coalesceKey, at: _clock()));
    if (_undo.length > maxDepth) _undo.removeAt(0);
    _redo.clear();
  }

  /// Steps back one recorded action. [current] is the live state, kept so
  /// [redo] can step forward again. Returns null when [canUndo] is false.
  S? undo(S current) {
    if (_undo.isEmpty) return null;
    final step = _undo.removeLast();
    _redo.add(UndoStep(step.label, current, at: _clock()));
    return step.snapshot;
  }

  /// Steps forward one previously-undone action. Returns null when [canRedo]
  /// is false.
  S? redo(S current) {
    if (_redo.isEmpty) return null;
    final step = _redo.removeLast();
    _undo.add(UndoStep(step.label, current, at: _clock()));
    return step.snapshot;
  }

  /// Drops the redo history alone — derived work written after an undo (a
  /// re-solve) is a new branch, and replaying the undone state over it would
  /// silently discard the solve.
  void clearRedo() => _redo.clear();

  /// Discards all history. Called on trip close.
  void clear() {
    _undo.clear();
    _redo.clear();
  }
}
