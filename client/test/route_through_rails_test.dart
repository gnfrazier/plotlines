// Issue #589 — the two rails' halves of "Route through this".
//
// The weights rail lists every point the route must reach, in order, by name,
// and lets the Author reorder or remove them. A routed-through node and a New
// Route map tap are the same concept there. The metrics rail reports, by name,
// whether the solved line reached each one; a missed point is called out
// with its distance rather than folded into a single yes/no.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/sidecar_manager.dart' show CapabilityStatus;
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/metrics_rail.dart';
import 'package:plotlines_client/presentation/widgets/weights_rail.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';
import 'support/display_units.dart';
import 'support/rail_tasks.dart';

const _start = <double>[-105.40, 40.0];
const _end = <double>[-105.00, 40.0];
const _lunch = <double>[-105.30, 40.0];
const _tap = <double>[-105.20, 40.0];
const _overlook = <double>[-105.10, 40.01]; // ~1.1 km north of the line

Segment _segment({
  String shape = 'point_to_point',
  List<Coord> via = const [_lunch, _tap],
  bool stale = false,
  TargetDistance? target,
}) =>
    Segment(
      id: 's1',
      mode: 'cycling',
      shape: shape,
      start: _start,
      end: shape == 'point_to_point' ? _end : null,
      via: via,
      targetDistance: target,
      nodes: [
        Node(id: 'n1', kind: NodeKind.restStop, coord: _lunch, title: 'Lunch'),
        Node(id: 'n2', kind: NodeKind.waypoint, coord: _overlook, title: 'Overlook'),
      ],
      geometry: LineString(coordinates: const [_start, _end]),
      metrics: RouteMetrics(distanceM: 34000),
      solve: SolveProvenance(stale: stale),
    );

Trip _trip(Segment s) => Trip(
      id: 't1',
      title: 'Trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: [Day(id: 'd1', index: 1, segments: [s])],
    );

Future<ProviderContainer> _pumpMetricsRail(WidgetTester tester, Segment s,
    {PlanningMode mode = PlanningMode.explore}) async {
  tester.view.physicalSize = const Size(600, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(overrides: [metricUnits()]);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(_trip(s));
  container.read(dayPlanningModeProvider('d1').notifier).state = mode;
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) {
            final trip = ref.watch(currentTripProvider);
            return MetricsRail(
              trip: trip,
              selectedSegment: trip.days.single.segments.single,
              elevationCapability: const CapabilityStatus(ready: true),
              displayFormat: const DisplayFormat(),
            );
          },
        ),
      ),
    ),
  ));
  await tester.pump();
  return container;
}

/// The rail scrolls; bring the row's control on screen before tapping it, or
/// the tap lands on whatever is drawn there instead.
Future<void> _tapInRow(WidgetTester tester, int row, String tooltip) async {
  final target = find.descendant(
      of: find.byKey(ValueKey('via-row-$row')), matching: find.byTooltip(tooltip));
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
}

Segment _seg(ProviderContainer c) => c.read(currentTripProvider).days.single.segments.single;

void main() {
  group('metrics rail — the one route-through list (#640)', () {
    testWidgets('lists a routed-through node by name and a map tap by position',
        (tester) async {
      await _pumpMetricsRail(tester, _segment());

      expect(find.text('ROUTE THROUGH'), findsOneWidget);
      expect(find.text('Lunch'), findsOneWidget);
      expect(find.text('Point 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('via-order-hint')), findsOneWidget);
    });

    testWidgets('reordering changes via and marks the passage stale', (tester) async {
      final c = await _pumpMetricsRail(tester, _segment());

      await _tapInRow(tester, 1, 'Move earlier');

      expect(_seg(c).via, const [_tap, _lunch]);
      expect(_seg(c).solve!.stale, isTrue);
    });

    testWidgets('a drag reorders too', (tester) async {
      final c = await _pumpMetricsRail(tester, _segment());
      final handle = find.descendant(
          of: find.byKey(const ValueKey('via-row-0')), matching: find.byIcon(Icons.drag_indicator));
      final rowHeight = tester.getSize(find.byKey(const ValueKey('via-row-0'))).height;
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(Offset(0, rowHeight * 0.2));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(_seg(c).via, const [_tap, _lunch]);
    });

    testWidgets('removing a node\'s point turns route-through off and keeps the node',
        (tester) async {
      final c = await _pumpMetricsRail(tester, _segment());

      await _tapInRow(tester, 0, 'Stop routing through this');

      expect(_seg(c).via, const [_tap]);
      expect(_seg(c).nodes.map((n) => n.id), contains('n1'));
      expect(_seg(c).solve!.stale, isTrue);
    });

    testWidgets('a start and a finish are pinned: no move controls, a lock instead',
        (tester) async {
      final s = _segment(via: const [_lunch, _tap, _overlook]);
      final pinnedEnds = s.copyWith(nodes: [
        Node(id: 'n1', kind: NodeKind.start, coord: _lunch, title: 'Lunch'),
        Node(id: 'n2', kind: NodeKind.finish, coord: _overlook, title: 'Overlook'),
      ]);
      final c = await _pumpMetricsRail(tester, pinnedEnds);

      for (final row in [0, 2]) {
        final r = find.byKey(ValueKey('via-row-$row'));
        expect(find.descendant(of: r, matching: find.byIcon(Icons.lock_outline)), findsOneWidget);
        expect(find.descendant(of: r, matching: find.byTooltip('Move earlier')), findsNothing);
      }
      expect(find.text('START'), findsOneWidget);
      expect(find.text('FINISH'), findsOneWidget);
      // The middle point can't move past either end.
      final mid = find.byKey(const ValueKey('via-row-1'));
      expect(
          tester.widget<IconButton>(find.descendant(
              of: mid, matching: find.widgetWithIcon(IconButton, Icons.arrow_upward))).onPressed,
          isNull);
      expect(_seg(c).via, const [_lunch, _tap, _overlook]);
    });

    testWidgets('three or more points show the target as advisory (A9a)', (tester) async {
      await _pumpMetricsRail(
        tester,
        _segment(
          shape: 'loop',
          via: const [_lunch, _tap, _overlook],
          target: TargetDistance(valueM: 30000, minM: 27000, maxM: 33000, advisory: true),
        ),
      );
      expect(find.byKey(const ValueKey('via-advisory')), findsOneWidget);
    });

    testWidgets('one or two points keep the banded target — no advisory line',
        (tester) async {
      await _pumpMetricsRail(
        tester,
        _segment(
          shape: 'loop',
          target: TargetDistance(valueM: 30000, minM: 27000, maxM: 33000),
        ),
      );
      expect(find.byKey(const ValueKey('via-advisory')), findsNothing);
    });

    testWidgets('Compose reports only; the spine editor orders its route', (tester) async {
      await _pumpMetricsRail(tester, _segment(), mode: PlanningMode.compose);
      expect(find.text('Lunch'), findsOneWidget);
      expect(find.byTooltip('Move earlier'), findsNothing);
      expect(find.byKey(const ValueKey('via-order-hint')), findsNothing);
    });
  });

  group('weights rail', () {
    testWidgets('no longer carries a second ROUTE THROUGH list', (tester) async {
      final container = ProviderContainer(overrides: [metricUnits()]);
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).open(_trip(_segment()));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: WeightsRail(dayId: 'd1', segment: _segment())),
        ),
      ));
      await tester.pump();
      await openRailTask(tester, 'frame');
      expect(find.text('ROUTE THROUGH'), findsNothing);
    });

    testWidgets('Compose keeps the anchor spine, which names a routed node too',
        (tester) async {
      final container = ProviderContainer(overrides: [metricUnits()]);
      addTearDown(container.dispose);
      container.read(currentTripProvider.notifier).open(_trip(_segment()));
      container.read(dayPlanningModeProvider('d1').notifier).state = PlanningMode.compose;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: WeightsRail(dayId: 'd1', segment: _segment())),
        ),
      ));
      await tester.pump();
      await openRailTask(tester, 'frame');

      expect(find.text('SPINE'), findsOneWidget);
      expect(find.text('Lunch'), findsOneWidget);
    });
  });

  group('metrics rail — did the route reach them', () {
    testWidgets('a reached point reads as reached; a missed one is named with its distance',
        (tester) async {
      await _pumpMetricsRail(tester, _segment(via: const [_lunch, _overlook]));

      expect(find.text('ROUTE THROUGH'), findsOneWidget);
      Finder rowOf(String label) => find.ancestor(of: find.text(label), matching: find.byType(Row)).first;
      expect(find.descendant(of: rowOf('Lunch'), matching: find.text('reached')), findsOneWidget);
      expect(find.descendant(of: rowOf('Overlook'), matching: find.text('missed')), findsOneWidget);
      expect(find.descendant(of: rowOf('Overlook'), matching: find.text('1.1 km')), findsOneWidget);
    });

    testWidgets('a stale passage asks for a re-solve rather than reporting', (tester) async {
      await _pumpMetricsRail(tester, _segment(via: const [_lunch, _overlook], stale: true));

      expect(find.byKey(const ValueKey('via-reach-pending')), findsOneWidget);
      expect(find.text('missed'), findsNothing);
      expect(find.text('Overlook'), findsOneWidget);
    });

    testWidgets('a passage with no via points has no ROUTE THROUGH section', (tester) async {
      await _pumpMetricsRail(tester, _segment(via: const []));
      expect(find.text('ROUTE THROUGH'), findsNothing);
    });
  });
}
