// Issue #410 — a promoted Anchor was never drawn on any map. `Trip.anchors`
// reached cards, dropdowns and lookups but no marker: promotion (FR106/FR110's
// "editorial moment") changed nothing on the surface an Author looks at most.
//
// The fix has one seam: `anchorMapPoints` turns `Trip.anchors` into typed
// `MapAnchorPoint`s, and `TapToPickMap` (Route/Content tabs) and
// `CandidateMap` (Layers tab) each draw one `AnchorMarker` per point. On
// `CandidateMap` the candidate an anchor was promoted from is retired, so
// promotion visibly replaces the mark rather than stacking canon on cache.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/candidate.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/map/anchor_map_points.dart';
import 'package:plotlines_client/presentation/map/candidate_map.dart';
import 'package:plotlines_client/presentation/map/tap_to_pick_map.dart';
import 'package:plotlines_client/state/providers.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Widget _wrap(Widget child) => ProviderScope(
      overrides: [sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager())],
      child: MaterialApp(home: Scaffold(body: child)),
    );

Anchor _anchor({
  String id = 'a1',
  Coord coord = const [-105.27, 40.02],
  String? title = 'Old Fort',
  List<RoleKind> kinds = const [RoleKind.narrative],
  AnchorProvenance? provenance,
  Area? area,
}) =>
    Anchor(
      id: id,
      coord: coord,
      title: title,
      area: area,
      roles: [for (final k in kinds) Role(id: '$id-${k.wireValue}', kind: k)],
      provenance: provenance,
    );

void main() {
  group('anchorMarkFor', () {
    test('one role keeps the shape its candidate affinity had', () {
      expect(anchorMarkFor(_anchor(kinds: [RoleKind.narrative])), AnchorMarkerMark.narrative);
      expect(anchorMarkFor(_anchor(kinds: [RoleKind.provision])), AnchorMarkerMark.provision);
      expect(anchorMarkFor(_anchor(kinds: [RoleKind.station])), AnchorMarkerMark.station);
    });

    test('several role kinds draw the star', () {
      expect(
        anchorMarkFor(_anchor(kinds: [RoleKind.narrative, RoleKind.station])),
        AnchorMarkerMark.multiRole,
      );
    });

    test('two roles of one kind are still one kind of place', () {
      final a = Anchor(
        id: 'a',
        coord: const [0, 0],
        roles: [
          Role(id: 'r1', kind: RoleKind.provision),
          Role(id: 'r2', kind: RoleKind.provision),
        ],
      );
      expect(anchorMarkFor(a), AnchorMarkerMark.provision);
    });
  });

  group('anchorMapPoints', () {
    test('one point per anchor, at the anchor\'s own coord', () {
      final points = anchorMapPoints([
        _anchor(id: 'a1', coord: const [-105.1, 40.1]),
        _anchor(id: 'a2', coord: const [-105.2, 40.2], title: null),
      ]);
      expect(points, hasLength(2));
      expect(points[0].coord, [-105.1, 40.1]);
      expect(points[1].coord, [-105.2, 40.2]);
    });

    test('the label names the anchor and its role kinds', () {
      final points = anchorMapPoints([
        _anchor(kinds: [RoleKind.narrative, RoleKind.station]),
        _anchor(id: 'a2', title: null, kinds: [RoleKind.provision]),
      ]);
      expect(points[0].label, 'Old Fort — anchor · narrative + station');
      expect(points[1].label, 'Anchor — anchor · provision');
    });

    test('carries the source candidate id so a candidate map can retire it', () {
      final points = anchorMapPoints([
        _anchor(
          provenance: const AnchorProvenance(
              kind: AnchorSourceKind.candidate, sourceId: 'c1', layer: 'historic'),
        ),
        _anchor(id: 'hp', provenance: const AnchorProvenance(kind: AnchorSourceKind.handPlaced)),
      ]);
      expect(points[0].sourceId, 'c1');
      expect(points[1].sourceId, isNull);
    });

    // FR108 / O3 — an area anchor still carries a representative coord; it
    // is marked there. Its boundary rides along as `rings` for
    // `AnchorAreaLayer` (#484, `anchor_area_layer_test.dart`).
    test('an area anchor is marked at its representative point', () {
      final ring = [
        [-105.0, 40.0], [-105.0, 40.1], [-104.9, 40.1], [-105.0, 40.0],
      ];
      final points = anchorMapPoints([
        _anchor(
          coord: const [-104.95, 40.05],
          area: Area(rings: [ring], source: AreaSource.authored),
        ),
      ]);
      expect(points.single.coord, [-104.95, 40.05]);
    });

    // FR107 / O2 — a role offset is the role's trigger position, not the
    // place; the anchor is drawn once, at its own coord.
    test('a role offset does not add a second mark', () {
      final a = Anchor(
        id: 'a',
        coord: const [-105.0, 40.0],
        roles: [
          Role(id: 'r', kind: RoleKind.narrative, coord: const [-105.004, 40.003]),
        ],
      );
      final points = anchorMapPoints([a]);
      expect(points, hasLength(1));
      expect(points.single.coord, [-105.0, 40.0]);
    });
  });

  group('unpromotedCandidates', () {
    const c1 = Candidate(
        id: 'c1', coord: [-105.27, 40.02], layer: 'historic', salience: 0.8,
        roleAffinity: RoleAffinity.narrative, title: 'Old Fort');
    const c2 = Candidate(
        id: 'c2', coord: [-105.28, 40.03], layer: 'water', salience: 0.4,
        roleAffinity: RoleAffinity.provision, title: 'Spring');

    test('with nothing promoted every candidate is drawn', () {
      expect(unpromotedCandidates([c1, c2], const [], const []), [c1, c2]);
    });

    test('a candidate promoted to an anchor is retired by source id', () {
      final anchors = anchorMapPoints([
        _anchor(
          coord: const [-100.0, 30.0], // a proposal's centroid, not c1's coord
          provenance: const AnchorProvenance(
              kind: AnchorSourceKind.candidate, sourceId: 'c1', layer: 'historic'),
        ),
      ]);
      expect(unpromotedCandidates([c1, c2], anchors, const []), [c2]);
    });

    test('a hand-placed anchor retires nothing', () {
      final anchors = anchorMapPoints([
        _anchor(coord: c1.coord, provenance: const AnchorProvenance(kind: AnchorSourceKind.handPlaced)),
      ]);
      expect(unpromotedCandidates([c1, c2], anchors, const []), [c1, c2]);
    });

    // A day-scoped `Node` at a candidate's exact coord (e.g. the lodging
    // path, `logistics_tab.dart`'s `promoteCandidate` — #477 moved the
    // Layers tab's own tap-to-promote off this mechanism onto an anchor)
    // still retires the candidate the same way.
    test('a candidate promoted to a node is retired by exact coord', () {
      const nodes = <MapMarkerPoint>[
        (coord: [-105.28, 40.03], role: NodeMarkerType.plot, arcStage: null),
      ];
      expect(unpromotedCandidates([c1, c2], const [], nodes), [c1]);
    });
  });

  group('TapToPickMap', () {
    testWidgets('draws one AnchorMarker per anchor, with the role-set mark', (tester) async {
      await tester.pumpWidget(_wrap(TapToPickMap(
        anchors: anchorMapPoints([
          _anchor(id: 'a1', coord: const [-105.001, 40.001], kinds: [RoleKind.provision]),
          _anchor(id: 'a2', coord: const [-105.002, 40.002], title: 'Both',
              kinds: [RoleKind.narrative, RoleKind.station]),
        ]),
        center: const [-105.0, 40.0],
      )));
      await _settle(tester);

      final marks = tester
          .widgetList<AnchorMarker>(find.byType(AnchorMarker))
          .map((m) => m.mark)
          .toList();
      expect(marks, [AnchorMarkerMark.provision, AnchorMarkerMark.multiRole]);
      expect(find.byTooltip('Old Fort — anchor · provision'), findsOneWidget);
      expect(find.byTooltip('Both — anchor · narrative + station'), findsOneWidget);
    });

    testWidgets('anchors draw beside node points, never instead of them', (tester) async {
      await tester.pumpWidget(_wrap(TapToPickMap(
        points: const [
          (coord: [-105.0, 40.0], role: NodeMarkerType.start, arcStage: null),
        ],
        anchors: anchorMapPoints([_anchor(coord: const [-105.001, 40.001])]),
        center: const [-105.0, 40.0],
      )));
      await _settle(tester);
      expect(find.byType(NodeMarker), findsOneWidget);
      expect(find.byType(AnchorMarker), findsOneWidget);
    });

    testWidgets('no anchors, no anchor layer', (tester) async {
      await tester.pumpWidget(_wrap(const TapToPickMap(center: [-105.0, 40.0])));
      await _settle(tester);
      expect(find.byType(AnchorMarker), findsNothing);
    });
  });

  group('CandidateMap', () {
    const candidate = Candidate(
        id: 'c1', coord: [-105.27, 40.02], layer: 'historic', salience: 0.8,
        roleAffinity: RoleAffinity.narrative, title: 'Old Fort');
    const other = Candidate(
        id: 'c2', coord: [-105.28, 40.03], layer: 'water', salience: 0.4,
        roleAffinity: RoleAffinity.provision, title: 'Spring');

    testWidgets('a promoted candidate\'s pin becomes an anchor mark', (tester) async {
      final anchors = anchorMapPoints([
        _anchor(
          coord: candidate.coord,
          provenance: const AnchorProvenance(
              kind: AnchorSourceKind.candidate, sourceId: 'c1', layer: 'historic'),
        ),
      ]);
      Candidate? tapped;
      await tester.pumpWidget(_wrap(CandidateMap(
        candidates: const [candidate, other],
        anchors: anchors,
        onCandidateTap: (c) => tapped = c,
      )));
      await _settle(tester);

      // One candidate marker left (Spring), one anchor mark (Old Fort).
      expect(find.byType(CandidateMarker), findsOneWidget);
      expect(find.byType(AnchorMarker), findsOneWidget);
      expect(find.byTooltip('Spring'), findsOneWidget);
      expect(find.byTooltip('Old Fort'), findsNothing,
          reason: 'the candidate pin is retired, not drawn under the anchor');
      expect(find.byTooltip('Old Fort — anchor · narrative'), findsOneWidget);

      // The anchor mark is not a promotion target — tapping it must not
      // report the retired candidate (which would only re-promote and throw).
      await tester.tap(find.byType(AnchorMarker));
      await tester.pump();
      expect(tapped, isNull);
      // A tap on a Tooltip shows it for a while; let that timer run out so
      // the harness's pending-timer check is about the map, not the tip.
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a hand-placed anchor draws at its own coord and retires no pin',
        (tester) async {
      await tester.pumpWidget(_wrap(CandidateMap(
        candidates: const [candidate],
        anchors: anchorMapPoints([
          _anchor(
            coord: const [-105.26, 40.01],
            title: 'Hand-placed',
            provenance: const AnchorProvenance(kind: AnchorSourceKind.handPlaced),
          ),
        ]),
      )));
      await _settle(tester);
      expect(find.byType(CandidateMarker), findsOneWidget);
      expect(find.byType(AnchorMarker), findsOneWidget);
    });

    // A day-scoped node from any producer (lodging, since #477 moved the
    // Layers tab's own tap onto an anchor instead) draws as the Route tab
    // draws it, and the candidate it copied its coord from is retired.
    testWidgets('a promoted day node draws as a NodeMarker and retires the pin',
        (tester) async {
      await tester.pumpWidget(_wrap(CandidateMap(
        candidates: const [candidate, other],
        nodes: const [
          (coord: [-105.27, 40.02], role: NodeMarkerType.plot, arcStage: null),
        ],
      )));
      await _settle(tester);
      expect(find.byType(CandidateMarker), findsOneWidget);
      expect(find.byTooltip('Old Fort'), findsNothing);
      final node = tester.widget<NodeMarker>(find.byType(NodeMarker));
      expect(node.type, NodeMarkerType.plot);
    });
  });
}
