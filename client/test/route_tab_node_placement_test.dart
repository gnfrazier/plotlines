// Issue #588 — node placement on the Route tab has a way out.
//
// Placement used to be armed by a button that then relabelled itself "Tap map
// to place node…", and nothing else disarmed it: not Esc, not selecting
// another passage, not switching day. A tap after any of those placed a node
// on whatever was selected at the time. Every way out pinned here asserts the
// same two things — the mode is off, and the trip is the very same object it
// was before placement was armed (nothing marked stale, nothing for autosave
// to write).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/route_tab.dart';
import 'package:plotlines_client/presentation/widgets/alternate_draft_bar.dart';
import 'package:plotlines_client/presentation/widgets/node_editor_sheet.dart';
import 'package:plotlines_client/presentation/widgets/node_placement_bar.dart';
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

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const _route = <Coord>[
  [-105.4, 40.0],
  [-105.0, 40.0],
];

Segment _leg(String id) => Segment(
      id: id,
      mode: 'cycling',
      shape: 'point_to_point',
      start: _route.first,
      end: _route.last,
      geometry: LineString(coordinates: _route),
    );

Trip _trip() => Trip(
      id: 't1',
      title: 'Trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: [
        Day(id: 'd1', index: 1, segments: [_leg('s1'), _leg('s2')]),
        Day(id: 'd2', index: 2, segments: [_leg('s3')]),
      ],
    );

int _nodeCount(Trip trip) => [
      for (final d in trip.days)
        for (final s in d.segments) ...s.nodes,
    ].length;

Future<ProviderContainer> _pumpTab(WidgetTester tester,
    {Trip? trip, (String, String)? selection = ('d1', 's1')}) async {
  tester.view.physicalSize = const Size(1800, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(overrides: [
    metricUnits(),
    sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
  ]);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(trip ?? _trip());
  container.read(selectedSegmentProvider.notifier).state = selection;
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) {
            final trip = ref.watch(currentTripProvider);
            // The shell's own day switch (#323): the selection moves with it.
            return RouteTab(
              trip: trip,
              activeDayId: ref.watch(selectedSegmentProvider)?.$1 ?? 'd1',
              onSelectDay: (id) =>
                  ref.read(selectedSegmentProvider.notifier).state = daySelection(trip, id),
            );
          },
        ),
      ),
    ),
  ));
  await _settle(tester);
  return container;
}

Future<void> _arm(WidgetTester tester) async {
  await tester.tap(find.text('Add node'));
  await _settle(tester);
  expect(find.byType(NodePlacementBar), findsOneWidget);
}

/// A tap on the open map, clear of the gesture panel in its top-right corner.
/// Long enough after the last pump that flutter_map's double-tap window has
/// closed and the tap reaches `onTap`.
Future<void> _tapMap(WidgetTester tester) async {
  final map = tester.getRect(find.byType(FlutterMap));
  await tester.tapAt(map.center + Offset(-map.width / 4, map.height / 4));
  await tester.pump(const Duration(milliseconds: 400));
  await _settle(tester);
}

final _cancelButton =
    find.descendant(of: find.byType(NodePlacementBar), matching: find.text('Cancel'));

void _expectDisarmed(ProviderContainer container, Trip before) {
  expect(find.byType(NodePlacementBar), findsNothing);
  expect(find.text('Add node'), findsOneWidget);
  expect(identical(container.read(currentTripProvider), before), isTrue,
      reason: 'cancelling placement must not touch the trip');
}

void main() {
  testWidgets('armed placement shows its own panel with a Cancel, not a relabelled button',
      (tester) async {
    await _pumpTab(tester);
    await _arm(tester);

    expect(find.text('PLACING A NODE'), findsOneWidget);
    expect(find.textContaining('Click the map to place a node'), findsOneWidget);
    expect(_cancelButton, findsOneWidget);
    expect(find.text('Add node'), findsNothing);
    expect(find.textContaining('Tap map to place node'), findsNothing);
    // The mode reads on the map itself: a crosshair over it.
    final region = tester.widget<MouseRegion>(find
        .ancestor(of: find.byType(FlutterMap), matching: find.byType(MouseRegion))
        .first);
    expect(region.cursor, SystemMouseCursors.precise);
  });

  testWidgets('arm → Cancel disarms and leaves the trip untouched', (tester) async {
    final container = await _pumpTab(tester);
    final before = container.read(currentTripProvider);
    await _arm(tester);

    await tester.tap(_cancelButton);
    await _settle(tester);

    _expectDisarmed(container, before);
    final region = tester.widget<MouseRegion>(find
        .ancestor(of: find.byType(FlutterMap), matching: find.byType(MouseRegion))
        .first);
    expect(region.cursor, MouseCursor.defer);

    // And a tap afterwards places nothing.
    await _tapMap(tester);
    expect(find.byType(NodeEditorForm), findsNothing);
    expect(_nodeCount(container.read(currentTripProvider)), 0);
  });

  testWidgets('arm → Esc disarms', (tester) async {
    final container = await _pumpTab(tester);
    final before = container.read(currentTripProvider);
    await _arm(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);

    _expectDisarmed(container, before);
  });

  testWidgets('Esc backs out of an alternate draft as well', (tester) async {
    final container = await _pumpTab(tester);
    final before = container.read(currentTripProvider);
    await tester.tap(find.text('Add alternate'));
    await _settle(tester);
    expect(find.byType(AlternateDraftBar), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);

    expect(find.byType(AlternateDraftBar), findsNothing);
    expect(identical(container.read(currentTripProvider), before), isTrue);
  });

  testWidgets('arm → select another passage disarms; a tap then places nothing',
      (tester) async {
    final container = await _pumpTab(tester);
    final before = container.read(currentTripProvider);
    await _arm(tester);

    container.read(selectedSegmentProvider.notifier).state = ('d1', 's2');
    await _settle(tester);

    _expectDisarmed(container, before);
    await _tapMap(tester);
    expect(find.byType(NodeEditorForm), findsNothing);
    expect(_nodeCount(container.read(currentTripProvider)), 0);
  });

  testWidgets('arm → switch day disarms', (tester) async {
    final container = await _pumpTab(tester);
    final before = container.read(currentTripProvider);
    await _arm(tester);

    await tester.tap(find.text('DAY 2'));
    await _settle(tester);

    expect(container.read(selectedSegmentProvider), ('d2', 's3'));
    _expectDisarmed(container, before);
  });

  testWidgets('arm → the selected passage goes away disarms', (tester) async {
    final container = await _pumpTab(tester);
    await _arm(tester);

    // Removal leaves the selection naming a passage that no longer exists —
    // the same state an undo past the passage's creation leaves.
    container.read(currentTripProvider.notifier).removeSegment('d1', 's1');
    await _settle(tester);

    expect(container.read(selectedSegmentProvider), ('d1', 's1'));
    expect(find.byType(NodePlacementBar), findsNothing);
  });

  testWidgets('arm → tap → dismiss the sheet adds no node and does not re-arm',
      (tester) async {
    final container = await _pumpTab(tester);
    final before = container.read(currentTripProvider);
    await _arm(tester);

    await _tapMap(tester);
    expect(find.byType(NodeEditorForm), findsOneWidget);
    // The tap disarmed placement before the sheet opened.
    expect(find.byType(NodePlacementBar), findsNothing);

    // Dismiss without saving: tap the scrim above the sheet.
    await tester.tapAt(const Offset(20, 20));
    await _settle(tester);

    expect(find.byType(NodeEditorForm), findsNothing);
    _expectDisarmed(container, before);
    expect(_nodeCount(container.read(currentTripProvider)), 0);
  });

  // #626 (option B, replacing #620's disabled button) — on a route day with
  // no passage, Add node is live: the node placed starts the passage. A
  // passage needs a mode, so it is the trip's one mode or the Author's pick.
  group('a day with no passage', () {
    Trip blankDay({Set<String> modes = const {'cycling'}}) => Trip(
          id: 't2',
          title: 'Blank',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          modes: modes,
          days: [Day(id: 'd1', index: 1)],
        );

    testWidgets('with one trip mode, Add node arms at once and says it starts the passage',
        (tester) async {
      await _pumpTab(tester, trip: blankDay(), selection: ('d1', 'gone'));
      expect(find.textContaining('Add a passage to this day first'), findsNothing);
      await _arm(tester);
      expect(find.textContaining("It starts this day's passage: Ride"), findsOneWidget);
    });

    testWidgets('placing the first node creates the passage with it, routed through',
        (tester) async {
      final container = await _pumpTab(tester, trip: blankDay(), selection: null);
      await _arm(tester);
      await _tapMap(tester);
      expect(find.byType(NodeEditorForm), findsOneWidget);
      final through = tester.widget<CheckboxListTile>(
          find.byKey(const ValueKey('node-route-through')));
      expect(through.value, isTrue, reason: 'on a node-built passage the nodes are the route');

      // The form is a lazy list; scroll it until Save is built.
      await tester.scrollUntilVisible(find.text('Save node'), 300,
          scrollable: find
              .descendant(of: find.byType(NodeEditorForm), matching: find.byType(Scrollable))
              .first);
      await tester.tap(find.text('Save node'));
      await _settle(tester);

      final day = container.read(currentTripProvider).days.single;
      expect(day.segments, hasLength(1));
      final passage = day.segments.single;
      expect(passage.mode, 'cycling');
      expect(passage.shape, 'point_to_point');
      expect(passage.start, isNull);
      expect(passage.nodes, hasLength(1));
      expect(passage.via, [passage.nodes.single.coord]);
      expect(routesFromNodes(passage), isTrue);
      expect(container.read(selectedSegmentProvider), ('d1', passage.id));
      // The next node goes on the passage that now exists: the ordinary path.
      expect(find.widgetWithText(PlotButton, 'Add node'), findsOneWidget);
    });

    testWidgets('dismissing the editor creates no passage', (tester) async {
      final container = await _pumpTab(tester, trip: blankDay(), selection: null);
      final before = container.read(currentTripProvider);
      await _arm(tester);
      await _tapMap(tester);
      await tester.tapAt(const Offset(20, 20));
      await _settle(tester);

      expect(identical(container.read(currentTripProvider), before), isTrue);
    });

    testWidgets('with two trip modes the Author picks; Cancel arms nothing', (tester) async {
      final container =
          await _pumpTab(tester, trip: blankDay(modes: {'cycling', 'hiking'}), selection: null);
      final before = container.read(currentTripProvider);
      await tester.tap(find.text('Add node'));
      await _settle(tester);
      expect(find.text('Start a passage'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await _settle(tester);
      expect(find.byType(NodePlacementBar), findsNothing);
      expect(identical(container.read(currentTripProvider), before), isTrue);

      await tester.tap(find.text('Add node'));
      await _settle(tester);
      await tester.tap(find.text('Hike'));
      await _settle(tester);
      expect(find.textContaining("It starts this day's passage: Hike"), findsOneWidget);
    });

    testWidgets('Esc backs out of new-passage placement', (tester) async {
      final container = await _pumpTab(tester, trip: blankDay(), selection: null);
      final before = container.read(currentTripProvider);
      await _arm(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      _expectDisarmed(container, before);
    });
  });
}
