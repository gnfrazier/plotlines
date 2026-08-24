// FR97 (Story N3) — which data layers are live for a trip, overridable per
// day. State only; `curation_client.dart`'s `/layers` resolves the
// (mode, day type) default this seeds from, and nothing here computes
// notability or salience (ARCH §4.1 — that stays sidecar-side).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/curation_client.dart';
import 'providers.dart';

class LayerSelectionState {
  const LayerSelectionState({this.tripLive = const {}, this.dayOverrides = const {}});

  /// The trip-wide live layer set — the picker's baseline every day reads
  /// unless it has its own override.
  final Set<String> tripLive;

  /// FR97's "overridable per day" — a day present here has fully replaced
  /// the trip default, not merged with it, mirroring how `Day.weights`
  /// overrides `Trip.defaultWeights` (C15).
  final Map<String, Set<String>> dayOverrides;

  /// The live set a given day actually sees.
  Set<String> liveFor(String? dayId) =>
      dayId != null && dayOverrides.containsKey(dayId) ? dayOverrides[dayId]! : tripLive;

  bool hasOverride(String dayId) => dayOverrides.containsKey(dayId);

  LayerSelectionState copyWith({Set<String>? tripLive, Map<String, Set<String>>? dayOverrides}) =>
      LayerSelectionState(
        tripLive: tripLive ?? this.tripLive,
        dayOverrides: dayOverrides ?? this.dayOverrides,
      );
}

class LayerSelectionNotifier extends StateNotifier<LayerSelectionState> {
  LayerSelectionNotifier() : super(const LayerSelectionState());

  /// Seeds the trip-level live set from `/layers`' resolved default. A
  /// no-op once the Author has made their own selection for this trip —
  /// call [setTripLive] for that, not this.
  void seedTripDefaults(Set<String> defaults) {
    state = state.copyWith(tripLive: defaults);
  }

  void setTripLive(Set<String> layers) {
    state = state.copyWith(tripLive: layers);
  }

  void toggleTripLayer(String layer) {
    final updated = {...state.tripLive};
    updated.contains(layer) ? updated.remove(layer) : updated.add(layer);
    setTripLive(updated);
  }

  /// FR97 — a day's live set, fully overriding the trip default. Seed
  /// [seedLayers] with the current effective set (usually
  /// `state.liveFor(dayId)`) so the override starts from what the Author
  /// was already looking at rather than an empty picker.
  void setDayOverride(String dayId, Set<String> layers) {
    state = state.copyWith(dayOverrides: {...state.dayOverrides, dayId: layers});
  }

  void toggleDayLayer(String dayId, String layer) {
    final current = {...state.liveFor(dayId)};
    current.contains(layer) ? current.remove(layer) : current.add(layer);
    setDayOverride(dayId, current);
  }

  /// Drops a day back to following the trip default.
  void clearDayOverride(String dayId) {
    final overrides = {...state.dayOverrides}..remove(dayId);
    state = state.copyWith(dayOverrides: overrides);
  }
}

final layerSelectionProvider =
    StateNotifierProvider<LayerSelectionNotifier, LayerSelectionState>(
  (ref) => LayerSelectionNotifier(),
);

typedef LayerCatalogKey = ({String mode, String dayType});

/// FR97 — the layer catalog and this (mode, day type)'s resolved default,
/// fetched from the sidecar. A `FutureProvider.family` rather than something
/// `layerSelectionProvider` fetches itself, so a screen can show the
/// catalog's loading/error state independently of the Author's own
/// selection (ARCH §8.3 — layer/POI readiness is per-capability, this is
/// its client-side mirror at the single-call scale).
final layerCatalogProvider =
    FutureProvider.family<LayerCatalog, LayerCatalogKey>((ref, key) {
  final client = ref.watch(curationClientProvider);
  return client.layerCatalog(mode: key.mode, dayType: key.dayType);
});
