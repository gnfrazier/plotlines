// FR4 (Story A3) — the surface weight: paved/gravel/singletrack each independently
// 0.0-5.0 decimal on the Author-facing `WeightProfile.surface` map, mapped onto
// `ThemeWeightProfile.surface_<class>`'s solver-internal -1.0..1.0 bipolar scale by
// `surfaceWeightsFromAuthor` (`weight_profile.dart`) before it goes out over the wire
// (`current_trip_provider.dart`'s `regenerateSegment`). Same shape and conversion as
// `peaksFromClimbing`, applied once per class rather than to a single scalar.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

void main() {
  group('surfaceWeightsFromAuthor', () {
    test('an empty surface map maps to an empty result — no invented weights are '
        'sent for classes the Author never touched', () {
      expect(surfaceWeightsFromAuthor(const {}), isEmpty);
    });

    test('the Author-facing midpoint (2.5, "indifferent") maps to the solver '
        "identity weight (0.0), matching ThemeWeightProfile's own default", () {
      expect(surfaceWeightsFromAuthor(const {'gravel': 2.5}), {'surface_gravel': 0.0});
    });

    test('the bottom of the 0.0-5.0 scale (avoid) maps to full avoidance (-1.0)', () {
      expect(surfaceWeightsFromAuthor(const {'paved': 0.0}), {'surface_paved': -1.0});
    });

    test('the top of the 0.0-5.0 scale (seek) maps to full seek (1.0)', () {
      expect(
        surfaceWeightsFromAuthor(const {'singletrack': 5.0}),
        {'surface_singletrack': 1.0},
      );
    });

    test('decimal precision survives the conversion', () {
      expect(surfaceWeightsFromAuthor(const {'gravel': 4.0})['surface_gravel'],
          closeTo(0.6, 1e-9));
    });

    test('each class converts independently, keyed by surface_<class>, in one call', () {
      expect(
        surfaceWeightsFromAuthor(const {'paved': 0.0, 'gravel': 5.0, 'singletrack': 2.5}),
        {'surface_paved': -1.0, 'surface_gravel': 1.0, 'surface_singletrack': 0.0},
      );
    });

    test('a class absent from the input is absent from the result, not sent as an '
        'invented 0.0 — same omission rule as peaksFromClimbing', () {
      final result = surfaceWeightsFromAuthor(const {'gravel': 5.0});
      expect(result.containsKey('surface_paved'), isFalse);
      expect(result.containsKey('surface_singletrack'), isFalse);
    });

    test('is monotonically increasing across the full 0.0-5.0 range — rising seek '
        'preference never decreases the solver-side weight', () {
      final values = [
        for (var ui = 0.0; ui <= 5.0; ui += 0.5)
          surfaceWeightsFromAuthor({'gravel': ui})['surface_gravel']!,
      ];
      expect(values, [...values]..sort());
    });
  });

  group('WeightProfile.withSurfaceClass', () {
    test('sets one class without disturbing the others', () {
      final w = WeightProfile(name: 'custom', surface: const {'paved': 1.0});
      final updated = w.withSurfaceClass('gravel', 4.0);
      expect(updated.surface, {'paved': 1.0, 'gravel': 4.0});
    });

    test('round-trips through toJson/fromJson with all three classes set', () {
      final w = WeightProfile(
        name: 'custom',
        surface: const {'paved': 0.0, 'gravel': 5.0, 'singletrack': 2.5},
      );
      final decoded = WeightProfile.fromJson(w.toJson());
      expect(decoded.surface, {'paved': 0.0, 'gravel': 5.0, 'singletrack': 2.5});
    });
  });
}
