// Issue #657 — the EXPORT tab's dead ends and silent failures, the last step
// of the Author flow (PR #651's trace, F9–F12 and F23):
//
// - F9: a failed itinerary write said nothing (`try`/`finally`, no catch);
// - F10: print blocked by stale work offered only Close;
// - F11: a failed cue derivation had no way to try again;
// - F12: device export swallowed a passage's cue failure and said "Exported";
// - F23: per-day export replaced same-named files without asking.
//
// The native file dialogs are answered through `ExportFileDialogs`; a real
// file write runs under `tester.runAsync`, since dart:io does not complete
// inside a widget test's fake clock.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';
import 'package:printing/printing.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/export_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';
import 'support/display_units.dart';

Segment _passage(String id, {String? title, bool stale = false}) => Segment(
      id: id,
      title: title,
      mode: 'cycling',
      shape: 'point_to_point',
      start: const [-79.50, 36.10],
      end: const [-79.40, 36.15],
      geometry: LineString(coordinates: const [[-79.50, 36.10], [-79.40, 36.15]]),
      metrics: RouteMetrics(distanceM: 9000),
      solve: SolveProvenance(solvedAt: '2026-10-08T00:00:00Z', stale: stale),
    );

class _FakeRoutingClient extends RoutingClient {
  _FakeRoutingClient({this.failCuesFor = const {}, this.regionFails = 0}) : super('http://fake');
  final Set<String> failCuesFor;

  /// How many `ensureRegion` calls fail before one succeeds.
  int regionFails;

  @override
  Future<String> ensureRegion(List<double> bboxWsen, {String networkType = 'bike', bool retry = false}) async {
    if (regionFails > 0) {
      regionFails--;
      throw RoutingException(503, jsonEncode({'detail': 'the sidecar could not be reached'}));
    }
    return 'region-1';
  }

  @override
  Future<CueSheet> cuesFor(Segment segment, {required String region}) async {
    if (failCuesFor.contains(segment.id)) {
      throw RoutingException(500, jsonEncode({'detail': 'cue derivation failed'}));
    }
    return CueSheet(generatedAt: '2026-10-08T00:00:00Z', cues: [
      Cue(id: 't', sequence: 0, distanceAlongM: 1000, kind: 'turn', modifier: 'left',
          instruction: 'Turn left off ${segment.id}'),
    ]);
  }

  @override
  Future<Map<String, dynamic>> about() async => throw RoutingException(503, '{}');

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
  }) async =>
      Segment(
        id: 'x',
        mode: mode,
        shape: shape,
        start: start,
        end: end,
        via: via,
        geometry: LineString(coordinates: [start, end!]),
        metrics: RouteMetrics(distanceM: 9000),
        solve: SolveProvenance(solvedAt: '2026-10-08T01:00:00Z'),
      );
}

Future<ProviderContainer> _pump(WidgetTester tester, List<Day> days,
    {RoutingClient? client, bool bbox = true}) async {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(overrides: [
    metricUnits(),
    routingClientProvider.overrideWithValue(client ?? _FakeRoutingClient()),
    if (bbox)
      tripBboxProvider.overrideWith((ref) => TripBboxNotifier()
        ..set(const TripBbox(minLat: 35.9, minLon: -79.6, maxLat: 36.3, maxLon: -79.2))),
  ]);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(Trip(
        id: 't',
        title: 'Greensboro',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        days: days,
      ));
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(builder: (context, ref, _) => ExportTab(trip: ref.watch(currentTripProvider))),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return container;
}

Future<void> _pumpFor(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  late Directory tmp;
  final saveLocation = ExportFileDialogs.saveLocation;
  final directory = ExportFileDialogs.directory;
  setUp(() => tmp = Directory.systemTemp.createTempSync('plotlines_657_'));
  tearDown(() {
    ExportFileDialogs.saveLocation = saveLocation;
    ExportFileDialogs.directory = directory;
    tmp.deleteSync(recursive: true);
  });

  testWidgets('F9 — a failed itinerary write shows the export-failed dialog', (tester) async {
    ExportFileDialogs.saveLocation = (_) async => '${tmp.path}/no-such-folder/itinerary.md';
    await _pump(tester, [Day(id: 'd1', index: 1, segments: [_passage('p1')])]);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(PlotButton, 'Export itinerary (MD)'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    expect(find.text('Export didn\'t finish'), findsOneWidget);
    expect(find.textContaining('couldn\'t be written'), findsOneWidget);
  });

  testWidgets('F10 — the stale print block opens the stale list, and the preview comes back',
      (tester) async {
    await _pump(tester, [Day(id: 'd1', index: 1, segments: [_passage('p1', stale: true)])]);

    await tester.tap(find.widgetWithText(PlotButton, 'Print preview').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('1 stale item needs re-solving'), findsOneWidget);

    await tester.tap(find.widgetWithText(PlotButton, 'Open stale list'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PlotButton, 'Re-solve all'));
    await _pumpFor(tester, frames: 10);

    expect(find.byType(PdfPreview), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Day 1'), findsOneWidget);
  });

  testWidgets('F11 — a failed cue derivation has Try again, which reloads the sheet',
      (tester) async {
    await _pump(tester, [Day(id: 'd1', index: 1, segments: [_passage('p1')])],
        client: _FakeRoutingClient(regionFails: 1));
    expect(find.textContaining('is unavailable right now'), findsOneWidget);
    expect(find.text('Turn left off p1'), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, 'Try again'));
    await tester.pumpAndSettle();

    expect(find.textContaining('is unavailable right now'), findsNothing);
    expect(find.text('Turn left off p1'), findsOneWidget);
  });

  group('device export', () {
    Future<void> toggleCueSheet(WidgetTester tester) async {
      final row = find.ancestor(of: find.text('Cue sheet (turn points)'), matching: find.byType(Row)).first;
      await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await tester.pump();
    }

    testWidgets('F12 — a passage whose turns failed is named before anything is written',
        (tester) async {
      final out = '${tmp.path}/greensboro.gpx';
      ExportFileDialogs.saveLocation = (_) async => out;
      await _pump(
          tester,
          [Day(id: 'd1', index: 1, segments: [_passage('p1', title: 'Morning ride'), _passage('p2')])],
          client: _FakeRoutingClient(failCuesFor: {'p1'}));
      await toggleCueSheet(tester);

      await tester.tap(find.widgetWithText(PlotButton, 'Export GPX file'));
      await tester.pumpAndSettle();

      expect(find.text('One passage has no turns'), findsOneWidget);
      expect(find.textContaining('Day 1, Morning ride'), findsOneWidget);
      await tester.tap(find.widgetWithText(PlotButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(File(out).existsSync(), isFalse);

      await tester.tap(find.widgetWithText(PlotButton, 'Export GPX file'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(PlotButton, 'Export without their turns'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(File(out).existsSync(), isTrue);
    });

    testWidgets('F23 — per-day export names the files it would replace, and Cancel keeps them',
        (tester) async {
      ExportFileDialogs.directory = () async => tmp.path;
      final existing = File('${tmp.path}/Greensboro_day1.gpx')..writeAsStringSync('mine');
      await _pump(tester, [
        Day(id: 'd1', index: 1, segments: [_passage('p1')]),
        Day(id: 'd2', index: 2, segments: [_passage('p2')]),
      ]);
      await tester.tap(find.text('PER DAY'));
      await tester.pump();

      await tester.tap(find.widgetWithText(PlotButton, 'Export 2 GPX files'));
      await tester.pumpAndSettle();

      expect(find.text('Replace 1 file?'), findsOneWidget);
      expect(find.textContaining('Greensboro_day1.gpx'), findsOneWidget);
      await tester.tap(find.widgetWithText(PlotButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(existing.readAsStringSync(), 'mine');
      expect(File('${tmp.path}/Greensboro_day2.gpx').existsSync(), isFalse);
    });
  });
}
