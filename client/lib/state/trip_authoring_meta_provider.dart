// New Route's trip name/dates/party-size/primary-modes fields (wireframe
// screen 00's step 2) — none of these are in `trip_payload.schema.json`
// (checked: no `party_size` or trip-level `primary_modes` anywhere in the
// schema), so they're kept out of `Trip`/`Trip.toJson()` entirely rather
// than smuggled onto the wire, same reasoning as E4's narration-trigger
// field being authoring-only.
//
// Trip name and dates already have a real schema home (`Trip.title`,
// `Trip.duration`) and are written there directly by New Route — only
// party size and primary modes live here.
//
// **Session-only, not persisted.** Reopening a saved trip or restarting the
// app loses these — an accepted limitation stated here rather than solved
// with a silent second storage path alongside the trip payload for two
// fields that don't affect routing.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

class TripAuthoringMeta {
  const TripAuthoringMeta({this.partySize, this.primaryModes = const {}});
  final int? partySize;
  final Set<String> primaryModes;

  TripAuthoringMeta copyWith({int? partySize, Set<String>? primaryModes}) => TripAuthoringMeta(
        partySize: partySize ?? this.partySize,
        primaryModes: primaryModes ?? this.primaryModes,
      );
}

class TripAuthoringMetaNotifier extends StateNotifier<TripAuthoringMeta> {
  TripAuthoringMetaNotifier() : super(const TripAuthoringMeta());

  void reset() => state = const TripAuthoringMeta();

  void setPartySize(int? size) => state = state.copyWith(partySize: size);

  void togglePrimaryMode(String mode) {
    final modes = {...state.primaryModes};
    modes.contains(mode) ? modes.remove(mode) : modes.add(mode);
    state = state.copyWith(primaryModes: modes);
  }
}

final tripAuthoringMetaProvider =
    StateNotifierProvider<TripAuthoringMetaNotifier, TripAuthoringMeta>(
        (ref) => TripAuthoringMetaNotifier());
