// Story A9a (issue #27) — a loop through three or more via-anchors makes the
// explore-mode target distance advisory (SPIKE-01: distance error rising to
// +30.7% / +81.9% at three vias, every via hit, every loop closed). Covers
// `planner_ui_state.dart`'s pure helpers — `advisoryViaAnchorThreshold`,
// `viaAnchorsMakeDistanceAdvisory`, `targetDistanceForViaCount` — and the
// `Diagnosis` domain fields that carry the deviation back from the sidecar.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/diagnosis.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';

void main() {
  group('viaAnchorsMakeDistanceAdvisory', () {
    test('the threshold is three', () {
      expect(advisoryViaAnchorThreshold, 3);
    });

    test('one or two via-anchors still honour target distance (A9)', () {
      expect(viaAnchorsMakeDistanceAdvisory(0), isFalse);
      expect(viaAnchorsMakeDistanceAdvisory(1), isFalse);
      expect(viaAnchorsMakeDistanceAdvisory(2), isFalse);
    });

    test('three or more make it advisory (A9a)', () {
      expect(viaAnchorsMakeDistanceAdvisory(3), isTrue);
      expect(viaAnchorsMakeDistanceAdvisory(6), isTrue);
    });
  });

  group('targetDistanceForViaCount', () {
    test('below the threshold it is just a banded target, not advisory', () {
      final target = targetDistanceForViaCount(20000.0, 2);
      expect(target.valueM, 20000.0);
      expect(target.minM, 18000.0);
      expect(target.maxM, 22000.0);
      expect(target.advisory, anyOf(isNull, isFalse));
    });

    test('at three via-anchors the band is still reported but marked advisory', () {
      final target = targetDistanceForViaCount(20000.0, 3);
      // band values still carried — A0a / diagnose report the realised
      // distance *against* them
      expect(target.minM, 18000.0);
      expect(target.maxM, 22000.0);
      expect(target.advisory, isTrue);
    });

    test('a wider explicit fraction still bands, and still flips advisory at 3', () {
      final target = targetDistanceForViaCount(20000.0, 4, halfWidthFrac: 0.2);
      expect(target.minM, 16000.0);
      expect(target.maxM, 24000.0);
      expect(target.advisory, isTrue);
    });
  });

  group('Diagnosis carries A9a advisory fields', () {
    // Shaped exactly like `Diagnosis.to_dict()` on the Python side: nullable
    // keys (`via_relaxation`, `best_effort`, and `advisory_deviation` when
    // there is nothing to report) are omitted, never sent as null.
    Map<String, dynamic> baseJson() => {
          'feasible': true,
          'kind': 'advisory',
          'conflict': <String>[],
          'explanation': 'three or more via-anchors fix this loop\'s length',
          'via_implicated': false,
          'distance_advisory': true,
          'advisory_deviation': {
            'realised_m': 26000.0,
            'target_m': 20000.0,
            'distance_error': 0.3,
            'deviates': true,
            'affordances': ['drop_via_anchor', 'move_via_anchor', 'widen_target', 'accept'],
            'relaxation': {
              'metric': 'distance_m',
              'from': 'distance between 18,000 m and 22,000 m',
              'to': 'distance between 18,000 m and 26,000 m',
              'trade_off': 'accepts a realised 26,000 m loop; no other band affected',
              'reached_by': 'balanced',
            },
          },
          'relaxations': <dynamic>[],
          'envelope': <String, dynamic>{},
          'solves': 3,
          'elapsed_ms': 12.0,
        };

    test('fromJson reads distance_advisory and advisory_deviation', () {
      final d = Diagnosis.fromJson(baseJson());
      expect(d.distanceAdvisory, isTrue);
      expect(d.kind, 'advisory');
      expect(d.advisoryDeviation!['deviates'], isTrue);
      expect(d.advisoryDeviation!['relaxation']['metric'], 'distance_m');
    });

    test('round-trips through toJson', () {
      final d = Diagnosis.fromJson(baseJson());
      final round = Diagnosis.fromJson(d.toJson());
      expect(round.distanceAdvisory, isTrue);
      expect(round.advisoryDeviation!['target_m'], 20000.0);
    });

    test('an ordinary diagnosis with the fields absent still parses (default false)', () {
      final json = baseJson()
        ..remove('distance_advisory')
        ..remove('advisory_deviation')
        ..['kind'] = 'none';
      final d = Diagnosis.fromJson(json);
      expect(d.distanceAdvisory, isFalse);
      expect(d.advisoryDeviation, isNull);
    });
  });
}
