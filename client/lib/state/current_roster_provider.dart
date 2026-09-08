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

  /// D4b — register a Character so author-entered values (and, later, notes /
  /// groups) have a subject to hang off. Idempotent on [characterId]; the
  /// Roster tab mirrors every add here so the persisted [TripRoster] — the
  /// thing a clone reads — actually contains the people the tab shows.
  void addEntry(String characterId, String name) {
    if (state.entries.any((e) => e.characterId == characterId)) return;
    state = state.copyWith(entries: [
      ...state.entries,
      RosterEntry(characterId: characterId, name: name),
    ]);
  }

  /// D6a in miniature — dropping a Character drops what the Author holds about
  /// them (their author-entered values and notes), the same rule
  /// [TripRoster.retainingPeople] applies on a clone that sheds people.
  void removeEntry(String characterId) {
    final keep = {
      for (final e in state.entries)
        if (e.characterId != characterId) e.characterId,
    };
    state = state.retainingPeople(keep);
  }

  /// D4b — record or update the Author's own value for one field of one
  /// Character. Bumps `updated_at` to [nowIso]. An empty/blank value clears
  /// the entry instead. This never touches consent: `profile_request.dart`
  /// keeps the request outstanding and the value can never read as `granted`.
  void setAuthorEnteredValue({
    required String characterId,
    required String fieldId,
    required String value,
    required String nowIso,
  }) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      clearAuthorEnteredValue(characterId: characterId, fieldId: fieldId);
      return;
    }
    final others = [
      for (final v in state.authorEnteredValues)
        if (!(v.subjectCharacterId == characterId && v.fieldId == fieldId)) v,
    ];
    state = state.copyWith(authorEnteredValues: [
      ...others,
      AuthorEnteredValue(
        subjectCharacterId: characterId,
        fieldId: fieldId,
        value: trimmed,
        updatedAt: nowIso,
      ),
    ]);
  }

  /// D4b / D6a — the Author clears a value they entered. Also the path a
  /// superseding K2 response would call once real Character responses exist.
  void clearAuthorEnteredValue({
    required String characterId,
    required String fieldId,
  }) {
    state = state.copyWith(authorEnteredValues: [
      for (final v in state.authorEnteredValues)
        if (!(v.subjectCharacterId == characterId && v.fieldId == fieldId)) v,
    ]);
  }
}

final currentRosterProvider =
    StateNotifierProvider<CurrentRosterNotifier, TripRoster>(
        (ref) => CurrentRosterNotifier());
