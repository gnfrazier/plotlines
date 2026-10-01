// The roster layer for the trip currently open in the planner (FR134–FR136),
// the sibling of `currentTripProvider` for everything that is *not* the
// canonical payload: membership, group assignments, the gear checklist, meal
// responsibilities, Author notes.
//
// Like `current_trip_provider.dart` this is one notifier for the open trip,
// and like the reveal / character-variant layers a reopened trip rehydrates
// it from storage (`TripPersistence.open`) rather than starting blank. It is
// persisted in its own `Trips.roster` column, beside the payload blob — see
// `domain/roster.dart` and `data/app_database.dart` for why it is not a
// payload field.
//
// The mutation surface started minimal (G2b / #73 only needed the roster
// carried, dropped, and rehydrated correctly). C8 (#44) adds the gear
// checklist editing surface — `addGearItem` / `updateGearItem` /
// `setGearAssignees` / `removeGearItem`. C9 (#45) adds the same shape for
// group meals — `addMeal` / `updateMeal` / `setMealCooks` / `removeMeal` —
// both driven from the Logistics tab. The Character-facing roster runtime is
// still a later story.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/domain.dart';
import 'authoring_undo_provider.dart';

class CurrentRosterNotifier extends StateNotifier<TripRoster> {
  CurrentRosterNotifier([this._ref]) : super(TripRoster.empty);

  /// Null only for a notifier built outside a container (tests), which then
  /// applies edits directly with no undo history.
  final Ref? _ref;

  /// FR142(a) / K12 — group assignment, membership, gear and meals are
  /// authored work, so each mutation below is one undo step
  /// (`authoring_undo_provider.dart`). Author notes are the exception the
  /// controller enforces on restore (FR135a).
  T _edit<T>(String label, T Function() apply, {String? coalesceKey}) {
    final ref = _ref;
    if (ref == null) return apply();
    return ref.read(authoringUndoProvider.notifier).edit(label, apply, coalesceKey: coalesceKey);
  }

  /// Replace the whole roster — used on open, on clone, and by tests. A
  /// trip with no roster column (or an empty one) lands here as
  /// [TripRoster.empty].
  void open(TripRoster roster) => state = roster;

  void reset() => state = TripRoster.empty;

  /// D4b — register a Character so author-entered values (and, later, notes /
  /// groups) have a subject to hang off. Idempotent on [characterId]; the
  /// Roster tab mirrors every add here so the persisted [TripRoster] — the
  /// thing a clone reads — actually contains the people the tab shows.
  void addEntry(String characterId, String name) =>
      _edit('Add a Character', () {
    if (state.entries.any((e) => e.characterId == characterId)) return;
    state = state.copyWith(entries: [
      ...state.entries,
      RosterEntry(characterId: characterId, name: name),
    ]);
  });

  /// D6a in miniature — dropping a Character drops what the Author holds about
  /// them (their author-entered values and notes), the same rule
  /// [TripRoster.retainingPeople] applies on a clone that sheds people. Also
  /// strips them from any Shared Group Gear line (C8) and drops a line left
  /// with nobody on it.
  void removeEntry(String characterId) =>
      _edit('Remove a Character', () {
    final keep = {
      for (final e in state.entries)
        if (e.characterId != characterId) e.characterId,
    };
    state = state.retainingPeople(keep);
  });

  // ---- C8 (FR24) — the gear checklist -------------------------------------

  /// Append a gear line. [id] is the caller's to generate (kept out of here
  /// so the notifier stays clock- and id-free, like the rest of this class).
  void addGearItem(GearItem item) =>
      _edit('Add a gear line', () {
    if (state.gear.any((g) => g.id == item.id)) return;
    state = state.copyWith(gear: [...state.gear, item]);
  });

  /// Edit one line in place — label, scope, necessity, or the Shared Group
  /// Gear flag. Turning [shared] off also clears the assignees, since a
  /// personal-list line is not carried by anyone in particular.
  void updateGearItem(
    String id, {
    String? label,
    GearScope? scope,
    GearNecessity? necessity,
    bool? shared,
  }) =>
      _edit('Edit a gear line', () {
    state = state.copyWith(gear: [
      for (final g in state.gear)
        if (g.id == id)
          g.copyWith(
            label: label,
            scope: scope,
            necessity: necessity,
            shared: shared,
            assigneeIds: shared == false ? const {} : null,
          )
        else
          g,
    ]);
  }, coalesceKey: 'gear:$id');

  /// Set who carries a Shared Group Gear line. A no-op on a line that is not
  /// [GearItem.shared] — assignment only means something for shared gear.
  void setGearAssignees(String id, Set<String> assigneeIds) =>
      _edit('Change who carries gear', () {
    state = state.copyWith(gear: [
      for (final g in state.gear)
        if (g.id == id && g.shared) g.withAssignees(assigneeIds) else g,
    ]);
  });

  void removeGearItem(String id) =>
      _edit('Remove a gear line', () {
    state = state.copyWith(gear: [
      for (final g in state.gear)
        if (g.id != id) g,
    ]);
  });

  // ---- C9 (FR25) — group meals ---------------------------------------------

  /// Append a group meal. [id] is the caller's to generate, like [addGearItem].
  void addMeal(MealResponsibility meal) =>
      _edit('Add a group meal', () {
    if (state.meals.any((m) => m.id == meal.id)) return;
    state = state.copyWith(meals: [...state.meals, meal]);
  });

  /// Edit one meal's label or day pin in place — `cookIds` is
  /// [setMealCooks]'s job, mirroring [setGearAssignees].
  void updateMeal(String id, {String? label, String? dayId, bool clearDayId = false}) =>
      _edit('Edit a group meal', () {
    state = state.copyWith(meals: [
      for (final m in state.meals)
        if (m.id == id)
          MealResponsibility(
            id: m.id,
            label: label ?? m.label,
            dayId: clearDayId ? null : (dayId ?? m.dayId),
            cookIds: m.cookIds,
          )
        else
          m,
    ]);
  }, coalesceKey: 'meal:$id');

  /// Set who carries a group meal — mirrors [setGearAssignees].
  void setMealCooks(String id, Set<String> cookIds) =>
      _edit('Change who cooks', () {
    state = state.copyWith(meals: [
      for (final m in state.meals)
        if (m.id == id) m.withCooks(cookIds) else m,
    ]);
  });

  void removeMeal(String id) =>
      _edit('Remove a group meal', () {
    state = state.copyWith(meals: [
      for (final m in state.meals)
        if (m.id != id) m,
    ]);
  });

  /// D4b — record or update the Author's own value for one field of one
  /// Character. Bumps `updated_at` to [nowIso]. An empty/blank value clears
  /// the entry instead. This never touches consent: `profile_request.dart`
  /// keeps the request outstanding and the value can never read as `granted`.
  void setAuthorEnteredValue({
    required String characterId,
    required String fieldId,
    required String value,
    required String nowIso,
  }) =>
      _edit('Edit a Character field', () {
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
  }, coalesceKey: 'author-value:$characterId:$fieldId');

  /// D4b / D6a — the Author clears a value they entered. Also the path a
  /// superseding K2 response would call once real Character responses exist.
  void clearAuthorEnteredValue({
    required String characterId,
    required String fieldId,
  }) =>
      _edit('Clear a Character field', () {
    state = state.copyWith(authorEnteredValues: [
      for (final v in state.authorEnteredValues)
        if (!(v.subjectCharacterId == characterId && v.fieldId == fieldId)) v,
    ]);
  });
}

final currentRosterProvider =
    StateNotifierProvider<CurrentRosterNotifier, TripRoster>(
        (ref) => CurrentRosterNotifier(ref));
