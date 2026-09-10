// Issue #344 — the Route tab's half of `Move on the map`: the map that shows
// the alternates, and the gesture the card asks for.
//
// Two things are being pinned. First, an alternate stopped existing on the map
// the instant it was created (#324 drew only the *draft*), which made moving a
// fork impossible by construction — an Author cannot drag a mark they cannot
// see. Second, the request to move one arrives from the Logistics tab, on a
// tab where there is no map at all, so it has to survive the switch and open
// the gesture on arrival.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/route_tab.dart';
import 'package:plotlines_client/presentation/widgets/alternate_move_bar.dart';
import 'package:plotlines_client/presentation/widgets/plot_toggle_chip.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';
import 'package:plotlines_client/state/providers.dart';
import 'support/display_units.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

/// The map layer leaves a ticker a single `pump()` does not settle — the same
/// short-pump loop the other map-bearing screen tests use.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const _route = <Coord>[
  [-105.4, 40.0],
  [-105.0, 40.0],
];

Alternate _alternate(String id, {String? label, double lon = -105.3}) => Alternate(
      id: id,
      kind: 'extension',
      intent: 'branch',
      label: label,
      geometry: LineString(
        coordinates: [
          [lon, 40.0],
          [lon + 0.1, 40.05],
          [lon + 0.2, 40.0],
        ],
        source: 'authored',
      ),
      divergesAtM: haversineM(_route.first, [lon, 40.0]),
      rejoinsAtM: haversineM(_route.first, [lon + 0.2, 40.0]),
    );

Segment _leg(List<Alternate> alternates) => Segment(
      id: 's1',
      mode: 'cycling',
      shape: 'point_to_point',
      start: _route.first,
      end: _route.last,
      geometry: LineString(coordinates: _route),
      alternates: alternates,
    );

Trip _trip(Segment segment) => Trip(
      id: 't1',
      title: 'Trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: [Day(id: 'd1', index: 1, segments: [segment])],
    );

Future<ProviderContainer> _pumpTab(WidgetTester tester, Trip trip) async {
  // A desktop-sized surface. The tab is a three-column workspace — weights
  // rail, map, metrics rail — and the gesture panel sits over the map at a
  // fixed width; at the 800×600 test default the panel overhangs the weights
  // rail and its controls are unreachable, which is a property of the test
  // window rather than of the layout.
  tester.view.physicalSize = const Size(1800, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(overrides: [
    metricUnits(),
    sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
  ]);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(trip);
  container.read(selectedSegmentProvider.notifier).state = ('d1', 's1');
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
  return container;
}

void main() {
  group('alternateLinesFor — the alternates that stay drawn', () {
    test('draws every alternate on the passage', () {
      final lines = alternateLinesFor(_leg([
        _alternate('a1'),
        _alternate('a2', lon: -105.2),
      ]));
      expect(lines, hasLength(2));
      expect(lines.first.first, const [-105.3, 40.0]);
    });

    test('leaves out the one in hand — it draws as the line being moved', () {
      final lines = alternateLinesFor(
        _leg([_alternate('a1'), _alternate('a2', lon: -105.2)]),
        exceptId: 'a1',
      );
      expect(lines, hasLength(1));
      expect(lines.single.first, const [-105.2, 40.0]);
    });

    test('a passage with nothing on it draws nothing', () {
      expect(alternateLinesFor(_leg(const [])), isEmpty);
      expect(alternateLinesFor(null), isEmpty);
    });
  });

  group('the gesture the card asks for', () {
    testWidgets('a request from another tab opens the move gesture on arrival',
        (tester) async {
      final container = await _pumpTab(
          tester, _trip(_leg([_alternate('a1', label: 'Past the Sugarloaf mine')])));

      expect(find.byType(AlternateMoveBar), findsNothing);

      // What the Logistics tab's row sets on the way to switching tabs.
      container.read(alternateToMoveProvider.notifier).state = 'a1';
      await _settle(tester);

      expect(find.byType(AlternateMoveBar), findsOneWidget);
      expect(find.text('MOVING PAST THE SUGARLOAF MINE'), findsOneWidget);
      // Consumed, so it cannot re-fire on the next rebuild.
      expect(container.read(alternateToMoveProvider), isNull);
    });

    testWidgets('cancelling leaves the trip untouched', (tester) async {
      final container =
          await _pumpTab(tester, _trip(_leg([_alternate('a1', label: 'Toe River road')])));
      final before = container
          .read(currentTripProvider)
          .days
          .single
          .segments
          .single
          .alternates
          .single
          .geometry
          .coordinates;

      container.read(alternateToMoveProvider.notifier).state = 'a1';
      await _settle(tester);
      // Grab a handle, so there is something in hand to throw away.
      await tester.tap(find.text('Leaves'));
      await _settle(tester);
      await tester.tap(find.text('Cancel'));
      await _settle(tester);

      expect(find.byType(AlternateMoveBar), findsNothing);
      expect(
        container.read(currentTripProvider).days.single.segments.single.alternates.single
            .geometry
            .coordinates,
        before,
      );
    });

    testWidgets('a request naming an alternate that is not there opens nothing',
        (tester) async {
      final container = await _pumpTab(tester, _trip(_leg([_alternate('a1')])));
      container.read(alternateToMoveProvider.notifier).state = 'gone';
      await _settle(tester);
      expect(find.byType(AlternateMoveBar), findsNothing);
    });

    testWidgets('the handle picker lists the marks and the shaping points',
        (tester) async {
      final container =
          await _pumpTab(tester, _trip(_leg([_alternate('a1', label: 'The mine road')])));
      container.read(alternateToMoveProvider.notifier).state = 'a1';
      await _settle(tester);

      final chips = tester
          .widgetList<PlotToggleChip>(find.byType(PlotToggleChip))
          .map((c) => c.label)
          .toList();
      expect(chips, containsAll(<String>['Leaves', 'Point 1', 'Rejoins']));
    });
  });
}
