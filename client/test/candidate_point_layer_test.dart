// Issue #478 — candidate points render SPIKE-G's way: the top-K by salience
// as widget markers, the rest as a canvas dot tail, and grid clusters only
// below the trip overview or above the density ceiling. Never one widget per
// candidate.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/candidate.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/map/candidate_map.dart';
import 'package:plotlines_client/presentation/map/candidate_point_layer.dart';
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

/// The layer alone on a bare `FlutterMap` (no basemap), so a test can pick
/// K and the ceiling and read the camera it planned against.
Widget _bareMap(CandidatePointLayer layer,
        {double zoom = 13, void Function(ll.LatLng)? onMapTap}) =>
    MaterialApp(
      home: Scaffold(
        body: FlutterMap(
          options: MapOptions(
            initialCenter: const ll.LatLng(40.02, -105.27),
            initialZoom: zoom,
            onTap: onMapTap == null ? null : (_, p) => onMapTap(p),
          ),
          children: [layer],
        ),
      ),
    );

Candidate _c(String id, double lon, double lat, {double salience = 0.5, String? title}) => Candidate(
      id: id,
      coord: [lon, lat],
      layer: 'historic',
      salience: salience,
      roleAffinity: RoleAffinity.narrative,
      title: title ?? 'Place $id',
    );

/// [n] candidates on a deterministic grid inside a 0.08° square around
/// Boulder, salience spread over [0, 1).
List<Candidate> _field(int n) {
  final side = (n / 2).ceil();
  return [
    for (var i = 0; i < n; i++)
      _c('c${i.toString().padLeft(5, '0')}', -105.31 + 0.08 * (i % side) / side,
          39.98 + 0.08 * (i ~/ side) / 2, salience: (i * 37 % 100) / 100),
  ];
}

/// A flat projection: 10,000 world px per degree, y growing south.
Offset _project(ll.LatLng p) => Offset(p.longitude * 10000, -p.latitude * 10000);

/// The origin that puts (lon, lat) at the viewport's top-left.
Offset _originAt(double lon, double lat) => _project(ll.LatLng(lat, lon));

const _viewport = Size(800, 600);

/// A trip extent wider than the test viewport at z13, so the bare-map
/// tests below plan at (not below) the overview zoom.
final _trip = LatLngBounds(const ll.LatLng(39.9, -105.4), const ll.LatLng(40.1, -105.1));

void main() {
  group('planCandidatePoints', () {
    // Top-left at (-105.30, 40.03): the viewport spans 0.08° × 0.06°.
    final origin = _originAt(-105.30, 40.03);

    test('under K every in-view candidate is a marker, no dots', () {
      final plan = planCandidatePoints(
        candidatesBySalience([_c('a', -105.29, 40.02), _c('b', -105.28, 40.01)]),
        project: _project, origin: origin, viewport: _viewport,
      );
      expect(plan.markers.map((c) => c.id), ['a', 'b']);
      expect(plan.dots, isEmpty);
      expect(plan.clustered, isFalse);
    });

    test('over K the most notable keep markers and the rest become dots', () {
      final plan = planCandidatePoints(
        candidatesBySalience([
          _c('low', -105.29, 40.02, salience: 0.1),
          _c('high', -105.28, 40.02, salience: 0.9),
          _c('mid', -105.27, 40.02, salience: 0.5),
          _c('tie-b', -105.26, 40.02, salience: 0.5),
        ]),
        project: _project, origin: origin, viewport: _viewport, maxMarkers: 2,
      );
      // Ties break by id, so 'mid' beats 'tie-b' every frame.
      expect(plan.markers.map((c) => c.id), ['high', 'mid']);
      expect(plan.dots.map((d) => d.candidate.id), ['tie-b', 'low']);
      expect(plan.inViewport, 4);
      // A dot sits at its screen offset: 0.01° right of the viewport's left
      // edge and 0.01° down = (100, 100) at 10,000 px/°.
      expect(plan.dots.last.offset.dx, closeTo(100, 1e-6));
      expect(plan.dots.last.offset.dy, closeTo(100, 1e-6));
    });

    test('K is counted in the viewport — an off-screen candidate takes no slot', () {
      final plan = planCandidatePoints(
        candidatesBySalience([
          _c('far', -104.0, 41.0, salience: 1.0),
          _c('here', -105.29, 40.02, salience: 0.2),
        ]),
        project: _project, origin: origin, viewport: _viewport, maxMarkers: 1,
      );
      expect(plan.markers.map((c) => c.id), ['here']);
      expect(plan.dots, isEmpty);
      expect(plan.inViewport, 1);
    });

    test('a marker centred just outside the edge still counts (it shows half of itself)', () {
      // 10 px left of the viewport, inside the 16 px margin.
      final plan = planCandidatePoints(
        candidatesBySalience([_c('edge', -105.301, 40.02)]),
        project: _project, origin: origin, viewport: _viewport,
      );
      expect(plan.markers.map((c) => c.id), ['edge']);
    });

    test('above the density ceiling the grid-cluster backstop engages', () {
      // Two share a 64 px cell (5 px apart), one sits alone far away.
      final plan = planCandidatePoints(
        candidatesBySalience([
          _c('a', -105.2950, 40.0250, salience: 0.3),
          _c('b', -105.2945, 40.0250, salience: 0.8),
          _c('lone', -105.24, 39.98),
        ]),
        project: _project, origin: origin, viewport: _viewport, densityCeiling: 2,
      );
      expect(plan.clustered, isTrue);
      expect(plan.dots, isEmpty);
      // A one-member cell keeps its full marker: a cluster never hides a
      // candidate it did not have to.
      expect(plan.markers.map((c) => c.id), ['lone']);
      final cluster = plan.clusters.single;
      expect(cluster.members.map((c) => c.id), ['b', 'a']);
      expect(cluster.topSalience, 0.8);
      expect(cluster.point.longitude, closeTo(-105.29475, 1e-9));
    });

    test('at the ceiling itself it does not cluster', () {
      final plan = planCandidatePoints(
        candidatesBySalience([_c('a', -105.2950, 40.025), _c('b', -105.2945, 40.025)]),
        project: _project, origin: origin, viewport: _viewport, densityCeiling: 2,
      );
      expect(plan.clustered, isFalse);
    });

    test('below the overview zoom it clusters whatever the count', () {
      final plan = planCandidatePoints(
        candidatesBySalience([_c('a', -105.2950, 40.025), _c('b', -105.2945, 40.025)]),
        project: _project, origin: origin, viewport: _viewport, belowOverview: true,
      );
      expect(plan.clustered, isTrue);
      expect(plan.clusters.single.members, hasLength(2));
    });

    test('cluster cells are keyed on world pixels, so a pan does not regroup them', () {
      final cands = candidatesBySalience([
        _c('a', -105.2950, 40.0250),
        _c('b', -105.2945, 40.0250),
        _c('c', -105.2800, 40.0100),
      ]);
      Set<Set<String>> groups(Offset o) {
        final plan = planCandidatePoints(cands,
            project: _project, origin: o, viewport: _viewport, belowOverview: true);
        return {
          for (final cl in plan.clusters) {for (final m in cl.members) m.id},
          for (final m in plan.markers) {m.id},
        };
      }

      // A 37 px pan: every screen offset moves, no world-pixel cell does.
      expect(groups(origin + const Offset(-37, -37)), groups(origin));
    });

    test('an sgv-density field (1,208) draws exactly K widget markers', () {
      // Spread across the whole viewport so every one is in view.
      final field = [
        for (var i = 0; i < 1208; i++)
          _c('c$i', -105.30 + 0.08 * (i % 44) / 44, 40.03 - 0.06 * (i ~/ 44) / 28,
              salience: (i * 37 % 100) / 100),
      ];
      final plan = planCandidatePoints(candidatesBySalience(field),
          project: _project, origin: origin, viewport: _viewport);
      expect(plan.inViewport, 1208);
      expect(plan.markers, hasLength(CandidatePointLayer.defaultMaxMarkers));
      expect(plan.dots, hasLength(1208 - CandidatePointLayer.defaultMaxMarkers));
      // Every marker is at least as notable as every dot.
      final minMarker = plan.markers.map((c) => c.salience).reduce((a, b) => a < b ? a : b);
      final maxDot = plan.dots.map((d) => d.candidate.salience).reduce((a, b) => a > b ? a : b);
      expect(minMarker, greaterThanOrEqualTo(maxDot));
    });
  });

  group('isBelowOverviewZoom', () {
    test('an extent filling the viewport is at or above the overview', () {
      expect(isBelowOverviewZoom(const Rect.fromLTWH(0, 0, 700, 500), _viewport), isFalse);
    });

    test('an extent under half the viewport on both axes is below it', () {
      expect(isBelowOverviewZoom(const Rect.fromLTWH(0, 0, 390, 290), _viewport), isTrue);
    });

    test('a long thin extent that still spans one axis is not', () {
      expect(isBelowOverviewZoom(const Rect.fromLTWH(0, 0, 700, 20), _viewport), isFalse);
    });

    test('no extent is never below it', () {
      expect(isBelowOverviewZoom(null, _viewport), isFalse);
    });
  });

  group('dots', () {
    final dots = [
      CandidateDot(_c('a', 0, 0), const Offset(100, 100)),
      CandidateDot(_c('b', 0, 0), const Offset(110, 100)),
    ];

    test('a tap resolves to the nearest dot within reach', () {
      expect(nearestDot(dots, const Offset(107, 101))?.candidate.id, 'b');
      expect(nearestDot(dots, const Offset(101, 99))?.candidate.id, 'a');
    });

    test('a tap out of reach of every dot resolves to nothing', () {
      expect(nearestDot(dots, const Offset(200, 200)), isNull);
    });

    test('a dot is sized and faded by salience, and never as big as a marker', () {
      expect(dotDiameter(0), 3);
      expect(dotDiameter(1), 7);
      // CandidateMarker's smallest draw is 55% of its 22 px base.
      expect(dotDiameter(1), lessThan(22 * 0.55));
      expect(dotOpacity(0), 0.25);
      expect(dotOpacity(1), closeTo(0.8, 1e-9));
    });
  });

  group('CandidatePointLayer on a map', () {
    testWidgets('mounts K markers and paints the rest as dots', (tester) async {
      await tester.pumpWidget(_bareMap(CandidatePointLayer(candidates: _field(12), maxMarkers: 3)));
      await tester.pump();
      expect(find.byType(CandidateMarker), findsNWidgets(3));
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<CandidateDotPainter>()
          .single;
      expect(painter.dots, hasLength(9));
    });

    testWidgets('a tap on a dot selects its candidate', (tester) async {
      Candidate? tapped;
      final field = [
        _c('marker', -105.29, 40.02, salience: 0.9),
        _c('dot', -105.25, 40.02, salience: 0.1),
      ];
      await tester.pumpWidget(_bareMap(
          CandidatePointLayer(candidates: field, maxMarkers: 1, overviewExtent: _trip,
              onCandidateTap: (c) => tapped = c)));
      await tester.pump();
      expect(find.byType(CandidateMarker), findsOneWidget);

      final camera = MapCamera.of(tester.element(find.byType(CandidatePointLayer)));
      final at = camera.latLngToScreenOffset(const ll.LatLng(40.02, -105.25));
      await tester.tapAt(tester.getTopLeft(find.byType(FlutterMap)) + at + const Offset(3, 2));
      await tester.pump();
      expect(tapped?.id, 'dot');
    });

    testWidgets('a tap away from every dot falls through to the map', (tester) async {
      Candidate? tapped;
      ll.LatLng? mapTap;
      await tester.pumpWidget(_bareMap(
        CandidatePointLayer(
            candidates: [_c('m', -105.29, 40.02), _c('d', -105.25, 40.02)],
            maxMarkers: 1,
            overviewExtent: _trip,
            onCandidateTap: (c) => tapped = c),
        onMapTap: (p) => mapTap = p,
      ));
      await tester.pump();

      final camera = MapCamera.of(tester.element(find.byType(CandidatePointLayer)));
      final empty = camera.latLngToScreenOffset(const ll.LatLng(40.00, -105.27));
      expect(find.byType(CandidateMarker), findsOneWidget, reason: 'one marker, one dot');
      await tester.tapAt(tester.getTopLeft(find.byType(FlutterMap)) + empty);
      // flutter_map holds a single tap until the double-tap window closes.
      await tester.pump(const Duration(milliseconds: 500));
      expect(tapped, isNull);
      expect(mapTap, isNotNull);
    });

    testWidgets('below the overview zoom it clusters, and a cluster tap zooms to its members',
        (tester) async {
      // A 0.08° field at z9 is ~60 px across: well under half the viewport.
      final field = _field(40);
      await tester.pumpWidget(_bareMap(
          CandidatePointLayer(
            candidates: field,
            overviewExtent: LatLngBounds(const ll.LatLng(39.98, -105.31), const ll.LatLng(40.06, -105.23)),
          ),
          zoom: 9));
      await tester.pump();
      expect(find.byType(CandidateClusterGlyph), findsWidgets);
      expect(find.byType(CandidateMarker), findsNothing);

      final before = MapCamera.of(tester.element(find.byType(CandidatePointLayer))).zoom;
      await tester.tap(find.byType(CandidateClusterGlyph).last);
      await tester.pump();
      final after = MapCamera.of(tester.element(find.byType(CandidatePointLayer))).zoom;
      expect(after, greaterThan(before));
    });

    testWidgets('with no trip extent a zoomed-out handful is not clustered', (tester) async {
      // The same 40 at z9, but no trip bbox to judge the overview against:
      // only the density ceiling may cluster.
      await tester.pumpWidget(_bareMap(CandidatePointLayer(candidates: _field(40)), zoom: 9));
      await tester.pump();
      expect(find.byType(CandidateClusterGlyph), findsNothing);
      expect(find.byType(CandidateMarker), findsNWidgets(40));
    });
  });

  group('CandidateMap (regression for #478)', () {
    testWidgets('an sgv-density candidate set mounts at most K widget markers', (tester) async {
      // 1,208 candidates (SPIKE-A's `sgv` count) inside a trip bbox that fills
      // the viewport at z13. Before #478 this mounted 1,208 `CandidateMarker`s.
      const bbox = TripBbox(minLat: 39.98, minLon: -105.31, maxLat: 40.06, maxLon: -105.23);
      await tester.pumpWidget(_wrap(CandidateMap(candidates: _field(1208), bbox: bbox, initialZoom: 13)));
      await _settle(tester);
      final markers = find.byType(CandidateMarker).evaluate().length;
      expect(markers, greaterThan(0));
      expect(markers, lessThanOrEqualTo(CandidatePointLayer.defaultMaxMarkers));
      expect(find.byType(CandidatePointLayer), findsOneWidget);
    });
  });
}
