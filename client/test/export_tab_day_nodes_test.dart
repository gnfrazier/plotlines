// Issue #43's lodging UX pass — `Day.nodes` (a rest day's POIs, and since
// Story C7 a lodging/campground choice placed at the day level) never
// reached the Export tab's cue-sheet preview, in either the real
// (`_entriesFromCueSheets`) or the fallback (`_entriesFromAuthoredContent`)
// derivation path — despite this file's own header doc comment already
// claiming otherwise ("the cue-sheet preview below... reads the same
// day-scoped nodes"). Both paths now append them, tagged with `poiType`
// the same way a segment node already was.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/export_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

Future<ProviderContainer> _pump(WidgetTester tester, Day day, {List<Override> extra = const []}) async {
  final container = ProviderContainer(overrides: extra);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(
        Trip(
          id: 't1',
          title: 'Test trip',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          days: [day],
        ),
      );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ExportTab(trip: ref.watch(currentTripProvider)),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Node _lodging({required String title, required String poiType}) =>
    Node(id: 'lodge-1', kind: NodeKind.poi, coord: const [-105.29, 40.0], title: title, poiType: poiType);

void main() {
  group('fallback path (_entriesFromAuthoredContent — no trip bbox, no sidecar call)', () {
    testWidgets('a rest day\'s lodging choice shows up, tagged with its type', (tester) async {
      final day = Day(
        id: 'day-1',
        index: 1,
        kind: 'rest',
        nodes: [_lodging(title: 'Grand Hotel', poiType: 'hotel')],
      );
      await _pump(tester, day);

      expect(find.text('Grand Hotel'), findsWidgets);
      expect(find.text('HOTEL'), findsOneWidget);
    });

    testWidgets('a route day\'s day-level lodging choice shows up after the segment\'s own cues',
        (tester) async {
      final day = Day(id: 'day-1', index: 1, segments: [
        Segment(
          id: 'seg-1',
          mode: 'cycling',
          shape: 'point_to_point',
          metrics: RouteMetrics(distanceM: 12000),
          nodes: [
            Node(id: 'n1', kind: NodeKind.poi, coord: const [-105.29, 40.0], title: 'Scenic view'),
          ],
        ),
      ], nodes: [
        _lodging(title: 'Pine Camp', poiType: 'campsite'),
      ]);
      await _pump(tester, day);

      expect(find.text('Scenic view'), findsOneWidget);
      expect(find.text('Pine Camp'), findsWidgets);
      expect(find.text('CAMPSITE'), findsOneWidget);
    });

    testWidgets('a day with only day-level nodes still renders its section, not an empty heading',
        (tester) async {
      // Regression: `_DayCueSection.build`'s own empty-check already tested
      // `day.nodes.isEmpty` (implying it expected to show them) while
      // neither derivation path actually did — a rest day used to render
      // "DAY 1" with nothing under it.
      final day = Day(
        id: 'day-1',
        index: 1,
        kind: 'rest',
        nodes: [_lodging(title: 'Grand Hotel', poiType: 'hotel')],
      );
      await _pump(tester, day);

      expect(find.text('DAY 1'), findsOneWidget);
      expect(find.text('Grand Hotel'), findsWidgets);
    });
  });

  group('real path (_entriesFromCueSheets — a trip bbox and a resolving sidecar)', () {
    Future<ProviderContainer> pumpReal(WidgetTester tester, Day day, CueSheet sheet) => _pump(
          tester,
          day,
          extra: [
            tripBboxProvider.overrideWith(
              (ref) => TripBboxNotifier()..set(const TripBbox(minLat: 39.9, minLon: -105.4, maxLat: 40.1, maxLon: -105.1)),
            ),
            routingClientProvider.overrideWithValue(_FakeRoutingClient(sheet)),
          ],
        );

    testWidgets('a route day\'s day-level lodging choice shows up after the derived cues',
        (tester) async {
      final day = Day(
        id: 'day-1',
        index: 1,
        segments: [
          Segment(
            id: 'seg-1',
            mode: 'cycling',
            shape: 'point_to_point',
            start: const [-105.3, 40.0],
            metrics: RouteMetrics(distanceM: 12000),
          ),
        ],
        nodes: [_lodging(title: 'Grand Hotel', poiType: 'hotel')],
      );
      final sheet = CueSheet(generatedAt: '2026-01-01T00:00:00Z', cues: [
        Cue(id: 'c1', sequence: 0, distanceAlongM: 0, kind: 'start', instruction: 'Start'),
        Cue(id: 'c2', sequence: 1, distanceAlongM: 12000, kind: 'finish', instruction: 'Finish'),
      ]);
      await pumpReal(tester, day, sheet);

      expect(find.text('Finish'), findsOneWidget);
      expect(find.text('Grand Hotel'), findsWidgets);
      expect(find.text('HOTEL'), findsOneWidget);
    });
  });
}

class _FakeRoutingClient extends RoutingClient {
  _FakeRoutingClient(this.sheet) : super('http://fake');
  final CueSheet sheet;

  @override
  Future<String> ensureRegion(List<double> bboxWsen, {String networkType = 'bike', bool retry = false}) async =>
      'region-1';

  @override
  Future<CueSheet> cuesFor(Segment segment, {required String region}) async => sheet;
}
