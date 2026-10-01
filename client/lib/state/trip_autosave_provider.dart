// Issue #577 — autosave (owner's decision, 2026-10-01). Saving used to be the
// manual Save button alone, so any way out of a trip would silently drop
// authored work — which "never silently discard authored work" forbids, and
// which is why the shell had no exit at all for a new trip. While a trip is
// open in the shell, every change to it is persisted after a short quiet
// period, and leaving flushes whatever is still pending. Save stays as an
// explicit confirmation (it also runs the sidecar's composition pass); it is
// no longer a requirement.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'current_roster_provider.dart';
import 'current_trip_provider.dart';
import 'providers.dart';
import 'trip_bbox_provider.dart';

/// How long the open trip must hold still before it is written. Long enough
/// that a drag of the target-distance slider or a run of keystrokes is one
/// write, short enough that quitting a moment after an edit loses nothing a
/// flush on leave wouldn't also catch.
const tripAutosaveDebounce = Duration(seconds: 2);

/// What the shell's quiet indicator says — never a prompt.
enum AutosaveStatus { idle, pending, saving, saved, failed }

class TripAutosave extends StateNotifier<AutosaveStatus> {
  TripAutosave(this._ref, {Duration? debounce})
      : _debounce = debounce ?? tripAutosaveDebounce,
        super(AutosaveStatus.idle) {
    // Listened from creation, acted on only between [start] and [stop]: a
    // trip opened or reset outside the shell (the library's open, a fresh
    // blank trip at launch) is not an edit and must not be written.
    _ref.listen(currentTripProvider, (_, _) => _changed());
    _ref.listen(currentRosterProvider, (_, _) => _changed());
    _ref.listen(tripBboxProvider, (_, _) => _changed());
  }

  final Ref _ref;
  final Duration _debounce;

  bool _active = false;
  bool _dirty = false;
  Timer? _timer;
  Future<void>? _inFlight;
  Future<void>? _startCheck;

  /// The shell is showing a trip: changes from here on are the Author's.
  /// A trip not in the library yet — every new trip, which creation routes
  /// straight into the shell unsaved — counts as a change from the start,
  /// so it is written without the Author touching anything.
  void start() {
    _active = true;
    _dirty = false;
    state = AutosaveStatus.idle;
    final id = _ref.read(currentTripProvider).id;
    _startCheck = _ref.read(appDatabaseProvider).loadTrip(id).then((row) {
      if (row == null && mounted) _active ? _changed() : _dirty = true;
    }, onError: (Object e) => debugPrint('autosave: could not check for a saved row: $e'));
  }

  /// The shell is going away. Whatever is still pending is written; nothing
  /// after this is, until the next [start].
  Future<void> stop() async {
    _active = false;
    _timer?.cancel();
    await flush();
  }

  void _changed() {
    if (!_active || !mounted) return;
    _dirty = true;
    if (mounted) state = AutosaveStatus.pending;
    _timer?.cancel();
    _timer = Timer(_debounce, () => unawaited(flush()));
  }

  /// Writes any pending change now and waits for it — the Library action
  /// awaits this before it navigates, so leaving never races the write.
  Future<void> flush() async {
    if (_startCheck != null) await _startCheck;
    _timer?.cancel();
    // A write already running finishes first; a change that landed during
    // it is still [_dirty] and gets its own write below. A loop, not one
    // wait: another caller waiting on the same write may start the next one
    // the moment it finishes, and this caller must not return (and the
    // Library action navigate) while that one is still running.
    while (_inFlight != null) {
      await _inFlight;
    }
    // The scope went away under a pending write (the app closing): nothing
    // left to write with.
    if (!_dirty || !mounted) return;
    _dirty = false;
    if (mounted) state = AutosaveStatus.saving;
    final write = _ref.read(tripPersistenceProvider).save(compose: false);
    // What other callers wait on: completes either way, since only this
    // caller reports the outcome.
    final settled = write.then<void>((_) {}, onError: (Object _) {});
    _inFlight = settled;
    try {
      await write;
      if (mounted && !_dirty) state = AutosaveStatus.saved;
    } catch (e) {
      // The detail is for the log (#390: never an exception on screen); the
      // indicator says plainly that this change isn't on disk yet.
      debugPrint('autosave failed: $e');
      _dirty = true;
      if (mounted) state = AutosaveStatus.failed;
    } finally {
      if (identical(_inFlight, settled)) _inFlight = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final tripAutosaveProvider = StateNotifierProvider<TripAutosave, AutosaveStatus>(
  (ref) => TripAutosave(ref),
);
