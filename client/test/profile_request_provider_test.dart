// FR78 / FR123 — consent starts closed on every trip. The Author-side
// response grid (`profileRequestProvider`) is session-only and its doc said
// reopening a trip resets it, but nothing ever called `reset()`: a grant
// recorded for a Character on one trip still read as granted after the
// Author started a new trip or opened another. It is now scoped to the open
// trip's id.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/profile_request_provider.dart';

Trip _trip(String id) => Trip(
      id: id,
      title: id,
      createdAt: '2026-09-01T00:00:00Z',
      updatedAt: '2026-09-01T00:00:00Z',
    );

void main() {
  late ProviderContainer container;
  setUp(() {
    container = ProviderContainer();
    container.listen(profileRequestProvider, (_, _) {});
  });
  tearDown(() => container.dispose());

  void grantFirstField() {
    final notifier = container.read(profileRequestProvider.notifier);
    final id = notifier.addCharacter('Ada');
    final field = container.read(profileRequestProvider).request.requestedFieldIds.first;
    notifier.recordResponse(
        CharacterResponse(characterId: id, characterName: 'Ada', grants: {field: true}));
    expect(container.read(profileRequestProvider).responses.single.grants, {field: true});
  }

  test('starting a new trip does not carry the previous trip\'s grants', () {
    grantFirstField();
    container.read(currentTripProvider.notifier).reset();
    expect(container.read(profileRequestProvider).responses, isEmpty);
  });

  test('opening another trip does not carry the previous trip\'s grants', () {
    container.read(currentTripProvider.notifier).open(_trip('a'));
    grantFirstField();
    container.read(currentTripProvider.notifier).open(_trip('b'));
    expect(container.read(profileRequestProvider).responses, isEmpty);
  });

  test('editing the open trip keeps the grid', () {
    grantFirstField();
    container.read(currentTripProvider.notifier).renameTrip('Renamed');
    expect(container.read(profileRequestProvider).responses, hasLength(1));
  });
}
