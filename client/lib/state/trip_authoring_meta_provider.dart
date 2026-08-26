// New Route's trip name/dates/party-size fields (wireframe screen 00's step
// 2) — none of these are in `trip_payload.schema.json` (checked: no
// `party_size` anywhere in the schema), so they're kept out of
// `Trip`/`Trip.toJson()` entirely rather than smuggled onto the wire, same
// reasoning as E4's narration-trigger field being authoring-only.
//
// Trip name and dates already have a real schema home (`Trip.title`,
// `Trip.duration`) and are written there directly by New Route — only party
// size lives here.
//
// **Session-only, not persisted.** Reopening a saved trip or restarting the
// app loses this — an accepted limitation stated here rather than solved
// with a silent second storage path alongside the trip payload for a field
// that doesn't affect routing.
//
// Travel modes used to live here too (`primaryModes`/`togglePrimaryMode`)
// but FR144/N0 promoted them to `Trip.declaredModes` — unlike party size,
// modes need to survive for "the life of the trip" (edit, save, reopen),
// which this session-only provider can't offer. See `trip.dart`'s
// `declaredModes` doc comment and `current_trip_provider.dart`'s
// `setDeclaredModes`/`toggleDeclaredMode`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

class TripAuthoringMeta {
  const TripAuthoringMeta({this.partySize});
  final int? partySize;

  TripAuthoringMeta copyWith({int? partySize}) => TripAuthoringMeta(
        partySize: partySize ?? this.partySize,
      );
}

class TripAuthoringMetaNotifier extends StateNotifier<TripAuthoringMeta> {
  TripAuthoringMetaNotifier() : super(const TripAuthoringMeta());

  void reset() => state = const TripAuthoringMeta();

  void setPartySize(int? size) => state = state.copyWith(partySize: size);
}

final tripAuthoringMetaProvider =
    StateNotifierProvider<TripAuthoringMetaNotifier, TripAuthoringMeta>(
        (ref) => TripAuthoringMetaNotifier());
