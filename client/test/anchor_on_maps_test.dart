// Issue #410 — the three map surfaces, end to end: promote through the real
// `currentTripProvider` and the promoted place appears on the map that tab
// draws. Before this every one of these found nothing — `Trip.anchors`
// reached a list, a dropdown, or a lookup on each tab, never a marker.
//
// `anchor_map_points_test.dart` pins the builder and the two map widgets in
// isolation; this file pins the wiring, which is where the defect lived.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/curation_client.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/candidate.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/content_tab.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/layers_tab.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/route_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';
import 'package:plotlines_client/state/trip_candidates_provider.dart';
import 'support/display_units.dart';

const _bbox = TripBbox(minLat: 39.9, minLon: -105.4, maxLat: 40.1, maxLon: -105.1);

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

class _ScriptedCurationClient extends CurationClient {
  _ScriptedCurationClient(this.next) : super('http://fake');
  final CandidateExtraction next;

  @override
  Future<LayerCatalog> layerCatalog({required String mode, required String dayType}) async =>
      LayerCatalog(
        layers: const ['sight', 'historic'],
        defaultLive: const {'sight'},
        rulesetVersion: '1.0.0',
      );

  @override
  Future<CandidateExtraction> candidatesForBbox({
    required TripBbox bbox,
    required Set<String> liveLayers,
  }) async =>
      next;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Trip _trip() => Trip(
      id: 't1',
      title: 'Trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      modes: const {'cycling'},
      days: [
        Day(id: 'd1', index: 1, segments: [
          Segment(
            id: 's1',
            mode: 'cycling',
            shape: 'point_to_point',
            start: const [-105.3, 40.0],
            end: const [-105.2, 40.05],
          ),
        ]),
      ],
    );

const _oldFort = Candidate(
  id: 'c-fort',
  coord: [-105.25, 40.02],
  layer: 'historic',
  salience: 0.8,
  roleAffinity: RoleAffinity.narrative,
  title: 'Old Fort',
);

ProviderContainer _container({CurationClient? curation}) {
  final c = ProviderContainer(overrides: [
    metricUnits(),
    sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
    tripBboxProvider.overrideWith((ref) => TripBboxNotifier()..set(_bbox)),
    // Only the Layers tab reads the database (layer selection); the other
    // two tabs never touch it, and an unused instance is a drift warning.
    if (curation != null) ...[
      appDatabaseProvider.overrideWithValue(AppDatabase.forTesting(NativeDatabase.memory())),
      curationClientProvider.overrideWithValue(curation),
    ],
  ]);
  addTearDown(c.dispose);
  c.read(currentTripProvider.notifier).open(_trip());
  c.read(selectedSegmentProvider.notifier).state = ('d1', 's1');
  return c;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container,
    Widget Function(Trip trip) tab) async {
  tester.view.physicalSize = const Size(1800, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: PlotTheme.light(),
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) => tab(ref.watch(currentTripProvider)),
        ),
      ),
    ),
  ));
  await _settle(tester);
}

/// The hand-placed path `anchor_promotion_panel.dart` takes: O1's MVP
/// "promote directly" branch, no candidate involved.
Anchor _promoteHandPlaced(ProviderContainer container) =>
    container.read(currentTripProvider.notifier).promoteAnchor(
          coord: const [-105.24, 40.03],
          roles: [Role(id: 'r1', kind: RoleKind.station)],
          title: 'Regroup at the bridge',
          provenance: const AnchorProvenance(kind: AnchorSourceKind.handPlaced),
        );

void main() {
  testWidgets('Route tab: a promoted anchor is drawn on the map', (tester) async {
    final container = _container();
    await _pump(
      tester,
      container,
      (trip) => RouteTab(trip: trip, activeDayId: 'd1', onSelectDay: (_) {}),
    );
    expect(find.byType(AnchorMarker), findsNothing);

    _promoteHandPlaced(container);
    await _settle(tester);

    final mark = tester.widget<AnchorMarker>(find.byType(AnchorMarker));
    expect(mark.mark, AnchorMarkerMark.station);
    expect(find.byTooltip('Regroup at the bridge — anchor · station'), findsOneWidget);
  });

  testWidgets('Content tab: the panel\'s own promotion reaches the map beside it',
      (tester) async {
    final container = _container();
    await _pump(tester, container, (trip) => ContentTab(trip: trip));
    expect(find.byType(AnchorMarker), findsNothing);

    _promoteHandPlaced(container);
    await _settle(tester);

    expect(find.byType(AnchorMarker), findsOneWidget);
  });

  testWidgets('Layers tab: promoting a candidate to an anchor replaces its pin with the anchor mark',
      (tester) async {
    final container = _container(
      curation: _ScriptedCurationClient(const CandidateExtraction(candidates: [_oldFort])),
    );
    await _pump(
      tester,
      container,
      (trip) => LayersTab(trip: trip, activeDayId: 'd1'),
    );
    await container
        .read(tripCandidatesProvider.notifier)
        .fetch(bbox: _bbox, liveLayers: {'sight', 'historic'});
    await _settle(tester);
    expect(find.byType(CandidateMarker), findsOneWidget);
    expect(find.byType(AnchorMarker), findsNothing);

    // The proposals view's shape of promotion: candidate provenance by id.
    container.read(currentTripProvider.notifier).promoteAnchor(
          coord: _oldFort.coord,
          roles: [Role(id: 'r1', kind: RoleKind.narrative)],
          title: _oldFort.title,
          provenance: const AnchorProvenance(
              kind: AnchorSourceKind.candidate, sourceId: 'c-fort', layer: 'historic'),
        );
    await _settle(tester);

    expect(find.byType(CandidateMarker), findsNothing,
        reason: 'the promoted candidate\'s pin is retired');
    expect(find.byType(AnchorMarker), findsOneWidget);
  });

  // #477 — the tab's own tap used to write a day `Node` (N3's stand-in from
  // before O1's Anchor/role model existed); it now runs the same
  // `promoteAnchor` path the line above exercises directly, so the tap
  // itself produces the anchor mark, not a `NodeMarker`, and the day gets no
  // `Node` at all.
  testWidgets('Layers tab: tap-to-promote changes the mark on the map it happened on',
      (tester) async {
    final container = _container(
      curation: _ScriptedCurationClient(const CandidateExtraction(candidates: [_oldFort])),
    );
    await _pump(
      tester,
      container,
      (trip) => LayersTab(trip: trip, activeDayId: 'd1'),
    );
    await container
        .read(tripCandidatesProvider.notifier)
        .fetch(bbox: _bbox, liveLayers: {'sight', 'historic'});
    await _settle(tester);
    expect(find.byType(CandidateMarker), findsOneWidget);
    expect(find.byType(AnchorMarker), findsNothing);

    await tester.tap(find.byType(CandidateMarker));
    await _settle(tester);

    expect(find.byType(CandidateMarker), findsNothing,
        reason: 'the promoted candidate\'s pin is retired');
    expect(find.byType(AnchorMarker), findsOneWidget);
    expect(
        tester.widgetList<NodeMarker>(find.byType(NodeMarker)).where((m) => m.type == NodeMarkerType.plot),
        isEmpty);

    final trip = container.read(currentTripProvider);
    expect(trip.days.single.nodes, isEmpty);
    expect(trip.anchors, hasLength(1));
    expect(trip.anchors.single.provenance?.sourceId, 'c-fort');
    expect(trip.anchors.single.roles.single.dayId, 'd1');
  });
}
