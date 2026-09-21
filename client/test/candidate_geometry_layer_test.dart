// Issue #475 — a polygon or line candidate's own geometry is drawn on the
// candidate map, gated by screen extent and a salience cap, and a tap on
// the outline reports the candidate through the same `onCandidateTap`.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' as ll;

import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/candidate.dart';
import 'package:plotlines_client/presentation/map/candidate_geometry_layer.dart';
import 'package:plotlines_client/presentation/map/candidate_map.dart';
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
const _reserveRing = [
  [-105.28, 40.01],
  [-105.26, 40.01],
  [-105.26, 40.03],
  [-105.28, 40.03],
  [-105.28, 40.01],
];

// A ~20 km east-west path.
const _bywayPath = [
  [-105.40, 40.02],
  [-105.30, 40.025],
  [-105.20, 40.02],
];

Candidate _polygon(String id, {double salience = 0.8, List<List<double>> ring = _reserveRing}) =>
    Candidate(
      id: id,
      coord: [-105.27, 40.02],
      layer: 'leisure',
      salience: salience,
      roleAffinity: RoleAffinity.narrative,
      title: 'Reserve $id',
      geometry: CandidatePolygon(ring: ring),
    );

Candidate _line(String id, {double salience = 0.6}) => Candidate(
      id: id,
      coord: [-105.30, 40.025],
      layer: 'sight',
      salience: salience,
      roleAffinity: RoleAffinity.narrative,
      title: 'Byway $id',
      geometry: const CandidateLine(coords: _bywayPath),
    );

const _point = Candidate(
  id: 'p1',
  coord: [-105.27, 40.02],
  layer: 'historic',
  salience: 0.9,
  roleAffinity: RoleAffinity.narrative,
  title: 'Old Fort',
);

/// A fixed Web-Mercator-ish projection at a given metres-per-pixel scale:
/// enough to make the extent gate deterministic without a camera.
Offset Function(ll.LatLng) _projectAt({required double pxPerDegree}) =>
    (p) => Offset(p.longitude * pxPerDegree, -p.latitude * pxPerDegree);

void main() {
  group('planCandidateOutlines', () {
    test('a point candidate is never outlined', () {
      final plan = planCandidateOutlines([_point], project: _projectAt(pxPerDegree: 10000));
      expect(plan, isEmpty);
    });

    test('an outline below the screen-extent gate is not drawn; above it is', () {
      final reserve = _polygon('r1');
      // 0.02° across at 1000 px/° = 20 px: under the 48 px default gate.
      expect(planCandidateOutlines([reserve], project: _projectAt(pxPerDegree: 1000)), isEmpty);
      // At 10000 px/° the same ring spans 200 px.
      final plan = planCandidateOutlines([reserve], project: _projectAt(pxPerDegree: 10000));
      expect(plan.map((o) => o.candidate.id), ['r1']);
      expect(plan.single.screenExtentPx, closeTo(200, 1e-6));
    });

    test('a line candidate is planned from its path extent', () {
      // 0.2° long at 1000 px/° = 200 px, so the byway passes where the
      // reserve (20 px) does not.
      final plan = planCandidateOutlines(
        [_polygon('r1'), _line('l1')],
        project: _projectAt(pxPerDegree: 1000),
      );
      expect(plan.map((o) => o.candidate.id), ['l1']);
      expect(plan.single.geometry, isA<CandidateLine>());
    });

    test('a candidate whose geometry is outside the viewport is culled', () {
      final visible = LatLngBounds(const ll.LatLng(41.0, -104.0), const ll.LatLng(42.0, -103.0));
      final plan = planCandidateOutlines(
        [_polygon('r1'), _line('l1')],
        project: _projectAt(pxPerDegree: 10000),
        visible: visible,
      );
      expect(plan, isEmpty);
    });

    test('the salience cap keeps the most notable outlines', () {
      final plan = planCandidateOutlines(
        [_polygon('low', salience: 0.2), _polygon('high', salience: 0.9), _polygon('mid', salience: 0.5)],
        project: _projectAt(pxPerDegree: 10000),
        maxOutlines: 2,
      );
      expect(plan.map((o) => o.candidate.id).toSet(), {'high', 'mid'});
    });

    test('the plan is ordered largest extent first so nested features paint on top', () {
      const inner = [
        [-105.275, 40.015],
        [-105.265, 40.015],
        [-105.265, 40.025],
        [-105.275, 40.025],
        [-105.275, 40.015],
      ];
      final plan = planCandidateOutlines(
        [_polygon('park', ring: inner), _polygon('district')],
        project: _projectAt(pxPerDegree: 10000),
      );
      expect(plan.map((o) => o.candidate.id), ['district', 'park']);
    });

    test('a degenerate ring or path is skipped rather than thrown on', () {
      final plan = planCandidateOutlines(
        [
          _polygon('r1', ring: const [[-105.27, 40.02], [-105.26, 40.02]]),
          Candidate(
            id: 'l1',
            coord: const [-105.3, 40.0],
            layer: 'sight',
            salience: 0.5,
            roleAffinity: RoleAffinity.narrative,
            geometry: const CandidateLine(coords: [[-105.3, 40.0]]),
          ),
        ],
        project: _projectAt(pxPerDegree: 10000),
      );
      expect(plan, isEmpty);
    });
  });

  group('outline styling', () {
    test('stroke weight and opacity follow CandidateMarker\'s salience ramp', () {
      // The marker's ring is `(1.4 + 1.6·s)·u` and its fill `0.25 + 0.55·s`.
      expect(outlineStrokeWidth(0), 1.4);
      expect(outlineStrokeWidth(1), closeTo(3.0, 1e-9));
      expect(outlineStrokeOpacity(0), 0.25);
      expect(outlineStrokeOpacity(1), closeTo(0.8, 1e-9));
      // The area fill is a fifth of the marker's, never opaque.
      expect(outlineFillOpacity(1), closeTo(0.16, 1e-9));
      expect(outlineFillOpacity(0), closeTo(0.05, 1e-9));
    });
  });

  group('CandidateGeometryLayer on CandidateMap', () {
    testWidgets('draws a polygon candidate as a polygon and a line candidate as a polyline',
        (tester) async {
      await tester.pumpWidget(_wrap(CandidateMap(
        candidates: [_polygon('r1'), _line('l1'), _point],
        initialZoom: 13,
      )));
      await _settle(tester);
      expect(find.byType(CandidateGeometryLayer), findsOneWidget);
      final polygonLayer = tester.widget<PolygonLayer<Candidate>>(find.byType(PolygonLayer<Candidate>));
      expect(polygonLayer.polygons.map((p) => p.hitValue?.id), ['r1']);
      final lineLayer = tester.widget<PolylineLayer<Candidate>>(find.byType(PolylineLayer<Candidate>));
      expect(lineLayer.polylines.map((p) => p.hitValue?.id), ['l1']);
      // The pin is still there — the outline is added around it, not instead.
      expect(find.byTooltip('Reserve r1'), findsOneWidget);
      expect(find.byTooltip('Byway l1'), findsOneWidget);
    });

    testWidgets('a map of point candidates mounts no geometry layer', (tester) async {
      await tester.pumpWidget(_wrap(const CandidateMap(candidates: [_point])));
      await _settle(tester);
      expect(find.byType(CandidateGeometryLayer), findsNothing);
    });

    testWidgets('zoomed out past the extent gate the outline is withheld and the pin remains',
        (tester) async {
      await tester.pumpWidget(_wrap(CandidateMap(
        candidates: [_polygon('r1')],
        initialZoom: 6,
      )));
      await _settle(tester);
      expect(find.byType(PolygonLayer<Candidate>), findsNothing);
      expect(find.byTooltip('Reserve r1'), findsOneWidget);
    });

    testWidgets('tapping inside a polygon outline reports that candidate', (tester) async {
      Candidate? tapped;
      await tester.pumpWidget(_wrap(CandidateMap(
        candidates: [_polygon('r1')],
        initialZoom: 13,
        onCandidateTap: (c) => tapped = c,
      )));
      await _settle(tester);

      // Tap a spot inside the ring but away from its centroid pin, so the
      // hit is the polygon's, not the marker's.
      final camera = MapCamera.of(tester.element(find.byType(CandidateGeometryLayer)));
      final inside = camera.latLngToScreenOffset(const ll.LatLng(40.0125, -105.2625));
      final origin = tester.getTopLeft(find.byType(FlutterMap));
      await tester.tapAt(origin + inside);
      await tester.pump();
      expect(tapped?.id, 'r1');
    });

    testWidgets('tapping on a line outline reports that candidate', (tester) async {
      Candidate? tapped;
      await tester.pumpWidget(_wrap(CandidateMap(
        candidates: [_line('l1')],
        initialZoom: 13,
        onCandidateTap: (c) => tapped = c,
      )));
      await _settle(tester);

      final camera = MapCamera.of(tester.element(find.byType(CandidateGeometryLayer)));
      // On the first leg, away from the representative point at its vertex.
      final on = camera.latLngToScreenOffset(const ll.LatLng(40.0225, -105.35));
      final origin = tester.getTopLeft(find.byType(FlutterMap));
      await tester.tapAt(origin + on);
      await tester.pump();
      expect(tapped?.id, 'l1');
    });
  });
}
