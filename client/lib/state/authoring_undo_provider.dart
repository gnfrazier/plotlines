// FR142(a) (Story K12) — the one undo/redo history for the open trip, over
// everything an Author authors in it: the payload (`currentTripProvider`),
// the trip's mode set (beside the payload, #319), the roster layer
// (`currentRosterProvider`) and the trip bbox (`tripBboxProvider`, D70).
//
// Every authored mutation runs through [AuthoringUndoController.edit], which
// captures the state before it and records one labelled step. The notifiers
// call it themselves (`CurrentTripNotifier`, `CurrentRosterNotifier`), so a
// screen never decides whether its action is undoable; the one exception is
// the bbox, whose single authored write is the trip-area screen's Apply.
// Nested edits — a method that calls another — record once, as the outer
// action, and so do edits made in the same synchronous turn (one gesture).
//
// Three boundaries (ARCH §10.4):
//  * **Session-scoped.** Nothing here is persisted. Opening, starting or
//    adopting a trip clears it, and so does leaving the trip for the
//    library; the undo menu says so.
//  * **Authored work only.** A re-solve, the compose pass and other derived
//    writes run inside [AuthoringUndoController.derived] instead of
//    recording a step — re-solving is idempotent, so there is nothing to reverse (D52).
//    Because a step is a whole snapshot, undoing an authored edit returns
//    the derived work that went with it too, so the result is always a
//    state the trip was really in.
//  * **Author-note deletion is never undone** (FR135a, D51). A restore keeps
//    the *current* `authorNotes` rather than the snapshot's, so a note
//    deleted — or dropped with its person — stays deleted whatever is
//    undone around it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/domain.dart';
import '../domain/trip_bbox.dart';
import 'current_roster_provider.dart';
import 'current_trip_provider.dart';
import 'trip_bbox_provider.dart';

/// The stated depth (FR142(a)): how many steps the session keeps.
const int undoHistoryDepth = 30;

/// One recorded state. The payload is held as its canonical JSON string
/// (D28) rather than the live object, so nothing that later shares a list
/// with the live trip can change a step after it was taken.
class AuthoringSnapshot {
  AuthoringSnapshot.capture(Trip trip, TripRoster roster, this.bbox)
      : tripJson = jsonEncode(trip.toJson()),
        modes = Set.unmodifiable(trip.modes),
        rosterJson = jsonEncode(roster.toJson());

  final String tripJson;

  /// [Trip.modes] rides beside the payload, not in it (#319) — a snapshot of
  /// `toJson()` alone would restore every trip with an empty mode set.
  final Set<String> modes;
  final String rosterJson;
  final TripBbox? bbox;

  Trip restoreTrip() =>
      Trip.fromJson(jsonDecode(tripJson) as Map<String, dynamic>).copyWith(modes: modes);

  /// FR135a — Author notes are taken from [current], never from the
  /// snapshot: deletion is irreversible by design.
  TripRoster restoreRoster(TripRoster current) =>
      TripRoster.fromJson(jsonDecode(rosterJson) as Map<String, dynamic>)
          .copyWith(authorNotes: current.authorNotes);
}

/// What the undo controls render.
class UndoStatus {
  const UndoStatus({
    this.undoLabel,
    this.redoLabel,
    this.history = const [],
    this.depth = undoHistoryDepth,
  });

  final String? undoLabel;
  final String? redoLabel;

  /// Every undoable step this session, newest first.
  final List<String> history;

  /// The stated maximum.
  final int depth;

  bool get canUndo => undoLabel != null;
  bool get canRedo => redoLabel != null;
}

class AuthoringUndoController extends StateNotifier<UndoStatus> {
  AuthoringUndoController(this._ref, {DateTime Function()? clock})
      : _history = UndoHistory<AuthoringSnapshot>(maxDepth: undoHistoryDepth, clock: clock),
        super(const UndoStatus());

  final Ref _ref;
  final UndoHistory<AuthoringSnapshot> _history;

  int _depth = 0;
  bool _restoring = false;

  /// True from a recorded step until the end of the current synchronous
  /// turn. One Author gesture is one event; a handler that calls two
  /// mutators for it (place a node, then mark its passage stale) is still
  /// one step, labelled by the first.
  bool _turnOpen = false;

  /// Runs [apply] — one authored action — and records the state before it as
  /// one step labelled [label]. Nothing is recorded when the action changed
  /// nothing, when it runs inside another edit (the outer one is the step),
  /// or while a step is being restored. Edits sharing [coalesceKey] within
  /// two seconds fold into the first one's step (typing, a dragged slider).
  T edit<T>(String label, T Function() apply, {String? coalesceKey}) {
    if (_depth > 0 || _restoring || _turnOpen || _history.coalesces(coalesceKey)) {
      return _nested(apply);
    }
    final trip = _ref.read(currentTripProvider);
    final roster = _ref.read(currentRosterProvider);
    final bbox = _ref.read(tripBboxProvider);
    final result = _nested(apply);
    // The notifiers never mutate a held value in place — every write is a
    // new object — so identity is the "did anything change" test, and the
    // before-values are still intact to encode now.
    if (identical(trip, _ref.read(currentTripProvider)) &&
        identical(roster, _ref.read(currentRosterProvider)) &&
        bbox == _ref.read(tripBboxProvider)) {
      return result;
    }
    _history.record(label, AuthoringSnapshot.capture(trip, roster, bbox),
        coalesceKey: coalesceKey);
    _turnOpen = true;
    scheduleMicrotask(() => _turnOpen = false);
    _publish();
    return result;
  }

  T _nested<T>(T Function() apply) {
    _depth++;
    try {
      return apply();
    } finally {
      _depth--;
    }
  }

  /// Runs [apply] — a derived write (a re-solve, the compose pass) — without
  /// recording a step, even where it goes through the same mutators an
  /// authored edit uses. It still ends any redo branch: replaying an undone
  /// state over a fresh solve would throw the solve away without saying so.
  T derived<T>(T Function() apply) {
    final trip = _ref.read(currentTripProvider);
    final result = _nested(apply);
    if (!_restoring && _history.canRedo && !identical(trip, _ref.read(currentTripProvider))) {
      _history.clearRedo();
      _publish();
    }
    return result;
  }

  void undo() {
    final target = _history.undo(_capture());
    if (target == null) return;
    _restore(target);
    _publish();
  }

  void redo() {
    final target = _history.redo(_capture());
    if (target == null) return;
    _restore(target);
    _publish();
  }

  /// Trip close / open / new — the history belongs to one editing session
  /// of one trip.
  ///
  /// A no-op on an empty history, so opening a trip inside a provider's own
  /// initialisation (`CurrentTripNotifier(ref)..open(trip)`) never modifies
  /// this provider while another is being built.
  void clear() {
    if (!_history.canUndo && !_history.canRedo) return;
    _history.clear();
    _publish();
  }

  AuthoringSnapshot _capture() => AuthoringSnapshot.capture(
        _ref.read(currentTripProvider),
        _ref.read(currentRosterProvider),
        _ref.read(tripBboxProvider),
      );

  void _restore(AuthoringSnapshot s) {
    _restoring = true;
    try {
      _ref.read(currentTripProvider.notifier).restore(s.restoreTrip());
      final roster = _ref.read(currentRosterProvider);
      _ref.read(currentRosterProvider.notifier).open(s.restoreRoster(roster));
      // Only a real change touches the bbox: setting it restarts the region
      // settle window (#246), which an undo of a role edit has no reason to.
      if (s.bbox != _ref.read(tripBboxProvider)) {
        final bboxes = _ref.read(tripBboxProvider.notifier);
        s.bbox == null ? bboxes.reset() : bboxes.set(s.bbox!);
      }
    } finally {
      _restoring = false;
    }
  }

  void _publish() {
    if (!mounted) return;
    state = UndoStatus(
      undoLabel: _history.undoLabel,
      redoLabel: _history.redoLabel,
      history: _history.undoLabels,
    );
  }
}

final authoringUndoProvider = StateNotifierProvider<AuthoringUndoController, UndoStatus>(
    (ref) => AuthoringUndoController(ref));
