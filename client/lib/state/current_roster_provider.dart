// The roster layer for the trip currently open in the planner (FR134–FR136),
// the sibling of `currentTripProvider` for everything that is *not* the
// canonical payload: membership, group assignments, shared gear, meal
// responsibilities, Author notes.
//
// Like `current_trip_provider.dart` this is one notifier for the open trip,
// and like the reveal / character-variant layers a reopened trip rehydrates
// it from storage (`TripPersistence.open`) rather than starting blank. It is
// persisted in its own `Trips.roster` column, beside the payload blob — see
// `domain/roster.dart` and `data/app_database.dart` for why it is not a
// payload field.
//
// The mutation surface here is intentionally small: G2b (#73) needs the
// roster to be *carried, dropped, and rehydrated* correctly, not yet edited
// through a UI. The Character-facing roster runtime is a later story.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/domain.dart';

class CurrentRosterNotifier extends StateNotifier<TripRoster> {
  CurrentRosterNotifier() : super(TripRoster.empty);

  /// Replace the whole roster — used on open, on clone, and by tests. A
  /// trip with no roster column (or an empty one) lands here as
  /// [TripRoster.empty].
  void open(TripRoster roster) => state = roster;

  void reset() => state = TripRoster.empty;
}

final currentRosterProvider =
    StateNotifierProvider<CurrentRosterNotifier, TripRoster>(
        (ref) => CurrentRosterNotifier());
