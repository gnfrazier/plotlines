// Story K8 (issue #114) — FR81. The single reset reverts planning controls
// (shape, start, destination, distance, weights) to defaults and clears the
// generated route, without discarding anything the Author authored on the
// passage. Covers `planner_ui_state.dart`'s `resetSegmentPlanningControls`,
// `segmentHasResettablePlanning`, and `defaultRouteTheme`.
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';

void main() {
  Segment solvedSegment() => Segment(
        id: 'seg-1',
        title: 'The river run',
        mode: 'paddling',
        shape: 'point_to_point',
        start: const [-105.27, 40.02],
        end: const [-105.20, 40.05],
        via: const [
          [-105.24, 40.03],
        ],
        targetDistance: TargetDistance(valueM: 42000, minM: 38000, maxM: 46000),
        bands: [Band(attribute: 'climb_m', max: 600)],
        violations: [Violation(attribute: 'climb_m', realised: 720, shortfall: 120)],
        weights: WeightProfile(name: 'custom', climbing: 3, traffic: 4),
        geometry: LineString(coordinates: const [
          [-105.27, 40.02],
          [-105.20, 40.05],
        ]),
        metrics: RouteMetrics(distanceM: 44120, climbM: 720),
        elevation: Elevation(ascentM: 720, descentM: 300),
        solve: SolveProvenance(solvedAt: '2026-01-01T00:00:00Z'),
        nodes: [
          Node(id: 'n1', kind: NodeKind.poi, coord: const [-105.25, 40.03], title: 'Old mill'),
        ],
        hazards: [Hazard(id: 'h1', severity: 'high', title: 'Weir')],
        portages: [
          Portage(
            id: 'p1',
            geometry: LineString(
              coordinates: const [
                [-105.25, 40.03],
                [-105.25, 40.031],
              ],
              source: 'authored',
            ),
          ),
        ],
        arcStage: 'crux',
        note: 'Scout the weir from river-left before committing.',
        media: [MediaRef(id: 'm1', kind: 'photo', path: 'weir.jpg')],
      );

  group('defaultRouteTheme', () {
    test('is balanced', () => expect(defaultRouteTheme, 'balanced'));
  });

  group('resetSegmentPlanningControls', () {
    test('reverts shape, start, destination, distance and weights to defaults', () {
      final r = resetSegmentPlanningControls(solvedSegment());
      expect(r.shape, defaultSegmentShape);
      expect(r.start, isNull);
      expect(r.end, isNull);
      expect(r.via, isEmpty);
      expect(r.targetDistance, isNull);
      expect(r.bands, isEmpty);
      expect(r.violations, isEmpty);
      expect(r.weights, isNull);
    });

    test('clears the generated route (geometry, metrics, elevation, solve)', () {
      final r = resetSegmentPlanningControls(solvedSegment());
      expect(r.geometry, isNull);
      expect(r.metrics, isNull);
      expect(r.elevation, isNull);
      expect(r.solve, isNull);
    });

    test('keeps the passage identity so transitions and node ownership resolve', () {
      final r = resetSegmentPlanningControls(solvedSegment());
      expect(r.id, 'seg-1');
      expect(r.title, 'The river run');
      expect(r.mode, 'paddling');
    });

    test('spares everything the Author authored on the passage', () {
      final r = resetSegmentPlanningControls(solvedSegment());
      expect(r.nodes.map((n) => n.id), ['n1']);
      expect(r.hazards.map((h) => h.id), ['h1']);
      expect(r.portages.map((p) => p.id), ['p1']);
      expect(r.arcStage, 'crux');
      expect(r.note, 'Scout the weir from river-left before committing.');
      expect(r.media.map((m) => m.id), ['m1']);
    });

    test('is idempotent — resetting an already-default segment changes nothing', () {
      final bare = Segment(id: 's', mode: 'cycling', shape: defaultSegmentShape);
      final r = resetSegmentPlanningControls(bare);
      expect(r.toJson(), bare.toJson());
    });
  });

  group('segmentHasResettablePlanning', () {
    test('false for a bare default segment', () {
      expect(
        segmentHasResettablePlanning(
          Segment(id: 's', mode: 'cycling', shape: defaultSegmentShape),
        ),
        isFalse,
      );
    });

    test('true once anything has been planned or solved', () {
      expect(segmentHasResettablePlanning(solvedSegment()), isTrue);
    });

    test('true for a non-default shape alone', () {
      expect(
        segmentHasResettablePlanning(
          Segment(id: 's', mode: 'cycling', shape: 'point_to_point'),
        ),
        isTrue,
      );
    });

    test('authored content alone does not make it resettable', () {
      final authoredOnly = Segment(
        id: 's',
        mode: 'cycling',
        shape: defaultSegmentShape,
        hazards: [Hazard(id: 'h', severity: 'caution')],
        note: 'watch the gravel',
        arcStage: 'rising',
      );
      expect(segmentHasResettablePlanning(authoredOnly), isFalse);
    });
  });
}
