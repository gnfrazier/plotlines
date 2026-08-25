// FR2 (Story A1) — the "peaks" climbing weight: 0.0-5.0 decimal on the
// Author-facing `WeightProfile.climbing`, mapped onto `ThemeWeightProfile
// .peaks`'s solver-internal -1.0..1.0 bipolar scale by `peaksFromClimbing`
// (`weight_profile.dart`) before it goes out over the wire
// (`current_trip_provider.dart`'s `regenerateSegment`).
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

void main() {
  group('peaksFromClimbing', () {
    test('the Author-facing midpoint (2.5, "indifferent") maps to the '
        'solver-internal identity weight (0.0)', () {
      expect(peaksFromClimbing(2.5), 0.0);
    });

    test('the bottom of the 0.0-5.0 scale maps to full "avoid climbing" (-1.0)', () {
      expect(peaksFromClimbing(0.0), -1.0);
    });

    test('the top of the 0.0-5.0 scale maps to full "seek climbing" (1.0)', () {
      expect(peaksFromClimbing(5.0), 1.0);
    });

    test('decimal precision survives the conversion', () {
      // 3.4, as in the design mockup's "Peaks — climbing" example.
      expect(peaksFromClimbing(3.4), closeTo(0.36, 1e-9));
    });

    test('no authored preference (null) stays null — the solve request omits '
        '`peaks` entirely rather than sending an invented 0.0', () {
      expect(peaksFromClimbing(null), isNull);
    });

    test('is monotonically increasing across the full 0.0-5.0 range', () {
      final values = [for (var ui = 0.0; ui <= 5.0; ui += 0.5) peaksFromClimbing(ui)!];
      expect(values, sorted(values));
    });
  });
}

List<double> sorted(List<double> values) => [...values]..sort();
