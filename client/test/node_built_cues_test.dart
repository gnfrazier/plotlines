// Issue #653 — a passage built from nodes (#626) has no stored `start`; D71
// derives its ends from its routed nodes (`routeSolveInputs`). Every cue path
// and Diagnose used to read `segment.start` instead, so the passage had no
// turns, a day that mixed one with a tapped route lost every passage's turns
// to a null check, and Diagnose crashed on `segment.start!`.
//
// The flow test in `route_by_nodes_flow_test.dart` carries placement through
// Generate to EXPORT, and `routing_client_node_built_test.dart` pins the
// request bodies; this file pins the per-passage isolation of a day's cue
// fetch, and Diagnose.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/map/tap_to_pick_map.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/content_tab.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/export_tab.dart';
import 'package:plotlines_client/presentation/widgets/weights_rail.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';
import 'support/display_units.dart';
import 'support/routing_ready.dart';

const _a = [-79.50, 36.10];
const _b = [-79.45, 36.12];
const _c = [-79.40, 36.15];

/// Built from three placed nodes: start, rest stop, finish. No stored ends.
Segment _nodeBuilt({String id = 'nodes', String? title}) => Segment(
      id: id,
      title: title,
      mode: 'cycling',
      shape: 'point_to_point',
      via: const [_a, _b, _c],
      nodes: [
        Node(id: 'n1', kind: NodeKind.start, coord: _a, title: 'Gazebo'),
        Node(id: 'n2', kind: NodeKind.restStop, coord: _b, title: 'Park'),
        Node(id: 'n3', kind: NodeKind.finish, coord: _c, title: 'Downtown'),
      ],
      geometry: LineString(coordinates: const [_a, _b, _c]),
      metrics: RouteMetrics(distanceM: 9000),
    );

Segment _tapped() => Segment(
      id: 'tapped',
      mode: 'cycling',
      shape: 'point_to_point',
      start: _c,
      end: const [-79.35, 36.18],
      geometry: LineString(coordinates: const [_c, [-79.35, 36.18]]),
      metrics: RouteMetrics(distanceM: 6000),
    );

CueSheet _sheet(String turn) => CueSheet(generatedAt: '2026-10-08T00:00:00Z', cues: [
      Cue(id: 's', sequence: 0, distanceAlongM: 0, kind: 'start', instruction: 'Start'),
      Cue(id: 't', sequence: 1, distanceAlongM: 1000, kind: 'turn', modifier: 'right', instruction: turn),
    ]);

class _FakeRoutingClient extends RoutingClient {
  _FakeRoutingClient({this.failFor = const {}}) : super('http://fake');
  final Set<String> failFor;
  final cuesAskedFor = <String>[];
  Coord? diagnoseStart;
  List<Coord>? diagnoseVia;

  @override
  Future<String> ensureRegion(List<double> bboxWsen, {String networkType = 'bike', bool retry = false}) async =>
      'region-1';

  @override
  Future<CueSheet> cuesFor(Segment segment, {required String region}) async {
    cuesAskedFor.add(segment.id);
    if (failFor.contains(segment.id)) {
      throw RoutingException(500, jsonEncode({'detail': 'cue derivation failed'}));
    }
    return _sheet('Turn right off ${segment.id}');
  }

  @override
  Future<String> submitDiagnose({
    required String region,
    required Coord start,
    required double targetM,
    required List<Band> bands,
    List<Coord> via = const [],
  }) async {
    diagnoseStart = start;
    diagnoseVia = via;
    return 'job-1';
  }

  @override
  Future<Diagnosis> awaitDiagnosis(String jobId) async =>
      throw StateError('a failure that is not a RoutingException');
}

Trip _trip(List<Segment> segments) => Trip(
      id: 't',
      title: 'Greensboro',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: [Day(id: 'd1', index: 1, segments: segments)],
    );

List<Override> _overrides(RoutingClient client, List<Segment> segments) => [
      metricUnits(),
      routingReady(),
      routingClientProvider.overrideWithValue(client),
      tripBboxProvider.overrideWith((ref) => TripBboxNotifier()
        ..set(const TripBbox(minLat: 35.9, minLon: -79.6, maxLat: 36.3, maxLon: -79.2))),
      currentTripProvider.overrideWith((ref) => CurrentTripNotifier(ref)..open(_trip(segments))),
    ];

Future<void> _pumpExport(WidgetTester tester, RoutingClient client, List<Segment> segments) async {
  await tester.pumpWidget(ProviderScope(
    overrides: _overrides(client, segments),
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(builder: (context, ref, _) => ExportTab(trip: ref.watch(currentTripProvider))),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('EXPORT cue sheet', () {
    testWidgets('a day of only node-built passages shows their turns', (tester) async {
      final client = _FakeRoutingClient();
      await _pumpExport(tester, client, [_nodeBuilt()]);

      expect(client.cuesAskedFor, ['nodes']);
      expect(find.text('Turn right off nodes'), findsOneWidget);
    });

    testWidgets('a mixed day keeps every passage\'s turns', (tester) async {
      final client = _FakeRoutingClient();
      await _pumpExport(tester, client, [_nodeBuilt(), _tapped()]);

      expect(find.text('Turn right off nodes'), findsOneWidget);
      expect(find.text('Turn right off tapped'), findsOneWidget);
      expect(find.textContaining('unavailable'), findsNothing);
    });

    testWidgets('one passage failing keeps the others\' turns and names the one that failed',
        (tester) async {
      final client = _FakeRoutingClient(failFor: {'nodes'});
      await _pumpExport(tester, client, [_nodeBuilt(title: 'Morning loop'), _tapped()]);

      expect(find.text('Turn right off tapped'), findsOneWidget);
      // The failed passage keeps its authored points.
      expect(find.text('Park'), findsWidgets);
      expect(find.textContaining('Turns couldn\'t be derived for Morning loop'), findsOneWidget);
    });
  });

  group('Diagnose', () {
    testWidgets('on a node-built passage it diagnoses from the start node, and any failure '
        'is a sentence', (tester) async {
      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final segment = _nodeBuilt().copyWith(bands: [Band(attribute: 'climb_m', min: 100)]);
      final client = _FakeRoutingClient();
      await tester.pumpWidget(ProviderScope(
        overrides: _overrides(client, [segment]),
        child: MaterialApp(home: Scaffold(body: WeightsRail(dayId: 'd1', segment: segment))),
      ));
      await tester.pump();

      await tester.tap(find.widgetWithText(PlotButton, 'Diagnose'));
      await tester.pumpAndSettle();

      expect(client.diagnoseStart, _a);
      expect(client.diagnoseVia, [_b]);
      expect(find.text('Diagnose didn\'t finish. Try again.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('the Content tab map draws a node-built passage\'s line from its start node',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ..._overrides(_FakeRoutingClient(), [_nodeBuilt()]),
        appDatabaseProvider.overrideWithValue(db),
        selectedSegmentProvider.overrideWith((ref) => ('d1', 'nodes')),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) => ContentTab(trip: ref.watch(currentTripProvider))),
        ),
      ),
    ));
    await tester.pump();

    final map = tester.widget<TapToPickMap>(find.byType(TapToPickMap));
    expect(map.center, _a);
    expect(map.polyline, const [_a, _b, _c]);
  });
}
