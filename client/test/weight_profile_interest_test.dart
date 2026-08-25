// FR5 (Story A4) — the "interest" salience-bias weight: a single 0.0-5.0
// decimal on the Author-facing `WeightProfile.interest`, mapped onto
// `ThemeWeightProfile.interest`'s solver-internal 0.0..1.0 scale by
// `interestFromAuthor` (`weight_profile.dart`) before it goes out over the
// wire (`current_trip_provider.dart`'s `regenerateSegment`). Unlike
// `peaksFromClimbing`/`surfaceWeightsFromAuthor`, this is the ordinary
// `w = ui / 5.0` conversion — `interest` is unipolar (ARCH D46: there is no
// "avoid good places" reading), so there is no 2.5 indifference point to
// re-center around.
//
// Also exercises MVP punchlist §2.17b's fail signal directly: the old
// `poi`/`density`/`types`/`detour_budget` shape must be gone, replaced by a
// single scalar with no type parameter.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

void main() {
  group('interestFromAuthor', () {
    test('the bottom of the 0.0-5.0 scale (no bias) maps to 0.0', () {
      expect(interestFromAuthor(0.0), 0.0);
    });

    test('the top of the 0.0-5.0 scale (max bias) maps to 1.0', () {
      expect(interestFromAuthor(5.0), 1.0);
    });

    test('the midpoint is NOT a special "indifferent" value the way it is for '
        'peaks/traffic/surface — interest has no bipolar reading', () {
      expect(interestFromAuthor(2.5), closeTo(0.5, 1e-9));
    });

    test('decimal precision survives the conversion', () {
      expect(interestFromAuthor(1.2), closeTo(0.24, 1e-9));
    });

    test('no authored preference (null) stays null — the solve request omits '
        '`interest` entirely rather than sending an invented 0.0', () {
      expect(interestFromAuthor(null), isNull);
    });

    test('is monotonically increasing across the full 0.0-5.0 range', () {
      final values = [for (var ui = 0.0; ui <= 5.0; ui += 0.5) interestFromAuthor(ui)!];
      expect(values, [...values]..sort());
    });
  });

  group('WeightProfile.interest', () {
    test('round-trips through toJson/fromJson', () {
      final w = WeightProfile(name: 'custom', interest: 3.5);
      final decoded = WeightProfile.fromJson(w.toJson());
      expect(decoded.interest, 3.5);
    });

    test('an unset interest is omitted from toJson rather than sent as 0.0', () {
      final w = WeightProfile(name: 'custom', climbing: 2.5);
      expect(w.toJson().containsKey('interest'), isFalse);
    });

    test('toJson carries no "poi" object and no "detour_budget" — the v1.0 '
        'density-plus-type shape this weight replaces', () {
      final w = WeightProfile(name: 'custom', interest: 4.0);
      final json = w.toJson();
      expect(json.containsKey('poi'), isFalse);
      expect(json.containsKey('detour_budget'), isFalse);
    });
  });

  group('ThemeWeightProfile.interest', () {
    test('defaults to 0.0 (no bias), matching every other unipolar weight\'s '
        'identity value', () {
      const profile = ThemeWeightProfile('custom');
      expect(profile.interest, 0.0);
    });

    test('round-trips through toJson/fromJson', () {
      const profile = ThemeWeightProfile('custom', interest: 0.8);
      final decoded = ThemeWeightProfile.fromJson(profile.toJson());
      expect(decoded.interest, 0.8);
    });
  });
}
