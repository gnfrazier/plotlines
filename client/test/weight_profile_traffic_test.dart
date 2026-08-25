// FR3 (Story A2) — the "cars" traffic-tolerance weight: 0.0-5.0 decimal on the
// Author-facing `WeightProfile.traffic`, mapped onto `ThemeWeightProfile.quiet`'s
// solver-internal 0.0..1.0 scale by `quietFromTraffic` (`weight_profile.dart`)
// before it goes out over the wire (`current_trip_provider.dart`'s
// `regenerateSegment`). Unlike `peaksFromClimbing`, this is an inversion: low
// tolerance (avoid cars) must produce a *high* quiet-aversion weight.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

void main() {
  group('quietFromTraffic', () {
    test('the Author-facing midpoint (2.5, "indifferent") maps to the solver '
        "default quiet-aversion (0.5), matching ThemeWeightProfile's own default", () {
      expect(quietFromTraffic(2.5), 0.5);
    });

    test('the bottom of the 0.0-5.0 scale (avoid cars / low tolerance) maps to '
        'full quiet-aversion (1.0)', () {
      expect(quietFromTraffic(0.0), 1.0);
    });

    test('the top of the 0.0-5.0 scale (seek cars / high tolerance) maps to no '
        'quiet-aversion (0.0)', () {
      expect(quietFromTraffic(5.0), 0.0);
    });

    test('decimal precision survives the conversion', () {
      // 1.2, as in the design mockup's "Cars — traffic tolerance" example.
      expect(quietFromTraffic(1.2), closeTo(0.76, 1e-9));
    });

    test('no authored preference (null) stays null — the solve request omits '
        '`quiet` entirely rather than sending an invented 0.5', () {
      expect(quietFromTraffic(null), isNull);
    });

    test('is monotonically decreasing across the full 0.0-5.0 range — rising car '
        'tolerance never increases quiet-road aversion', () {
      final values = [for (var ui = 0.0; ui <= 5.0; ui += 0.5) quietFromTraffic(ui)!];
      expect(values, sorted(values, descending: true));
    });
  });
}

List<double> sorted(List<double> values, {bool descending = false}) =>
    [...values]..sort(descending ? (a, b) => b.compareTo(a) : null);
