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

import 'package:flutter/foundation.dart' show listEquals, setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/candidate.dart';
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
  });

  final List<Candidate> candidates;
  final bool loading;
  final String? error;

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
  }) =>
      TripCandidatesState(
        candidates: candidates ?? this.candidates,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
        fetchedFor: fetchedFor ?? this.fetchedFor,
      );

  @override
  bool operator ==(Object other) =>
      other is TripCandidatesState &&
      listEquals(other.candidates, candidates) &&
      other.loading == loading &&
      other.error == error &&
      other.fetchedFor == fetchedFor;

  @override
  int get hashCode => Object.hash(Object.hashAll(candidates), loading, error, fetchedFor);
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
      final candidates = await _ref
          .read(curationClientProvider)
          .candidatesForBbox(bbox: bbox, liveLayers: liveLayers);
      state = state.copyWith(
        candidates: candidates,
        loading: false,
        fetchedFor: CandidateFetchKey(bbox: bbox, liveLayers: liveLayers),
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: e.toString(),
        fetchedFor: CandidateFetchKey(bbox: bbox, liveLayers: liveLayers),
      );
    }
  }
}

final tripCandidatesProvider =
    StateNotifierProvider<TripCandidatesNotifier, TripCandidatesState>(
  TripCandidatesNotifier.new,
);
