// FR9 (Story A6) — `bandViolations`, the synchronous half of A6's AC: "the
// best-effort route and its band violations return with the initial solve."
// Distinct from the async named-conflict-plus-relaxations half
// (`RoutingClient.submitDiagnose`/`pollDiagnose`), which SPIKE-02 measured at
// 1.3-15.0s and cannot sit inside a solve request — this only compares
// numbers a solve already returned against the Author's own bands.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';

void main() {
  group('bandViolations', () {
    test('no metrics yet means nothing to judge', () {
      expect(bandViolations(null, [Band(attribute: 'climb_m', min: 100)]), isEmpty);
    });

    test('no bands means nothing to violate', () {
      final metrics = RouteMetrics(distanceM: 20000, climbM: 50);
      expect(bandViolations(metrics, const []), isEmpty);
    });

    test('a realized value inside its band is not a violation', () {
      final metrics = RouteMetrics(climbM: 300);
      final bands = [Band(attribute: 'climb_m', min: 200, max: 400)];
      expect(bandViolations(metrics, bands), isEmpty);
    });

    test('under the minimum is a violation with a negative shortfall', () {
      final metrics = RouteMetrics(climbM: 210);
      final bands = [Band(attribute: 'climb_m', min: 280)];
      final violations = bandViolations(metrics, bands);
      expect(violations, hasLength(1));
      expect(violations.single.attribute, 'climb_m');
      expect(violations.single.realised, 210);
      expect(violations.single.shortfall, -70);
    });

    test('over the maximum is a violation with a positive shortfall', () {
      final metrics = RouteMetrics(traffic: 0.25);
      final bands = [Band(attribute: 'traffic', max: 0.14)];
      final violations = bandViolations(metrics, bands);
      expect(violations.single.attribute, 'traffic');
      expect(violations.single.shortfall, closeTo(0.11, 1e-9));
    });

    test('names every violated band, not just the first', () {
      final metrics = RouteMetrics(climbM: 100, traffic: 0.4);
      final bands = [
        Band(attribute: 'climb_m', min: 280),
        Band(attribute: 'traffic', max: 0.14),
      ];
      final violations = bandViolations(metrics, bands);
      expect(violations.map((v) => v.attribute).toSet(), {'climb_m', 'traffic'});
    });

    test('never a raw error on an attribute with no matching metric field — '
        'skipped rather than crashing the whole comparison', () {
      final metrics = RouteMetrics(climbM: 50);
      final bands = [Band(attribute: 'not_a_real_attribute', min: 1)];
      expect(() => bandViolations(metrics, bands), returnsNormally);
      expect(bandViolations(metrics, bands), isEmpty);
    });

    test('every attribute band.dart declares bandable is actually readable off RouteMetrics', () {
      final metrics = RouteMetrics(
        distanceM: 1,
        climbM: 2,
        descentM: 3,
        traffic: 0.1,
        unpavedFrac: 0.2,
        scenicFrac: 0.3,
        salience: 0.4,
      );
      for (final attribute in attributeValues) {
        final band = Band(attribute: attribute, max: -1); // guaranteed violated
        final violations = bandViolations(metrics, [band]);
        expect(violations, hasLength(1), reason: '$attribute should be a readable metric');
      }
    });
  });
}
