// Issue #640 — the create-route-by-nodes flow end to end, on the real Route
// tab with both rails: a blank day, three nodes placed in the order #640's
// QA placed them (start, finish, rest stop), the one ROUTE THROUGH list, and
// Generate. Only the sidecar is faked.
//
// Issue #653 — the same flow carried on to EXPORT: the passage it builds has
// no stored start, and its cue sheet still has turns.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/export_tab.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/route_tab.dart';
import 'package:plotlines_client/presentation/widgets/node_editor_sheet.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';
import 'support/display_units.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

class _RecordingRoutingClient extends RoutingClient {
  _RecordingRoutingClient() : super('http://fake');
  ({Coord start, Coord? end, List<Coord> via})? asked;

  @override
  Future<String> ensureRegion(List<double> bboxWsen,
          {String networkType = 'bike', bool retry = false}) async =>
      'region-1';

  @override
  Future<Segment> generateSegment({
    required String region,
    required Coord start,
    Coord? end,
    List<Coord> via = const [],
    String mode = 'cycling',
    String? discipline,
    String shape = 'loop',
    String theme = 'balanced',
    Map<String, double>? weights,
    double? targetM,
  }) async {
    asked = (start: start, end: end, via: via);
    return Segment(
      id: 'x',
      mode: mode,
      shape: shape,
      start: start,
      end: end,
      via: via,
      geometry: LineString(coordinates: [start, ...via, end!]),
      metrics: RouteMetrics(distanceM: 24000),
      solve: SolveProvenance(solvedAt: '2026-10-07T00:00:00Z'),
    );
  }

  ({Coord start, Coord? end, List<Coord> via})? cuesAsked;

  @override
  Future<CueSheet> cuesFor(Segment segment, {required String region}) async {
    cuesAsked = routeSolveInputs(segment);
    return CueSheet(generatedAt: '2026-10-07T00:00:00Z', cues: [
      Cue(id: 'c0', sequence: 0, distanceAlongM: 0, kind: 'start', instruction: 'Start'),
      Cue(id: 'c1', sequence: 1, distanceAlongM: 3000, kind: 'turn', modifier: 'left',
          instruction: 'Turn left onto Lake Brandt Rd'),
      Cue(id: 'c2', sequence: 2, distanceAlongM: 24000, kind: 'finish', instruction: 'Finish'),
    ]);
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<(_RecordingRoutingClient, ProviderContainer)> _pumpRouteTab(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final client = _RecordingRoutingClient();
  final container = ProviderContainer(overrides: [
    metricUnits(),
    sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
    routingClientProvider.overrideWithValue(client),
    tripBboxProvider.overrideWith((ref) => TripBboxNotifier()
      ..set(const TripBbox(minLat: 35.9, minLon: -79.6, maxLat: 36.3, maxLon: -79.2))),
  ]);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(Trip(
        id: 't',
        title: 'Greensboro',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        modes: const {'cycling'},
        days: [Day(id: 'd1', index: 1)],
      ));
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) => RouteTab(
            trip: ref.watch(currentTripProvider),
            activeDayId: 'd1',
            onSelectDay: (_) {},
          ),
        ),
      ),
    ),
  ));
  await _settle(tester);
  return (client, container);
}

Future<void> _place(WidgetTester tester, Offset fromCenter, String kind, String title) async {
  await tester.tap(find.widgetWithText(PlotButton, 'Add node'));
  await _settle(tester);
  final map = tester.getRect(find.byType(FlutterMap));
  await tester.tapAt(map.center + fromCenter);
  await tester.pump(const Duration(milliseconds: 400));
  await _settle(tester);
  expect(find.byType(NodeEditorForm), findsOneWidget);
  await tester.enterText(
      find.descendant(of: find.byType(NodeEditorForm), matching: find.byType(TextField)).first,
      title);
  await tester.tap(find.widgetWithText(ChoiceChip, kind));
  await tester.pump();
  await tester.scrollUntilVisible(find.text('Save node'), 300,
      scrollable: find
          .descendant(of: find.byType(NodeEditorForm), matching: find.byType(Scrollable))
          .first);
  await tester.tap(find.text('Save node'));
  await _settle(tester);
}

void main() {
  testWidgets('start, finish, rest stop → the list reads start / rest stop / finish, '
      'and Generate ends at the finish', (tester) async {
    final (client, container) = await _pumpRouteTab(tester);

    await _place(tester, const Offset(-200, 100), 'start', 'Willowbrook Gazebo');
    await _place(tester, const Offset(100, 50), 'finish', 'Heart of Downtown');
    await _place(tester, const Offset(-150, -150), 'rest stop', 'Northeast Park');

    // The one ROUTE THROUGH list, in the right rail, in route order.
    Finder rowText(int i, String text) =>
        find.descendant(of: find.byKey(ValueKey('via-row-$i')), matching: find.text(text));
    expect(rowText(0, 'Willowbrook Gazebo'), findsOneWidget);
    expect(rowText(0, 'START'), findsOneWidget);
    expect(rowText(1, 'Northeast Park'), findsOneWidget);
    expect(rowText(2, 'Heart of Downtown'), findsOneWidget);
    expect(rowText(2, 'FINISH'), findsOneWidget);
    // Numbered on the map, too.
    expect(find.descendant(of: find.byType(FlutterMap), matching: find.text('3')), findsOneWidget);

    await tester.tap(find.widgetWithText(PlotButton, 'Generate'));
    await _settle(tester);

    final trip = container.read(currentTripProvider);
    final nodes = {for (final n in trip.days.single.segments.single.nodes) n.title: n.coord};
    expect(client.asked!.start, nodes['Willowbrook Gazebo']);
    expect(client.asked!.end, nodes['Heart of Downtown']);
    expect(client.asked!.via, [nodes['Northeast Park']]);
    expect(container.read(selectedSegmentProvider)?.$1, 'd1');
  });

  testWidgets('#653 — a passage built from nodes, generated, has turns on EXPORT', (tester) async {
    final (client, container) = await _pumpRouteTab(tester);
    await _place(tester, const Offset(-200, 100), 'start', 'Willowbrook Gazebo');
    await _place(tester, const Offset(100, 50), 'finish', 'Heart of Downtown');
    await tester.tap(find.widgetWithText(PlotButton, 'Generate'));
    await _settle(tester);
    final segment = container.read(currentTripProvider).days.single.segments.single;
    // The premise: the passage keeps no stored start (D71), which is what
    // every cue path used to key on.
    expect(segment.start, isNull);
    expect(segment.geometry, isNotNull);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) => ExportTab(trip: ref.watch(currentTripProvider))),
        ),
      ),
    ));
    await _settle(tester);

    final nodes = {for (final n in segment.nodes) n.title: n.coord};
    expect(client.cuesAsked!.start, nodes['Willowbrook Gazebo']);
    expect(client.cuesAsked!.end, nodes['Heart of Downtown']);
    expect(find.text('Turn left onto Lake Brandt Rd'), findsOneWidget);
    expect(find.textContaining('unavailable'), findsNothing);
  });
}
