// Story H6 (issue #80) — Personalize within the Author's bounds (FR6, FR20).
//
// Covers `domain/character_variant.dart`'s pure layer:
//   * Author-variable parameters (FR6 bands) are offered to the Character and
//     movable only inside the Author's own min/max;
//   * parameters the Author pinned (no band) are visible with their canonical
//     value but cannot be moved — the AC's "locked ones visible but fixed";
//   * every operation leaves the canonical `Segment` untouched — the AC's
//     "never alters the Author's canonical route";
//   * choosing an accommodation alternate (FR20) swaps its precomputed
//     metrics in — the AC's "metrics update on toggle".
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';

void main() {
  Segment authoredSegment() => Segment(
        id: 'seg-1',
        mode: 'cycling',
        shape: 'loop',
        start: const [-105.27, 40.02],
        // FR6 — the Author left two realised attributes open for the Character.
        bands: [
          Band(attribute: 'climb_m', min: 200.0, max: 600.0, source: 'author'),
          Band(attribute: 'distance_m', min: 20000.0, max: 30000.0, source: 'author'),
        ],
        metrics: RouteMetrics(
          distanceM: 25000.0,
          climbM: 450.0,
          descentM: 450.0,
          traffic: 0.30,
          scenicFrac: 0.40,
        ),
        alternates: [
          Alternate(
            id: 'alt-bypass',
            kind: 'bypass',
            label: 'Skip the pass',
            geometry: LineString(coordinates: const [
              [-105.27, 40.02],
              [-105.25, 40.03],
            ]),
            metrics: RouteMetrics(distanceM: 21000.0, climbM: 180.0, descentM: 180.0),
            divergesAtM: 8000.0,
            rejoinsAtM: 16000.0,
          ),
          Alternate(
            id: 'alt-extension',
            kind: 'extension',
            label: 'Over the ridge too',
            geometry: LineString(coordinates: const [
              [-105.27, 40.02],
              [-105.21, 40.06],
            ]),
            metrics: RouteMetrics(distanceM: 33000.0, climbM: 900.0, descentM: 900.0),
          ),
        ],
      );

  group('adjustableParameters (FR6) — Author-variable parameters', () {
    test('are exactly the attributes the Author banded, paired with the canonical value', () {
      final params = adjustableParameters(authoredSegment());
      expect(params.map((p) => p.attribute).toSet(), {'climb_m', 'distance_m'});
      final climb = params.firstWhere((p) => p.attribute == 'climb_m');
      expect(climb.min, 200.0);
      expect(climb.max, 600.0);
      expect(climb.canonical, 450.0);
    });

    test('a passage with no Author bands offers the Character nothing to move', () {
      final noBands = Segment(
        id: 's', mode: 'cycling', shape: 'loop', start: const [-105.27, 40.02],
        metrics: RouteMetrics(distanceM: 25000.0, climbM: 450.0),
      );
      expect(adjustableParameters(noBands), isEmpty);
    });
  });

  group('lockedParameters — visible but fixed', () {
    test('are the solved attributes the Author did NOT band', () {
      final locked = lockedParameters(authoredSegment());
      final byAttr = {for (final p in locked) p.attribute: p.value};
      // climb_m and distance_m are banded, so they are adjustable, not locked
      expect(byAttr.containsKey('climb_m'), isFalse);
      expect(byAttr.containsKey('distance_m'), isFalse);
      // traffic / descent / scenic are realised but unbanded → locked, shown
      expect(byAttr['traffic'], 0.30);
      expect(byAttr['descent_m'], 450.0);
      expect(byAttr['scenic_frac'], 0.40);
    });

    test('nothing is locked before the route is solved', () {
      final unsolved = Segment(
        id: 's', mode: 'cycling', shape: 'loop', start: const [-105.27, 40.02],
        bands: [Band(attribute: 'climb_m', min: 200.0)],
      );
      expect(lockedParameters(unsolved), isEmpty);
    });
  });

  group('adjustParameter — Character-adjustable, within the Author\'s bounds', () {
    test('a value inside the band is recorded as-is', () {
      final s = authoredSegment();
      final v = adjustParameter(CharacterVariant(segmentId: s.id), s, 'climb_m', 300.0);
      expect(v.bandTargets['climb_m'], 300.0);
    });

    test('a value past the band is clamped to the Author\'s bound, never beyond', () {
      final s = authoredSegment();
      final tooHard = adjustParameter(CharacterVariant(segmentId: s.id), s, 'climb_m', 5000.0);
      expect(tooHard.bandTargets['climb_m'], 600.0);
      final tooEasy = adjustParameter(CharacterVariant(segmentId: s.id), s, 'climb_m', 0.0);
      expect(tooEasy.bandTargets['climb_m'], 200.0);
    });

    test('a locked (unbanded) attribute cannot be moved — it throws', () {
      final s = authoredSegment();
      expect(
        () => adjustParameter(CharacterVariant(segmentId: s.id), s, 'traffic', 0.1),
        throwsArgumentError,
      );
    });

    test('clearAdjustment returns the parameter to the Author\'s full band', () {
      final s = authoredSegment();
      var v = adjustParameter(CharacterVariant(segmentId: s.id), s, 'climb_m', 300.0);
      v = clearAdjustment(v, 'climb_m');
      expect(v.bandTargets.containsKey('climb_m'), isFalse);
    });
  });

  group('characterBands — a Character-scoped narrowing of the Author\'s constraint set', () {
    test('an adjusted band is tightened to the Character\'s target on both bounded sides', () {
      final s = authoredSegment();
      final v = adjustParameter(CharacterVariant(segmentId: s.id), s, 'climb_m', 300.0);
      final bands = characterBands(s, v);
      final climb = bands.firstWhere((b) => b.attribute == 'climb_m');
      expect(climb.min, 300.0);
      expect(climb.max, 300.0);
      expect(climb.source, 'character');
    });

    test('an unadjusted band is passed through unchanged, still marked author', () {
      final s = authoredSegment();
      final v = adjustParameter(CharacterVariant(segmentId: s.id), s, 'climb_m', 300.0);
      final distance = characterBands(s, v).firstWhere((b) => b.attribute == 'distance_m');
      expect(distance.min, 20000.0);
      expect(distance.max, 30000.0);
      expect(distance.source, 'author');
    });
  });

  group('variantMetrics (FR20) — metrics update on toggle', () {
    test('no choice → the canonical metrics, unchanged', () {
      final s = authoredSegment();
      final m = variantMetrics(s, CharacterVariant(segmentId: s.id));
      expect(m, same(s.metrics));
    });

    test('the bypass alternate swaps in its lighter precomputed metrics', () {
      final s = authoredSegment();
      final v = chooseAlternate(CharacterVariant(segmentId: s.id), s, 'alt-bypass');
      final m = variantMetrics(s, v)!;
      expect(m.distanceM, 21000.0);
      expect(m.climbM, 180.0);
    });

    test('the extension alternate swaps in its heavier metrics', () {
      final s = authoredSegment();
      final v = chooseAlternate(CharacterVariant(segmentId: s.id), s, 'alt-extension');
      expect(variantMetrics(s, v)!.climbM, 900.0);
    });

    test('an unknown alternate id is rejected', () {
      final s = authoredSegment();
      expect(
        () => chooseAlternate(CharacterVariant(segmentId: s.id), s, 'alt-nope'),
        throwsArgumentError,
      );
    });

    test('switching back to the canonical line restores the canonical metrics', () {
      final s = authoredSegment();
      var v = chooseAlternate(CharacterVariant(segmentId: s.id), s, 'alt-bypass');
      v = chooseAlternate(v, s, null);
      expect(variantMetrics(s, v), same(s.metrics));
    });
  });

  group('variantDayDistanceClimb — the day re-rolls with the Character\'s choice', () {
    test('sums canonical metrics when no variant is chosen', () {
      final a = authoredSegment();
      final b = Segment(
        id: 'seg-2', mode: 'cycling', shape: 'loop', start: const [-105.2, 40.0],
        metrics: RouteMetrics(distanceM: 10000.0, climbM: 100.0, descentM: 100.0),
      );
      final rolled = variantDayDistanceClimb([a, b], (_) => null)!;
      expect(rolled.distanceM, 35000.0);
      expect(rolled.climbM, 550.0);
    });

    test('a chosen bypass on one segment lowers the day total', () {
      final a = authoredSegment();
      final b = Segment(
        id: 'seg-2', mode: 'cycling', shape: 'loop', start: const [-105.2, 40.0],
        metrics: RouteMetrics(distanceM: 10000.0, climbM: 100.0, descentM: 100.0),
      );
      final variant = chooseAlternate(CharacterVariant(segmentId: a.id), a, 'alt-bypass');
      final rolled = variantDayDistanceClimb(
        [a, b],
        (id) => id == a.id ? variant : null,
      )!;
      expect(rolled.distanceM, 31000.0); // 21000 + 10000
      expect(rolled.climbM, 280.0); // 180 + 100
    });
  });

  group('never alters the Author\'s canonical route (P8 / ARCH §7.8)', () {
    test('adjusting, choosing an alternate, and re-rolling leave the Segment identical', () {
      final s = authoredSegment();
      final bandsBefore = s.bands.map((b) => '${b.attribute}:${b.min}:${b.max}:${b.source}').toList();
      final metricsBefore = s.metrics!.toJson();
      final alternatesBefore = s.alternates.map((a) => a.id).toList();

      var v = CharacterVariant(segmentId: s.id);
      v = adjustParameter(v, s, 'climb_m', 250.0);
      v = adjustParameter(v, s, 'distance_m', 999999.0); // clamped, not written to canon
      v = chooseAlternate(v, s, 'alt-extension');
      characterBands(s, v);
      variantMetrics(s, v);
      variantDayDistanceClimb([s], (_) => v);

      expect(
        s.bands.map((b) => '${b.attribute}:${b.min}:${b.max}:${b.source}').toList(),
        bandsBefore,
      );
      expect(s.metrics!.toJson(), metricsBefore);
      expect(s.alternates.map((a) => a.id).toList(), alternatesBefore);
      // the variant carries the personal choices; canon carried none to begin with
      expect(v.bandTargets['distance_m'], 30000.0);
      expect(v.chosenAlternateId, 'alt-extension');
    });

    test('needsResolve reflects a band move but not an alternate choice', () {
      final s = authoredSegment();
      expect(CharacterVariant(segmentId: s.id).needsResolve, isFalse);
      expect(chooseAlternate(CharacterVariant(segmentId: s.id), s, 'alt-bypass').needsResolve, isFalse);
      expect(adjustParameter(CharacterVariant(segmentId: s.id), s, 'climb_m', 300.0).needsResolve, isTrue);
    });
  });
}
