// FR78a, FR123 / D4a — Author-side state for the profile-field/permission
// request set and the per-Character response grid it's read against.
//
// **Session-only, not persisted** — same reasoning `trip_authoring_meta_provider.dart`
// documents for party size, and stronger here: there is no roster/invitation
// mechanism yet (FR136/FR137 are `[Later]`), so no real `CharacterResponse`
// can ever reach this app today. Persisting a request set or a response grid
// nothing can populate would be a second storage path with no producer.
// `domain/profile_request.dart`'s doc comment carries the full reasoning.
//
// Reopening a saved trip or restarting the app resets the request set back
// to [FieldRequestSet.defaults] and clears any responses — an accepted
// limitation stated here rather than solved with persistence for a field
// that, per the above, has nothing real to persist yet.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/domain.dart';

class ProfileRequestState {
  ProfileRequestState({
    FieldRequestSet? request,
    this.responses = const [],
  }) : request = request ?? FieldRequestSet.defaults();

  final FieldRequestSet request;
  final List<CharacterResponse> responses;

  ProfileRequestState copyWith({
    FieldRequestSet? request,
    List<CharacterResponse>? responses,
  }) =>
      ProfileRequestState(
        request: request ?? this.request,
        responses: responses ?? this.responses,
      );
}

class ProfileRequestNotifier extends StateNotifier<ProfileRequestState> {
  ProfileRequestNotifier() : super(ProfileRequestState());

  /// A fresh trip (or reopening one) starts from the adjustable default set
  /// again — FR78a's "requesting never auto-grants" means there is nothing
  /// carried over to lose.
  void reset() => state = ProfileRequestState();

  void toggleField(String fieldId) =>
      state = state.copyWith(request: state.request.toggle(fieldId));

  /// Adds a Character to this trip's local roster stub with no response yet
  /// — every one of its fields reads [ConsentStatus.requested] (pending) or
  /// [ConsentStatus.notRequested] until a real response exists. There is no
  /// affordance anywhere in this provider for the Author to directly set a
  /// field to granted/declined on a Character's behalf — FR78's "sharing is
  /// always an explicit Character action" means this app has no honest way
  /// to originate that decision itself; only [recordResponse] (standing in
  /// for K2, the Character-side response flow) can move a field off pending.
  void addCharacter(String name) {
    final id = 'char-${DateTime.now().microsecondsSinceEpoch}-${state.responses.length}';
    state = state.copyWith(responses: [
      ...state.responses,
      CharacterResponse(characterId: id, characterName: name),
    ]);
  }

  void removeCharacter(String characterId) => state = state.copyWith(
        responses: state.responses.where((r) => r.characterId != characterId).toList(),
      );

  /// Stands in for K2 (Character response, not built here) so this provider
  /// and its consuming UI are exercised against real granted/declined/
  /// volunteered data in tests without inventing a second, parallel model —
  /// `resolveCharacterStatuses` is the same function real K2 data would run
  /// through.
  void recordResponse(CharacterResponse response) {
    state = state.copyWith(responses: [
      for (final r in state.responses)
        if (r.characterId == response.characterId) response else r,
    ]);
  }
}

final profileRequestProvider =
    StateNotifierProvider<ProfileRequestNotifier, ProfileRequestState>(
        (ref) => ProfileRequestNotifier());
