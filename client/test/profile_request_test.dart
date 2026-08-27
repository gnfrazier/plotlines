// D4a (FR78a, FR123) — `domain/profile_request.dart`'s AC coverage:
//   - the request set is a default set the Author can adjust per trip
//   - the request set includes arrival visibility (a permission) alongside
//     ordinary profile fields, through the same mechanism
//   - requesting never auto-grants (structural, not a UI rule)
//   - the Author sees per Character which fields were granted, declined, or
//     volunteered unprompted
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

void main() {
  group('FieldRequestSet.defaults', () {
    test('starts from the catalog\'s default-in fields only', () {
      final request = FieldRequestSet.defaults();
      for (final f in defaultProfileFieldCatalog) {
        expect(request.isRequested(f.id), f.defaultRequested,
            reason: '${f.id} defaultRequested=${f.defaultRequested}');
      }
    });

    test('arrival visibility (FR123) is in the catalog as a permission, default-out', () {
      final field = defaultProfileFieldCatalog.firstWhere((f) => f.id == 'arrival_visibility');
      expect(field.category, ProfileFieldCategory.permission);
      expect(field.defaultRequested, isFalse);
      // Same mechanism as an ordinary profile field: it is just another
      // catalog entry a request set can toggle.
      final request = FieldRequestSet.defaults().toggle('arrival_visibility');
      expect(request.isRequested('arrival_visibility'), isTrue);
    });
  });

  group('FieldRequestSet.toggle', () {
    test('is an adjustment in either direction, per trip', () {
      final defaults = FieldRequestSet.defaults();
      expect(defaults.isRequested('full_name'), isTrue); // default-in
      final adjusted = defaults.toggle('full_name').toggle('medical_conditions');
      expect(adjusted.isRequested('full_name'), isFalse); // Author removed it
      expect(adjusted.isRequested('medical_conditions'), isTrue); // Author added it
      // The original is untouched (immutable value type).
      expect(defaults.isRequested('full_name'), isTrue);
    });
  });

  group('resolveStatus — requesting never auto-grants', () {
    final request = FieldRequestSet.defaults();

    test('a requested field with no response is pending, not granted', () {
      final response = const CharacterResponse(characterId: 'c1', characterName: 'Bob');
      expect(resolveStatus(request, response, 'full_name'), ConsentStatus.requested);
    });

    test('an unrequested field with no response reads not-requested', () {
      final response = const CharacterResponse(characterId: 'c1', characterName: 'Bob');
      expect(resolveStatus(request, response, 'medical_conditions'), ConsentStatus.notRequested);
    });

    test('an explicit true grant resolves granted', () {
      final response = const CharacterResponse(
        characterId: 'c1',
        characterName: 'Bob',
        grants: {'full_name': true},
      );
      expect(resolveStatus(request, response, 'full_name'), ConsentStatus.granted);
    });

    test('an explicit false grant resolves declined', () {
      final response = const CharacterResponse(
        characterId: 'c1',
        characterName: 'Bob',
        grants: {'phone': false},
      );
      expect(resolveStatus(request, response, 'phone'), ConsentStatus.declined);
    });

    test('a volunteered field resolves volunteered even if never requested', () {
      final response = const CharacterResponse(
        characterId: 'c1',
        characterName: 'Bob',
        volunteeredFieldIds: {'medical_conditions'},
      );
      expect(resolveStatus(request, response, 'medical_conditions'), ConsentStatus.volunteered);
    });

    test('volunteered wins over a request-set entry for the same field', () {
      final response = const CharacterResponse(
        characterId: 'c1',
        characterName: 'Bob',
        grants: {'full_name': false},
        volunteeredFieldIds: {'full_name'},
      );
      expect(resolveStatus(request, response, 'full_name'), ConsentStatus.volunteered);
    });

    test('arrival visibility (FR123) defaults nothing shared even once requested', () {
      final arrivalRequested = request.toggle('arrival_visibility');
      final response = const CharacterResponse(characterId: 'c1', characterName: 'Bob');
      expect(resolveStatus(arrivalRequested, response, 'arrival_visibility'), ConsentStatus.requested);
    });
  });

  group('resolveCharacterStatuses — the Author\'s per-Character view', () {
    test('covers every requested field plus any volunteered extras, nothing else', () {
      final request = FieldRequestSet.defaults(); // full_name, phone, emergency_contact
      final response = const CharacterResponse(
        characterId: 'c1',
        characterName: 'Bob',
        grants: {'full_name': true, 'phone': false},
        volunteeredFieldIds: {'medical_conditions'},
      );
      final statuses = resolveCharacterStatuses(request, response);
      final byId = {for (final s in statuses) s.field.id: s.status};

      expect(byId['full_name'], ConsentStatus.granted);
      expect(byId['phone'], ConsentStatus.declined);
      expect(byId['emergency_contact'], ConsentStatus.requested); // pending, not granted
      expect(byId['medical_conditions'], ConsentStatus.volunteered);
      // Never-requested, never-volunteered fields don't appear at all —
      // nothing to bury and nothing to pad the view with.
      expect(byId.containsKey('vehicle_info'), isFalse);
    });

    test('an ungranted field is distinguishable from one that was never asked', () {
      // D5's framing (FR134) that this domain intentionally keeps clean:
      // "no allergies listed" (not requested) must never render like
      // "didn't tell me about allergies" (requested, still pending).
      final request = FieldRequestSet.defaults().toggle('medical_conditions');
      final response = const CharacterResponse(characterId: 'c1', characterName: 'Bob');
      final statuses = resolveCharacterStatuses(request, response);
      final medical = statuses.firstWhere((s) => s.field.id == 'medical_conditions');
      expect(medical.status, ConsentStatus.requested);
      expect(statuses.any((s) => s.field.id == 'vehicle_info'), isFalse);
    });
  });
}
