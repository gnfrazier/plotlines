// Issue #626 — the weights rail on a passage built from placed nodes: it
// says what Generate needs until there are two points to route between, and
// a never-solved passage's action reads "Generate", not "Regenerate".
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/weights_rail.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'support/display_units.dart';
import 'support/routing_ready.dart';

const _a = <double>[-105.30, 40.0];
const _b = <double>[-105.20, 40.0];

Segment _nodeBuilt(List<Coord> via) => Segment(
      id: 's1',
      mode: 'cycling',
      shape: 'point_to_point',
      via: via,
      nodes: [
        for (var i = 0; i < via.length; i++)
          Node(id: 'n$i', kind: NodeKind.waypoint, coord: via[i]),
      ],
    );

Future<void> _pump(WidgetTester tester, Segment s) async {
  tester.view.physicalSize = const Size(1400, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(overrides: [metricUnits(), routingReady()]);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(Trip(
        id: 't1',
        title: 'Trip',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        days: [Day(id: 'd1', index: 1, segments: [s])],
      ));
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) => WeightsRail(
            dayId: 'd1',
            segment: ref.watch(currentTripProvider).days.single.segments.single,
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
}

PlotButton _generate(WidgetTester tester) =>
    tester.widget<PlotButton>(find.widgetWithText(PlotButton, 'Generate'));

void main() {
  testWidgets('one point: Generate is disabled, and the rail says why', (tester) async {
    await _pump(tester, _nodeBuilt(const [_a]));
    expect(_generate(tester).onPressed, isNull);
    expect(find.textContaining('Place two or more route-through nodes'), findsOneWidget);
  });

  testWidgets('two points: Generate is live and the reason is gone', (tester) async {
    await _pump(tester, _nodeBuilt(const [_a, _b]));
    expect(_generate(tester).onPressed, isNotNull);
    expect(find.textContaining('Place two or more route-through nodes'), findsNothing);
  });
}
