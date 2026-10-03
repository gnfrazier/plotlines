// Issue #572 — with no trip bbox (every reopened trip until #570), the
// curation maps and the trip-area screen framed on `HomeRegion`: a
// Greensboro trip opened its Proposals map over Asheville. They now frame on
// the trip's own geometry first (`tripExtentOf`), and only fall back to the
// home region when the trip has placed nothing.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart' as ll;

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/curation_client.dart';
import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/domain/trip_extent.dart';
import 'package:plotlines_client/domain/home_region.dart';
import 'package:plotlines_client/presentation/map/candidate_map.dart';
import 'package:plotlines_client/presentation/map/tap_to_pick_map.dart';
import 'package:plotlines_client/presentation/map/trip_area_map.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/layers_tab.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/proposals_view.dart';
import 'package:plotlines_client/presentation/screens/new_route_screen.dart';
import 'package:plotlines_client/presentation/screens/trip_area_screen.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

// A Greensboro loop — well clear of the WNC home region.
const _route = [
  [-79.80, 36.07],
  [-79.70, 36.10],
  [-79.65, 36.05],
  [-79.80, 36.07],
];

Trip _greensboroTrip() => Trip(
      id: 't1',
      title: 'Greensboro loop',
      createdAt: '2026-10-01T00:00:00Z',
      updatedAt: '2026-10-01T00:00:00Z',
      modes: const {'cycling'},
      days: [
        Day(id: 'd1', index: 1, segments: [
          Segment(
            id: 's1',
            mode: 'cycling',
            shape: 'loop',
            start: [..._route.first],
            geometry: LineString(coordinates: [for (final c in _route) [...c]]),
          ),
        ]),
      ],
    );

Trip _emptyTrip() => Trip(
      id: 't0',
      title: 'Fresh',
      createdAt: '2026-10-01T00:00:00Z',
      updatedAt: '2026-10-01T00:00:00Z',
      days: [Day(id: 'd1', index: 1)],
    );

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

class _CatalogOnlyCurationClient extends CurationClient {
  _CatalogOnlyCurationClient() : super('http://fake');
  @override
  Future<LayerCatalog> layerCatalog({required String mode, required String dayType}) async =>
      const LayerCatalog(layers: ['historic'], defaultLive: {'historic'}, rulesetVersion: '1.0.0');
}

class _StubRoutingClient extends RoutingClient {
  _StubRoutingClient() : super('http://stub');
  @override
  Future<String> ensureRegion(List<double> bboxWsen,
          {String networkType = 'bike', bool retry = false}) async =>
      'region-stub';
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

ProviderContainer _container(Trip trip, {TripBbox? bbox}) {
  final container = ProviderContainer(overrides: [
    appDatabaseProvider.overrideWithValue(AppDatabase.forTesting(NativeDatabase.memory())),
    sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
    curationClientProvider.overrideWithValue(_CatalogOnlyCurationClient()),
    routingClientProvider.overrideWithValue(_StubRoutingClient()),
    tripRegionKeyProvider.overrideWith(
        (ref) => TripRegionKeyNotifier(ref, settleWindow: Duration.zero)),
    if (bbox != null) tripBboxProvider.overrideWith((ref) => TripBboxNotifier()..set(bbox)),
  ]);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(trip);
  return container;
}

/// The route's bounds sit inside the fit's bounds — the camera frames the trip.
void _expectFramesRoute(CameraFit? fit) {
  expect(fit, isA<FitBounds>());
  final b = (fit! as FitBounds).bounds;
  for (final c in _route) {
    expect(b.contains(ll.LatLng(c[1], c[0])), isTrue, reason: 'fit should contain $c');
  }
}

void main() {
  group('tripExtentOf', () {
    test('is null for a trip that has placed nothing', () {
      expect(tripExtentOf(_emptyTrip()), isNull);
    });

    test('covers every passage route point and every anchor', () {
      final trip = _greensboroTrip().copyWith(anchors: [
        Anchor(id: 'a1', coord: const [-79.60, 36.20], roles: [Role(id: 'r1', kind: RoleKind.narrative)]),
      ]);
      final e = tripExtentOf(trip)!;
      expect(e.minLon, -79.80);
      expect(e.maxLon, -79.60);
      expect(e.minLat, 36.05);
      expect(e.maxLat, 36.20);
    });
  });

  testWidgets('Proposals with no bbox frames the trip, not the home region', (tester) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final trip = _greensboroTrip();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: _container(trip),
      child: MaterialApp(
          home: Scaffold(body: ProposalsView(trip: trip, liveLayers: const {'historic'}))),
    ));
    await _settle(tester);

    _expectFramesRoute(tester.widget<CandidateMap>(find.byType(CandidateMap)).initialCameraFit);
  });

  testWidgets('Proposals with a bbox keeps framing on it (unchanged)', (tester) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final trip = _greensboroTrip();
    const bbox = TripBbox(minLat: 36.0, minLon: -79.9, maxLat: 36.2, maxLon: -79.6);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: _container(trip, bbox: bbox),
      child: MaterialApp(
          home: Scaffold(body: ProposalsView(trip: trip, liveLayers: const {'historic'}))),
    ));
    await _settle(tester);

    expect(tester.widget<CandidateMap>(find.byType(CandidateMap)).initialCameraFit, isNull);
  });

  testWidgets('the Layers tab with no bbox frames the trip', (tester) async {
    final trip = _greensboroTrip();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: _container(trip),
      child: MaterialApp(home: Scaffold(body: LayersTab(trip: trip, activeDayId: 'd1'))),
    ));
    await _settle(tester);

    _expectFramesRoute(tester.widget<CandidateMap>(find.byType(CandidateMap)).initialCameraFit);
  });

  testWidgets('revising a trip area with no bbox frames the trip, not the home region',
      (tester) async {
    final router = GoRouter(
      initialLocation: '/trip-area',
      routes: [
        GoRoute(
            path: '/trip-area', builder: (_, _) => const TripAreaScreen(isCreation: false)),
      ],
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: _container(_greensboroTrip()),
      child: MaterialApp.router(routerConfig: router),
    ));
    await _settle(tester);

    _expectFramesRoute(tester.widget<TripAreaMap>(find.byType(TripAreaMap)).initialCameraFit);
  });

  // #612/#614/#618/#619 — a map opened with no center of its own (New Route
  // from "Add a day" / "Add a route day", a blank day's route map, the
  // lodging picker) used to open over `HomeRegion` whatever the trip area was.
  group('a map with no center of its own opens over the trip area', () {
    const greensboro = TripBbox(minLat: 36.0, minLon: -79.9, maxLat: 36.2, maxLon: -79.6);

    CameraFit? fitOf(WidgetTester tester) =>
        tester.widget<FlutterMap>(find.byType(FlutterMap)).options.initialCameraFit;

    void expectFramesBbox(CameraFit? fit, TripBbox b) {
      expect(fit, isA<FitBounds>());
      final bounds = (fit! as FitBounds).bounds;
      expect(bounds.contains(ll.LatLng(b.centerLat, b.centerLon)), isTrue);
      expect(bounds.contains(ll.LatLng(HomeRegion.centerLat, HomeRegion.centerLon)), isFalse);
    }

    testWidgets('TapToPickMap frames the drawn bbox', (tester) async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: _container(_emptyTrip(), bbox: greensboro),
        child: const MaterialApp(home: Scaffold(body: TapToPickMap())),
      ));
      await _settle(tester);
      expectFramesBbox(fitOf(tester), greensboro);
    });

    testWidgets('TapToPickMap with no bbox frames what the trip has placed', (tester) async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: _container(_greensboroTrip()),
        child: const MaterialApp(home: Scaffold(body: TapToPickMap())),
      ));
      await _settle(tester);
      _expectFramesRoute(fitOf(tester));
    });

    testWidgets('TapToPickMap keeps HomeRegion only when there is no trip area at all',
        (tester) async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: _container(_emptyTrip()),
        child: const MaterialApp(home: Scaffold(body: TapToPickMap())),
      ));
      await _settle(tester);
      final options = tester.widget<FlutterMap>(find.byType(FlutterMap)).options;
      expect(options.initialCameraFit, isNull);
      expect(options.initialCenter.latitude, closeTo(HomeRegion.centerLat, 1e-9));
    });

    testWidgets('an explicit center still wins', (tester) async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: _container(_emptyTrip(), bbox: greensboro),
        child: const MaterialApp(
            home: Scaffold(body: TapToPickMap(center: [-105.27, 40.02]))),
      ));
      await _settle(tester);
      final options = tester.widget<FlutterMap>(find.byType(FlutterMap)).options;
      expect(options.initialCameraFit, isNull);
      expect(options.initialCenter.latitude, closeTo(40.02, 1e-9));
    });

    testWidgets('CandidateMap with neither a fit nor a bbox frames the trip area',
        (tester) async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: _container(_emptyTrip(), bbox: greensboro),
        child: const MaterialApp(home: Scaffold(body: CandidateMap(candidates: []))),
      ));
      await _settle(tester);
      expectFramesBbox(fitOf(tester), greensboro);
    });

    testWidgets('New Route opened with no center (Add a day / Add a route day) frames the trip area',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: _container(_emptyTrip(), bbox: greensboro),
        child: const MaterialApp(home: NewRouteScreen()),
      ));
      await _settle(tester);
      expectFramesBbox(fitOf(tester), greensboro);
    });
  });
}
