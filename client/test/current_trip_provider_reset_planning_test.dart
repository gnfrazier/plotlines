// Story K8 (issue #114) — FR81. `CurrentTripNotifier.resetSegmentPlanning`
// is the single reset action: it reverts a passage's planning controls to
// defaults and clears its generated route, and — the hard clause — in
// compose mode it does not discard promoted anchors, roles, or reveal
// settings. Discarding those stays a separate, confirmed action
// (`removeAnchor` behind FR139's orphan prompt).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';

void main() {
  Segment solvedSegment(String id) => Segment(
        id: id,
        mode: 'cycling',
        shape: 'point_to_point',
        start: const [-105.27, 40.02],
        end: const [-105.20, 40.05],
        via: const [
          [-105.24, 40.03],
        ],
        targetDistance: TargetDistance(valueM: 42000, minM: 38000, maxM: 46000),
        bands: [Band(attribute: 'climb_m', max: 600)],
        weights: WeightProfile(name: 'custom', climbing: 3),
        geometry: LineString(coordinates: const [
          [-105.27, 40.02],
          [-105.20, 40.05],
        ]),
        metrics: RouteMetrics(distanceM: 44120),
        elevation: Elevation(ascentM: 720),
        solve: SolveProvenance(solvedAt: '2026-01-01T00:00:00Z'),
        nodes: [
          Node(id: '$id-n1', kind: NodeKind.poi, coord: const [-105.25, 40.03], title: 'Mill'),
        ],
        hazards: [Hazard(id: '$id-h1', severity: 'high', title: 'Cattle guard')],
        arcStage: 'crux',
        note: 'authored prose',
      );

  CurrentTripNotifier openTrip(ProviderContainer c, {List<Anchor> anchors = const []}) {
    final notifier = c.read(currentTripProvider.notifier);
    notifier.open(Trip(
      id: 't1',
      title: 'Test trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      anchors: anchors,
      days: [
        Day(id: 'day-1', index: 1, segments: [solvedSegment('seg-1'), solvedSegment('seg-2')]),
      ],
    ));
    return notifier;
  }

  test('reverts planning controls to defaults and clears the generated route', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    openTrip(c).resetSegmentPlanning('day-1', 'seg-1');

    final seg = c.read(currentTripProvider).days.first.segments.first;
    expect(seg.id, 'seg-1');
    expect(seg.shape, defaultSegmentShape);
    expect(seg.start, isNull);
    expect(seg.end, isNull);
    expect(seg.via, isEmpty);
    expect(seg.targetDistance, isNull);
    expect(seg.bands, isEmpty);
    expect(seg.weights, isNull);
    expect(seg.geometry, isNull);
    expect(seg.metrics, isNull);
    expect(seg.elevation, isNull);
    expect(seg.solve, isNull);
  });

  test('keeps authored content on the passage it reset', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    openTrip(c).resetSegmentPlanning('day-1', 'seg-1');

    final seg = c.read(currentTripProvider).days.first.segments.first;
    expect(seg.nodes.map((n) => n.id), ['seg-1-n1']);
    expect(seg.hazards.map((h) => h.id), ['seg-1-h1']);
    expect(seg.arcStage, 'crux');
    expect(seg.note, 'authored prose');
  });

  test('touches only the targeted passage', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    openTrip(c).resetSegmentPlanning('day-1', 'seg-1');

    final other = c.read(currentTripProvider).days.first.segments[1];
    expect(other.id, 'seg-2');
    expect(other.geometry, isNotNull);
    expect(other.weights, isNotNull);
    expect(other.targetDistance, isNotNull);
  });

  test('in compose mode it does not discard promoted anchors, roles, or reveal', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final anchors = [
      Anchor(
        id: 'anchor-1',
        coord: const [-105.25, 40.03],
        title: 'The old mine',
        roles: [
          Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival),
          Role(id: 'r2', kind: RoleKind.provision, reveal: RevealPolicy.alwaysVisible),
        ],
      ),
    ];
    openTrip(c, anchors: anchors).resetSegmentPlanning('day-1', 'seg-1');

    final kept = c.read(currentTripProvider).anchors;
    expect(kept.length, 1);
    expect(kept.single.id, 'anchor-1');
    expect(kept.single.roles.map((r) => r.id), ['r1', 'r2']);
    expect(kept.single.roles.first.reveal, RevealPolicy.onArrival);
  });

  test('resetting every passage never reaches the anchors — discarding those is separate', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final anchors = [
      Anchor(id: 'a1', coord: const [-105.25, 40.03], roles: [
        Role(id: 'r1', kind: RoleKind.narrative),
      ]),
    ];
    final notifier = openTrip(c, anchors: anchors);
    notifier.resetSegmentPlanning('day-1', 'seg-1');
    notifier.resetSegmentPlanning('day-1', 'seg-2');

    expect(c.read(currentTripProvider).anchors.single.id, 'a1');
  });
}
