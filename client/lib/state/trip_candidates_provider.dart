// FR98/FR99 (Story N3) + issue #316 — the trip's extracted candidate set,
// held in State so it survives navigation between the trip-creation layer
// step (`trip_layers_screen.dart`, where extraction is kicked off once the
// Author settles the live layers) and the Layers tab
// (`plan_tabs/layers_tab.dart`, which reads that warmed result rather than
// only ever fetching on an explicit button press).
//
// Extraction is a bbox-scoped sidecar call (`/candidates`); ARCH §4.1 keeps
// notability scoring sidecar-side, so nothing here computes salience. This
// is only the client-side cache of the last run and its loading/error
// state. `reset()` is called at trip initiation so a new trip never opens
// the workspace showing the previous trip's candidates.
library;

import 'package:flutter/foundation.dart' show listEquals, mapEquals, setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/curation_client.dart' show CurationException;
import '../domain/candidate.dart';
import '../domain/reason_phrase.dart' show looksLikeRawDiagnostic;
import '../domain/trip_bbox.dart';
import 'providers.dart';

/// What [TripCandidatesState.fetchedFor] records — the (extent, live-layer
/// set) a candidate run was made against, so a caller can tell a result
/// that still matches the workspace apart from one the Author has since
/// invalidated by revising the bbox or toggling a layer.
class CandidateFetchKey {
  const CandidateFetchKey({required this.bbox, required this.liveLayers});

  final TripBbox bbox;
  final Set<String> liveLayers;

  bool matches(TripBbox otherBbox, Set<String> otherLayers) =>
      bbox == otherBbox && setEquals(liveLayers, otherLayers);
}

class TripCandidatesState {
  const TripCandidatesState({
    this.candidates = const [],
    this.loading = false,
    this.error,
    this.fetchedFor,
    this.layersServed = const [],
    this.layersUnavailable = const {},
  });

  final List<Candidate> candidates;
  final bool loading;
  final String? error;

  /// #415 — what the last run served and what it could not, straight from
  /// `GET /candidates`. [layersUnavailable] is layer id → wire reason
  /// (`loading` / `failed:<reason>` / `unknown_layer`); the tab maps each
  /// through `unavailableLayerReason` to a bounded cause. Non-empty with a
  /// non-empty [layersServed] is M13's `layersPartiallyServed` (#400);
  /// non-empty with nothing served is `layerExtractionFailed` reached
  /// through a 200 rather than an exception.
  final List<String> layersServed;
  final Map<String, String> layersUnavailable;

  bool get isPartiallyServed => layersUnavailable.isNotEmpty && layersServed.isNotEmpty;
  bool get isTotalFailure => layersUnavailable.isNotEmpty && layersServed.isEmpty;

  /// Null until the first run completes (successfully or not).
  final CandidateFetchKey? fetchedFor;

  /// True once a run has been made for exactly this (bbox, live-layer set).
  bool isCurrentFor(TripBbox bbox, Set<String> liveLayers) =>
      fetchedFor?.matches(bbox, liveLayers) ?? false;

  TripCandidatesState copyWith({
    List<Candidate>? candidates,
    bool? loading,
    String? error,
    bool clearError = false,
    CandidateFetchKey? fetchedFor,
    List<String>? layersServed,
    Map<String, String>? layersUnavailable,
  }) =>
      TripCandidatesState(
        candidates: candidates ?? this.candidates,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
        fetchedFor: fetchedFor ?? this.fetchedFor,
        layersServed: layersServed ?? this.layersServed,
        layersUnavailable: layersUnavailable ?? this.layersUnavailable,
      );

  @override
  bool operator ==(Object other) =>
      other is TripCandidatesState &&
      listEquals(other.candidates, candidates) &&
      other.loading == loading &&
      other.error == error &&
      other.fetchedFor == fetchedFor &&
      listEquals(other.layersServed, layersServed) &&
      mapEquals(other.layersUnavailable, layersUnavailable);

  @override
  int get hashCode => Object.hash(Object.hashAll(candidates), loading, error, fetchedFor,
      Object.hashAll(layersServed), Object.hashAll(layersUnavailable.entries));
}

class TripCandidatesNotifier extends StateNotifier<TripCandidatesState> {
  TripCandidatesNotifier(this._ref) : super(const TripCandidatesState());

  /// Held rather than a resolved `CurationClient` so a sidecar port
  /// transition (which rebuilds [curationClientProvider]) never recreates
  /// this notifier and drops a warmed candidate set — the client is read
  /// fresh per [fetch].
  final Ref _ref;

  void reset() => state = const TripCandidatesState();

  /// Extracts and notability-scores [bbox]'s features against [liveLayers]
  /// (`GET /candidates`). A no-op while a run is already in flight. On
  /// failure the previous candidates are left in place and [state.error] is
  /// set — one broken run never blanks a warmed workspace.
  Future<void> fetch({
    required TripBbox bbox,
    required Set<String> liveLayers,
  }) async {
    if (state.loading) return;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final result = await _ref
          .read(curationClientProvider)
          .candidatesForBbox(bbox: bbox, liveLayers: liveLayers);
      state = state.copyWith(
        candidates: result.candidates,
        loading: false,
        fetchedFor: CandidateFetchKey(bbox: bbox, liveLayers: liveLayers),
        layersServed: result.layersServed,
        layersUnavailable: result.layersUnavailable,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: _errorMessage(e),
        fetchedFor: CandidateFetchKey(bbox: bbox, liveLayers: liveLayers),
      );
    }
  }

  /// #415 — the partial-success state's retry: re-requests **only** the
  /// layers the last run could not serve, against the same bbox, and merges
  /// what comes back into the warmed set. The layers that already served
  /// are not re-fetched — their candidates are on the map and the Author
  /// may be mid-promotion; re-running the whole extraction would cost the
  /// 15.8–178.5 s SPIKE-D measured to recover one layer. A no-op when
  /// nothing is unavailable or a run is in flight.
  Future<void> retryUnavailable() async {
    final key = state.fetchedFor;
    final retry = state.layersUnavailable.keys.toSet();
    if (state.loading || key == null || retry.isEmpty) return;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final result = await _ref
          .read(curationClientProvider)
          .candidatesForBbox(bbox: key.bbox, liveLayers: retry);
      state = state.copyWith(
        candidates: [
          for (final c in state.candidates)
            if (!retry.contains(c.layer)) c,
          ...result.candidates,
        ],
        loading: false,
        layersServed: [...state.layersServed, ...result.layersServed],
        layersUnavailable: result.layersUnavailable,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: _errorMessage(e));
    }
  }
}

/// Issue #496 unwraps `CurationException`'s [CurationException.message]
/// rather than its `toString()` (which prefixes the class name and status
/// code); issue #418 closes the gap that left open — `message` falls back to
/// the raw response body when it isn't `{"detail": …}`, and every other
/// thrown type (`SocketException`, a bare `StateError`) had no unwrapping at
/// all, so its `toString()` reached the screen whole. [looksLikeRawDiagnostic]
/// (#230 B3) is the same guard `sidecar_manager.dart`'s `describe` already
/// applies to a capability's `/health` reason: the sidecar's own honest
/// sentences pass through untouched, and anything shaped like a repr, a
/// traceback, or a host:port is replaced with a fixed phrase — the detail
/// stays in the log, not on `layers_tab.dart`'s shared error surface.
String _errorMessage(Object e) {
  final raw = e is CurationException ? e.message : e.toString();
  return looksLikeRawDiagnostic(raw) ? 'something went wrong finding candidates for this area' : raw;
}

final tripCandidatesProvider =
    StateNotifierProvider<TripCandidatesNotifier, TripCandidatesState>(
  TripCandidatesNotifier.new,
);
