// Issue #484 (FR108 / O3) — an area anchor's boundary is drawn on both
// planning maps. Before this, `anchorMapPoints` carried only the
// representative point, so a promoted district was a diamond; on
// `CandidateMap` it was worse, because promotion retired the candidate whose
// ring (#475) had been drawn, and the ring went with it.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/candidate.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/promote.dart';
import 'package:plotlines_client/presentation/map/anchor_area_layer.dart';
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

// A ~2 km square around Boulder, closed ring — reads as an area at z13.
const _districtRing = [
  [-105.28, 40.01],
  [-105.26, 40.01],
  [-105.26, 40.03],
  [-105.28, 40.03],
  [-105.28, 40.01],
];

const _holeRing = [
  [-105.275, 40.015],
  [-105.265, 40.015],
  [-105.265, 40.025],
  [-105.275, 40.025],
  [-105.275, 40.015],
];

MapAnchorPoint _point({String id = 'p', List<List<List<double>>>? rings}) => (
      coord: [-105.27, 40.02],
      label: '$id — anchor · narrative',
      mark: AnchorMarkerMark.narrative,
      sourceId: null,
      rings: rings,
    );

Offset Function(ll.LatLng) _projectAt({required double pxPerDegree}) =>
    (p) => Offset(p.longitude * pxPerDegree, -p.latitude * pxPerDegree);

Anchor _areaAnchor({String id = 'a1', String title = 'Old Town', List<Ring>? rings}) => Anchor(
      id: id,
      coord: const [-105.27, 40.02],
      title: title,
      area: Area(rings: rings ?? [_districtRing], source: AreaSource.authored),
      roles: [Role(id: '$id-n', kind: RoleKind.narrative)],
    );

List<Polygon> _polygons(WidgetTester tester) => tester
    .widgetList<PolygonLayer>(find.descendant(
      of: find.byType(AnchorAreaLayer),
      matching: find.byType(PolygonLayer),
    ))
    .expand((l) => l.polygons)
    .toList();

void main() {
  group('anchorMapPoints carries the area', () {
    test('an area anchor\'s rings ride with its point', () {
      final points = anchorMapPoints([_areaAnchor(rings: [_districtRing, _holeRing])]);
      expect(points.single.rings, [_districtRing, _holeRing]);
    });

    test('a point anchor carries no rings', () {
      final a = Anchor(
        id: 'p',
        coord: const [-105.0, 40.0],
        roles: [Role(id: 'r', kind: RoleKind.provision)],
      );
      expect(anchorMapPoints([a]).single.rings, isNull);
    });
  });

  group('planAnchorOutlines', () {
    test('a point anchor is never outlined', () {
      expect(planAnchorOutlines([_point()], project: _projectAt(pxPerDegree: 10000)), isEmpty);
    });

    test('below the screen-extent gate the boundary is withheld; above it is drawn', () {
      final district = _point(rings: [_districtRing]);
      // 0.02° across at 1000 px/° = 20 px: under the 48 px gate.
      expect(planAnchorOutlines([district], project: _projectAt(pxPerDegree: 1000)), isEmpty);
      final plan = planAnchorOutlines([district], project: _projectAt(pxPerDegree: 10000));
      expect(plan.single.screenExtentPx, closeTo(200, 1e-6));
      expect(plan.single.exterior, _districtRing);
    });

    test('holes travel with the exterior', () {
      final plan = planAnchorOutlines(
        [_point(rings: [_districtRing, _holeRing])],
        project: _projectAt(pxPerDegree: 10000),
      );
      expect(plan.single.holes, [_holeRing]);
    });

    test('an anchor outside the viewport is culled', () {
      final visible = LatLngBounds(const ll.LatLng(41.0, -104.0), const ll.LatLng(42.0, -103.0));
      final plan = planAnchorOutlines(
        [_point(rings: [_districtRing])],
        project: _projectAt(pxPerDegree: 10000),
        visible: visible,
      );
      expect(plan, isEmpty);
    });

    test('there is no cap: every area anchor that passes the gate is drawn', () {
      final many = [for (var i = 0; i < 400; i++) _point(id: 'a$i', rings: [_districtRing])];
      final plan = planAnchorOutlines(many, project: _projectAt(pxPerDegree: 10000));
      expect(plan, hasLength(400));
    });

    test('largest extent first, so a nested area paints on top', () {
      final plan = planAnchorOutlines(
        [_point(id: 'park', rings: [_holeRing]), _point(id: 'district', rings: [_districtRing])],
        project: _projectAt(pxPerDegree: 10000),
      );
      expect(plan.map((o) => o.anchor.label.split(' ').first), ['district', 'park']);
    });

    test('a degenerate ring is skipped rather than thrown on', () {
      final plan = planAnchorOutlines(
        [_point(rings: [const [[-105.27, 40.02], [-105.26, 40.02], [-105.27, 40.02]]])],
        project: _projectAt(pxPerDegree: 10000),
      );
      expect(plan, isEmpty);
    });
  });

  group('AnchorAreaLayer on TapToPickMap', () {
    testWidgets('an area anchor draws its ring under a marker at its point', (tester) async {
      await tester.pumpWidget(_wrap(TapToPickMap(
        anchors: anchorMapPoints([_areaAnchor(rings: [_districtRing, _holeRing])]),
        center: const [-105.27, 40.02],
        initialZoom: 13,
      )));
      await _settle(tester);

      expect(find.byType(AnchorMarker), findsOneWidget);
      final polygons = _polygons(tester);
      // A casing and a stroke per anchor.
      expect(polygons, hasLength(2));
      for (final p in polygons) {
        expect(p.points, hasLength(_districtRing.length));
        expect(p.holePointsList, hasLength(1));
      }
      expect(polygons[0].color, isNull, reason: 'the casing is a border only');
      expect(polygons[0].borderStrokeWidth, AnchorAreaLayer.casingWidth);
      expect(polygons[1].borderStrokeWidth, AnchorAreaLayer.strokeWidth);
      expect(polygons[1].color, isNotNull);
      expect(polygons[1].color!.a, closeTo(AnchorAreaLayer.fillOpacity, 1e-6));
    });

    testWidgets('a point anchor mounts no area layer', (tester) async {
      final a = Anchor(
        id: 'p',
        coord: const [-105.27, 40.02],
        roles: [Role(id: 'r', kind: RoleKind.narrative)],
      );
      await tester.pumpWidget(_wrap(TapToPickMap(
        anchors: anchorMapPoints([a]),
        center: const [-105.27, 40.02],
      )));
      await _settle(tester);
      expect(find.byType(AnchorMarker), findsOneWidget);
      expect(find.byType(AnchorAreaLayer), findsNothing);
    });

    testWidgets('zoomed out past the extent gate the ring is withheld and the mark remains',
        (tester) async {
      await tester.pumpWidget(_wrap(TapToPickMap(
        anchors: anchorMapPoints([_areaAnchor()]),
        center: const [-105.27, 40.02],
        initialZoom: 8,
      )));
      await _settle(tester);
      expect(find.byType(AnchorMarker), findsOneWidget);
      expect(_polygons(tester), isEmpty);
    });
  });

  group('AnchorAreaLayer on CandidateMap', () {
    const district = Candidate(
      id: 'c1',
      coord: [-105.27, 40.02],
      layer: 'historic',
      salience: 0.8,
      roleAffinity: RoleAffinity.narrative,
      title: 'Old Town',
      geometry: CandidatePolygon(ring: _districtRing),
    );

    // Before #484: promotion retired the candidate's pin (#410) but not its
    // #475 ring, which was fed the unretired list — so the ring that stayed
    // was the cache's, tap-promotable to a `DuplicatePromotionException`,
    // and the anchor's own copy of the boundary was never drawn at all.
    testWidgets('promoting an area candidate moves its ring from cache to canon',
        (tester) async {
      await tester.pumpWidget(_wrap(const CandidateMap(candidates: [district], initialZoom: 13)));
      await _settle(tester);
      expect(find.byType(PolygonLayer<Candidate>), findsOneWidget, reason: 'the candidate ring');
      expect(find.byType(AnchorAreaLayer), findsNothing);

      final anchor = promoteAnchor(
        id: 'a1',
        coord: district.coord,
        roles: [Role(id: 'r', kind: RoleKind.narrative)],
        title: district.title,
        area: areaFromCandidate(district),
        provenance: provenanceFromCandidate(district),
        existingAnchors: const [],
      );
      Candidate? tapped;
      await tester.pumpWidget(_wrap(CandidateMap(
        candidates: const [district],
        anchors: anchorMapPoints([anchor]),
        onCandidateTap: (c) => tapped = c,
        initialZoom: 13,
      )));
      await _settle(tester);

      expect(find.byType(CandidateMarker), findsNothing, reason: 'the candidate pin is retired');
      expect(find.byType(PolygonLayer<Candidate>), findsNothing,
          reason: 'and its #475 ring with it — the ring is no longer a promotion target');
      expect(find.byType(AnchorMarker), findsOneWidget);
      final polygons = _polygons(tester);
      expect(polygons, hasLength(2), reason: 'the anchor\'s own copy of the ring is drawn');
      expect(polygons[1].points.length, _districtRing.length);

      // A tap inside the boundary reaches the map, not the retired candidate.
      final camera = MapCamera.of(tester.element(find.byType(AnchorAreaLayer)));
      final origin = tester.getTopLeft(find.byType(FlutterMap));
      final inside = camera.latLngToScreenOffset(const ll.LatLng(40.012, -105.262));
      await tester.tapAt(origin + inside);
      await tester.pump();
      expect(tapped, isNull);
      // The tap fell through to the map, whose double-tap timer must run out.
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('the anchor ring does not intercept a tap on a candidate inside it',
        (tester) async {
      const inside = Candidate(
        id: 'c2',
        coord: [-105.27, 40.02],
        layer: 'sight',
        salience: 0.5,
        roleAffinity: RoleAffinity.narrative,
        title: 'Fountain',
      );
      Candidate? tapped;
      await tester.pumpWidget(_wrap(CandidateMap(
        candidates: const [inside],
        anchors: anchorMapPoints([
          Anchor(
            id: 'a1',
            coord: const [-105.275, 40.025],
            title: 'Old Town',
            area: Area(rings: const [_districtRing], source: AreaSource.authored),
            roles: [Role(id: 'r', kind: RoleKind.narrative)],
          ),
        ]),
        onCandidateTap: (c) => tapped = c,
        initialZoom: 13,
      )));
      await _settle(tester);
      expect(_polygons(tester), hasLength(2));
      await tester.tap(find.byType(CandidateMarker));
      await tester.pump();
      expect(tapped?.id, 'c2');
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
