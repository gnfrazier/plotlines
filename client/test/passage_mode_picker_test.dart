// Issue #319 — `passageModesOffered`: the pure half of `PassageModePicker`.
// The picker never offers a mode the trip does not have, keeps the canonical
// list order rather than the set's, restricts to what the surface may
// offer (a generated route cannot be `transit`), and always includes an
// existing passage's own mode so nothing renders unselected.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/travel_mode.dart';
import 'package:plotlines_client/presentation/widgets/passage_mode_picker.dart';

void main() {
  test('is the trip set filtered to the offerable list, in canonical order', () {
    expect(passageModesOffered({'hiking', 'cycling'}), ['cycling', 'hiking']);
    expect(passageModesOffered({'driving', 'paddling', 'cycling'}),
        ['cycling', 'paddling', 'driving']);
  });

  test('never offers a mode the trip lacks', () {
    expect(passageModesOffered({'cycling'}), ['cycling']);
    expect(passageModesOffered(const {}), isEmpty);
  });

  test('the default offerable list is the traversal list — transit is never generated', () {
    expect(passageModesOffered({'cycling', 'transit'}), ['cycling']);
    expect(passageModesOffered({'cycling', 'transit'}, offerable: kTravelModes),
        ['cycling', 'transit']);
  });

  test('an existing passage\'s own mode is always offered', () {
    expect(passageModesOffered({'cycling'}, current: 'driving'), ['cycling', 'driving']);
    // …but only if the surface may offer it at all.
    expect(passageModesOffered({'cycling'}, current: 'transit'), ['cycling']);
    expect(passageModesOffered({'cycling'}, current: 'transit', offerable: kTravelModes),
        ['cycling', 'transit']);
  });

  test('a plugin mode this build has never heard of is not offered', () {
    // Not in `kTravelModes`, so no label/icon/network type exists for it.
    expect(passageModesOffered({'cycling', 'horseback'}), ['cycling']);
  });
}
