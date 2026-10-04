// Issue #328 — the Route workspace's task spine. The left rail was 50+
// controls at one depth in one scroll; it is now an accordion of Frame / Tune
// / Refine, one open at a time, each stating its own answer when closed, with
// the actions on their own plane below. The right rail leads with the
// selected passage and folds the whole trip into one row.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/app_database.dart';
import 'package:plotlines_client/data/sidecar_manager.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/trip_shell_screen.dart';
import 'package:plotlines_client/presentation/widgets/metrics_rail.dart';
import 'package:plotlines_client/presentation/widgets/weights_rail.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';
import 'package:plotlines_client/state/providers.dart';
import 'support/display_units.dart';
import 'support/app_fonts.dart';
import 'support/rail_tasks.dart';

class _FakeSidecarManager extends SidecarManager {
  @override
  Future<void> start() async {}
  @override
  SidecarStatus get status => const SidecarStatus(SidecarState.ready);
}

Segment _segment({List<Band> bands = const [], List<Node> nodes = const [], String? arcStage}) => Segment(
      id: 'seg-1',
      mode: 'cycling',
      shape: 'loop',
      start: const [-105.27, 40.02],
      targetDistance: TargetDistance(valueM: 16100),
      bands: bands,
      nodes: nodes,
      arcStage: arcStage,
      metrics: RouteMetrics(distanceM: 16400, climbM: 210),
      solve: SolveProvenance(solvedAt: '2026-08-25T00:00:00Z'),
    );

Trip _trip(Segment segment) => Trip(
      id: 'trip-1',
      title: 'Test trip',
      createdAt: '2026-08-25T00:00:00Z',
      updatedAt: '2026-08-25T00:00:00Z',
      modes: const {'cycling'},
      days: [
        Day(id: 'day-1', index: 1, segments: [segment]),
        Day(id: 'day-2', index: 2),
      ],
    );

Future<void> _pumpRail(WidgetTester tester, Segment segment) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      currentTripProvider.overrideWith((ref) => CurrentTripNotifier(ref)..open(_trip(segment))),
      metricUnits(),
    ],
    child: MaterialApp(home: Scaffold(body: WeightsRail(dayId: 'day-1', segment: segment))),
  ));
  await tester.pump();
}

Finder _task(String name) => find.byKey(ValueKey('rail-task-$name'));

bool _isOpen(WidgetTester tester, String name) =>
    find.descendant(of: _task(name), matching: find.byIcon(Icons.expand_less)).evaluate().isNotEmpty;

void main() {
  testWidgets('opening one task closes the others', (tester) async {
    await _pumpRail(tester, _segment());

    expect(_isOpen(tester, 'tune'), isTrue, reason: 'Tune opens by default');
    expect(_isOpen(tester, 'frame'), isFalse);
    expect(_isOpen(tester, 'refine'), isFalse);

    await openRailTask(tester, 'frame');
    expect(_isOpen(tester, 'frame'), isTrue);
    expect(_isOpen(tester, 'tune'), isFalse);
    expect(find.text('Peaks — climbing'), findsNothing, reason: 'a closed task shows no controls');

    await openRailTask(tester, 'refine');
    expect(_isOpen(tester, 'refine'), isTrue);
    expect(_isOpen(tester, 'frame'), isFalse);
    expect(find.text('SHAPE'), findsNothing);
  });

  testWidgets('closed tasks state their own answer in the data voice', (tester) async {
    await _pumpRail(
      tester,
      _segment(
        bands: [Band(attribute: 'climb_m', max: 500)],
        nodes: [
          Node(id: 'n1', kind: NodeKind.poi, coord: const [-105.26, 40.02], title: 'Farm stand'),
          Node(id: 'n2', kind: NodeKind.poi, coord: const [-105.25, 40.02], title: 'Gap'),
        ],
        arcStage: 'rising',
      ),
    );

    // Tune is open, so Frame and Refine carry summaries: one line of data
    // tokens each, the unit carried by the distance.
    Finder summary(String task, String line) =>
        find.descendant(of: _task(task), matching: find.text(line, findRichText: true));
    expect(summary('frame', 'RIDE · LOOP · 16.1 KM'), findsOneWidget);
    expect(summary('refine', '2 NODES · RISING ACTION · NO ALTERNATE'), findsOneWidget);

    await openRailTask(tester, 'frame');
    expect(summary('tune', 'DEFAULT WEIGHTS · 1 BAND'), findsOneWidget);
  });

  testWidgets('with one task open and no bands, the rail does not scroll at 900 px', (tester) async {
    // In the real Trip Shell (title bar, tabs, day strip) at a 1440 x 900
    // window, with the app's own fonts: the test font's square glyphs wrap
    // every label and would measure a rail no Author ever sees.
    await tester.runAsync(loadAppFonts);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        metricUnits(),
        sidecarManagerProvider.overrideWith((ref) => _FakeSidecarManager()),
        appDatabaseProvider.overrideWithValue(AppDatabase.forTesting(NativeDatabase.memory())),
        currentTripProvider.overrideWith((ref) => CurrentTripNotifier(ref)..open(_trip(_segment()))),
        selectedSegmentProvider.overrideWith((ref) => ('day-1', 'seg-1')),
      ],
      child: const MaterialApp(home: TripShellScreen()),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    for (final task in ['frame', 'tune', 'refine']) {
      await openRailTask(tester, task);
      final scrollable = tester.state<ScrollableState>(find
          .descendant(of: find.byType(WeightsRail), matching: find.byType(Scrollable))
          .first);
      expect(scrollable.position.maxScrollExtent, 0.0, reason: '$task open must fit without a scroll');
    }
  });

  testWidgets('the action bar sits on its own plane, outside the scroll', (tester) async {
    await _pumpRail(tester, _segment());
    final scroll = find.descendant(of: find.byType(WeightsRail), matching: find.byType(SingleChildScrollView));
    // Never solved, so the action reads Generate (#626); same plane either way.
    expect(find.descendant(of: scroll, matching: find.text('Generate')), findsNothing);
    expect(find.text('Generate'), findsOneWidget);
  });

  testWidgets('the right rail leads with the passage; the trip folds to one row', (tester) async {
    final segment = _segment();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MetricsRail(
          trip: _trip(segment),
          selectedSegment: segment,
          elevationCapability: const CapabilityStatus(ready: true),
        ),
      ),
    ));
    await tester.pump();

    final passageY = tester.getTopLeft(find.text('THIS PASSAGE')).dy;
    final tripY = tester.getTopLeft(find.text('WHOLE TRIP')).dy;
    expect(passageY, lessThan(tripY));
    expect(find.text('2 DAYS'), findsOneWidget);
    expect(find.text('BY DAY'), findsNothing, reason: 'trip scope is collapsed while a passage is selected');

    await tester.tap(find.byKey(const ValueKey('metrics-whole-trip')));
    await tester.pump();
    expect(find.text('BY DAY'), findsOneWidget);
  });
}
