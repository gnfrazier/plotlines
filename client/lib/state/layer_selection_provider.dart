// FR97 (Story N3) — which data layers are live for a trip, overridable per
// day. State only; `curation_client.dart`'s `/layers` resolves the
// (mode, day type) default this seeds from, and nothing here computes
// notability or salience (ARCH §4.1 — that stays sidecar-side).
library;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/curation_client.dart';
import 'providers.dart';

class LayerSelectionState {
  const LayerSelectionState({
    this.tripLive = const {},
    this.dayOverrides = const {},
    this.seededFromModes,
  });

  /// The trip-wide live layer set — the picker's baseline every day reads
  /// unless it has its own override.
  final Set<String> tripLive;

  /// FR97's "overridable per day" — a day present here has fully replaced
  /// the trip default, not merged with it, mirroring how `Day.weights`
  /// overrides `Trip.defaultWeights` (C15).
  final Map<String, Set<String>> dayOverrides;

  /// FR144/N0 — the declared-mode set [tripLive] was last (re)seeded from,
  /// so [LayerSelectionNotifier.seedForModes] can tell "the Author changed
  /// which modes this trip declares" (reseed) apart from "the catalog
  /// refetched for some other reason, e.g. switching the active day's day
  /// type" (leave whatever the Author has already set alone). Null before
  /// the first seed.
  final Set<String>? seededFromModes;

  /// The live set a given day actually sees.
  Set<String> liveFor(String? dayId) =>
      dayId != null && dayOverrides.containsKey(dayId) ? dayOverrides[dayId]! : tripLive;

  bool hasOverride(String dayId) => dayOverrides.containsKey(dayId);

  LayerSelectionState copyWith({
    Set<String>? tripLive,
    Map<String, Set<String>>? dayOverrides,
    Set<String>? seededFromModes,
  }) =>
      LayerSelectionState(
        tripLive: tripLive ?? this.tripLive,
        dayOverrides: dayOverrides ?? this.dayOverrides,
        seededFromModes: seededFromModes ?? this.seededFromModes,
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

  /// FR144/N0 — "changing the [declared mode] set updates layer defaults
  /// for days the Author has not overridden." Unlike [seedTripDefaults]
  /// (seed-once, guarded by the caller checking `tripLive.isEmpty`), this
  /// reseeds [tripLive] to [defaults] whenever [modes] itself has actually
  /// changed since the last seed — and is a no-op otherwise, so it can be
  /// called on every build (e.g. from a `FutureProvider` callback) without
  /// clobbering an Author's own trip-wide layer edits every time the active
  /// day (and so the catalog's day-type key) changes. [dayOverrides] is
  /// never touched here — "leaves overridden days alone."
  void seedForModes(Set<String> modes, Set<String> defaults) {
    if (state.seededFromModes != null && setEquals(state.seededFromModes, modes)) return;
    state = state.copyWith(tripLive: defaults, seededFromModes: modes);
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

/// [modes] is a sorted, comma-joined [layerModesKey] string rather than a
/// `Set` — a `FutureProvider.family` key needs value equality to cache
/// correctly, and `Set` only has identity equality, so two callers wanting
/// "the same" modes would never hit the same cache entry or share an
/// in-flight request.
typedef LayerCatalogKey = ({String modes, String dayType});

/// A stable, order-independent family key for [modes] — `{'hiking',
/// 'cycling'}` and `{'cycling', 'hiking'}` must resolve to the same
/// [layerCatalogProvider] entry. Falls back to cycling for an empty set
/// (a pre-N0 saved trip with nothing declared yet — `layers_tab.dart`'s
/// `_effectiveModes` is the other half of that fallback).
String layerModesKey(Set<String> modes) =>
    (modes.isEmpty ? const ['cycling'] : (modes.toList()..sort())).join(',');

/// FR97/FR144 (N3/N0) — the layer catalog, plus the resolved default-live
/// set for this (declared mode set, day type) pair, fetched from the
/// sidecar. A `FutureProvider.family` rather than something
/// `layerSelectionProvider` fetches itself, so a screen can show the
/// catalog's loading/error state independently of the Author's own
/// selection (ARCH §8.3 — layer/POI readiness is per-capability, this is
/// its client-side mirror at the single-call scale).
///
/// The sidecar's `/layers` only resolves one mode at a time (`resolve_
/// default_layers(mode, day_type)`, data-driven config — FR144's build note
/// keeps that file out of scope); a trip declaring more than one mode gets
/// the **union** of each declared mode's default-live set, fetched here
/// rather than invented as a new server contract.
final layerCatalogProvider =
    FutureProvider.family<LayerCatalog, LayerCatalogKey>((ref, key) async {
  final client = ref.watch(curationClientProvider);
  final modes = key.modes.split(',').where((m) => m.isNotEmpty).toList();
  final catalogs = await Future.wait(
    modes.map((mode) => client.layerCatalog(mode: mode, dayType: key.dayType)),
  );
  return unionLayerCatalogs(catalogs);
});

/// The union of each per-mode catalog's `defaultLive`, keyed off the first
/// catalog's `layers`/`rulesetVersion` (identical across every mode's
/// response — the taxonomy doesn't vary by mode, only which of it is live
/// by default). Pure and network-free, split out of [layerCatalogProvider]
/// so it's unit-testable on its own (`layer_selection_provider_test.dart`)
/// — this codebase otherwise has no HTTP-mocked tests for either sidecar
/// client (`curation_client_test.dart`'s own doc comment), which would
/// otherwise leave this story's one piece of real aggregation logic
/// untested.
LayerCatalog unionLayerCatalogs(List<LayerCatalog> catalogs) => LayerCatalog(
      layers: catalogs.first.layers,
      defaultLive: {for (final c in catalogs) ...c.defaultLive},
      rulesetVersion: catalogs.first.rulesetVersion,
    );
