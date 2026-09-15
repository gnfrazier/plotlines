// Issue #393 — the cue sheet's first rendering of a promoted anchor's
// narrative role, now that `Role.dayId`/`Role.segmentId` (issue #384) says
// which day/segment it belongs to. Mirrors `export_tab_day_nodes_test.dart`'s
// two-path structure (`_entriesFromAuthoredContent` / `_entriesFromCueSheets`)
// and adds the reveal dimension neither of that file's cases needed: the
// Export tab is the Author's own "preview-as-self" (`RevealResolver`,
// `hasArrived: true`), so an on_arrival role shows in full here even though
// the same `DayCueSection` withholds it for a Character (H13).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/presentation/screens/character_read_screen.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/export_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/providers.dart';
import 'package:plotlines_client/state/trip_bbox_provider.dart';

Trip _tripWith({required Day day, required List<Anchor> anchors}) => Trip(
      id: 't1',
      title: 'Test trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: [day],
      anchors: anchors,
    );

Future<ProviderContainer> _pumpExport(
  WidgetTester tester, {
  required Day day,
  required List<Anchor> anchors,
  List<Override> extra = const [],
}) async {
  final container = ProviderContainer(overrides: extra);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(_tripWith(day: day, anchors: anchors));
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

Future<ProviderContainer> _pumpCharacterRead(
  WidgetTester tester, {
  required Day day,
  required List<Anchor> anchors,
}) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  final trip = _tripWith(day: day, anchors: anchors);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: CharacterReadScreen(trip: trip))),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  group('fallback path (_entriesFromAuthoredContent)', () {
    testWidgets('a day-only narrative anchor role shows up after the day\'s other entries',
        (tester) async {
      final day = Day(id: 'day-1', index: 1, kind: 'rest');
      final anchors = [
        Anchor(id: 'a1', coord: const [-105.3, 40.0], roles: [
          Role(
            id: 'r1',
            kind: RoleKind.narrative,
            reveal: RevealPolicy.alwaysVisible,
            title: 'Historic District',
            dayId: 'day-1',
          ),
        ]),
      ];
      await _pumpExport(tester, day: day, anchors: anchors);

      expect(find.text('Historic District'), findsOneWidget);
    });

    testWidgets('a segment-scoped narrative anchor role shows up next to that segment\'s cues',
        (tester) async {
      final day = Day(id: 'day-1', index: 1, segments: [
        Segment(
          id: 'seg-1',
          mode: 'cycling',
          shape: 'point_to_point',
          metrics: RouteMetrics(distanceM: 12000),
        ),
      ]);
      final anchors = [
        Anchor(id: 'a1', coord: const [-105.3, 40.0], roles: [
          Role(
            id: 'r1',
            kind: RoleKind.narrative,
            reveal: RevealPolicy.alwaysVisible,
            title: 'Trailhead Overlook',
            dayId: 'day-1',
            segmentId: 'seg-1',
          ),
        ]),
      ];
      await _pumpExport(tester, day: day, anchors: anchors);

      expect(find.text('Trailhead Overlook'), findsOneWidget);
    });

    testWidgets('a provision role attached to the day is not rendered as a plot point',
        (tester) async {
      final day = Day(id: 'day-1', index: 1, kind: 'rest');
      final anchors = [
        Anchor(id: 'a1', coord: const [-105.3, 40.0], roles: [
          Role(
            id: 'r1',
            kind: RoleKind.provision,
            reveal: RevealPolicy.alwaysVisible,
            title: 'Water source',
            dayId: 'day-1',
          ),
        ]),
      ];
      await _pumpExport(tester, day: day, anchors: anchors);

      expect(find.text('Water source'), findsNothing);
    });

    testWidgets(
        'the Export tab is the Author\'s own preview-as-self — an on_arrival role shows in full',
        (tester) async {
      final day = Day(id: 'day-1', index: 1, kind: 'rest');
      final anchors = [
        Anchor(id: 'a1', coord: const [-105.3, 40.0], roles: [
          Role(
            id: 'r1',
            kind: RoleKind.narrative,
            reveal: RevealPolicy.onArrival,
            title: 'The Ambush Site',
            dayId: 'day-1',
          ),
        ]),
      ];
      await _pumpExport(tester, day: day, anchors: anchors);

      expect(find.text('The Ambush Site'), findsOneWidget);
      expect(find.text('Held for arrival'), findsNothing);
    });
  });

  group('real path (_entriesFromCueSheets)', () {
    testWidgets('a segment-scoped narrative anchor role shows up after the derived cues',
        (tester) async {
      final day = Day(id: 'day-1', index: 1, segments: [
        Segment(
          id: 'seg-1',
          mode: 'cycling',
          shape: 'point_to_point',
          start: const [-105.3, 40.0],
          metrics: RouteMetrics(distanceM: 12000),
        ),
      ]);
      final anchors = [
        Anchor(id: 'a1', coord: const [-105.3, 40.0], roles: [
          Role(
            id: 'r1',
            kind: RoleKind.narrative,
            reveal: RevealPolicy.alwaysVisible,
            title: 'Trailhead Overlook',
            dayId: 'day-1',
            segmentId: 'seg-1',
          ),
        ]),
      ];
      final sheet = CueSheet(generatedAt: '2026-01-01T00:00:00Z', cues: [
        Cue(id: 'c1', sequence: 0, distanceAlongM: 0, kind: 'start', instruction: 'Start'),
        Cue(id: 'c2', sequence: 1, distanceAlongM: 12000, kind: 'finish', instruction: 'Finish'),
      ]);
      await _pumpExport(tester, day: day, anchors: anchors, extra: [
        tripBboxProvider.overrideWith(
          (ref) => TripBboxNotifier()
            ..set(const TripBbox(minLat: 39.9, minLon: -105.4, maxLat: 40.1, maxLon: -105.1)),
        ),
        routingClientProvider.overrideWithValue(_FakeRoutingClient(sheet)),
      ]);

      expect(find.text('Finish'), findsOneWidget);
      expect(find.text('Trailhead Overlook'), findsOneWidget);
    });
  });

  group('Character read screen — the shared DayCueSection is reveal-gated there', () {
    testWidgets('an on_arrival role withheld with no live arrival signal reads "Held for arrival"',
        (tester) async {
      final day = Day(id: 'day-1', index: 1, kind: 'rest');
      final anchors = [
        Anchor(id: 'a1', coord: const [-105.3, 40.0], roles: [
          Role(
            id: 'r1',
            kind: RoleKind.narrative,
            reveal: RevealPolicy.onArrival,
            title: 'The Ambush Site',
            dayId: 'day-1',
          ),
        ]),
      ];
      await _pumpCharacterRead(tester, day: day, anchors: anchors);

      expect(find.text('The Ambush Site'), findsNothing);
      // Two independent reveal-gated surfaces both correctly withhold it:
      // the trip-wide Plot Points list (H13) and this story's own cue-sheet
      // entry — both "Held for arrival," neither leaking the title.
      expect(find.text('Held for arrival'), findsNWidgets(2));
    });

    testWidgets('an always-visible role shows its title on the Character read screen too',
        (tester) async {
      final day = Day(id: 'day-1', index: 1, kind: 'rest');
      final anchors = [
        Anchor(id: 'a1', coord: const [-105.3, 40.0], roles: [
          Role(
            id: 'r1',
            kind: RoleKind.narrative,
            reveal: RevealPolicy.alwaysVisible,
            title: 'Historic District',
            dayId: 'day-1',
          ),
        ]),
      ];
      await _pumpCharacterRead(tester, day: day, anchors: anchors);

      expect(find.text('Historic District'), findsWidgets);
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
