// Story B3 (issue #32), FR12 — "appears on Character timeline at the mode
// change", against the Character-facing reading that exists today: the Export
// tab's cue-sheet preview (F1).
//
// A `Transition` belongs to the day, not to either passage, so concatenating
// per-passage cue sheets went straight over every junction between them — a
// Character reading the sheet was never told to get off the bike. These tests
// pin the fix.
//
// Exercised through the authored-content path (no trip bbox, so no sidecar
// call), which is also the path a Character sees when cue derivation is
// unreachable — the one where the transition matters most.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/export_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

Segment _passage(String id, {required String mode, double distanceM = 12000}) => Segment(
      id: id,
      mode: mode,
      shape: 'point_to_point',
      metrics: RouteMetrics(distanceM: distanceM),
    );

Future<ProviderContainer> _pump(WidgetTester tester, Day day) async {
  final container = ProviderContainer();
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

Day _rideThenPaddle({String? instructions, String? title}) => resequencePassages(Day(
      id: 'day-1',
      index: 1,
      segments: [
        _passage('a', mode: 'cycling'),
        _passage('b', mode: 'paddling'),
      ],
      transitions: [
        Transition(
          id: 'tab',
          fromSegmentId: 'a',
          toSegmentId: 'b',
          node: instructions == null && title == null
              ? null
              : Node(
                  id: 'n1',
                  kind: NodeKind.transition,
                  coord: const [-105.29, 40.0],
                  title: title,
                  instructions: instructions,
                ),
        ),
      ],
    ));

void main() {
  testWidgets('the mode change appears on the day\'s reading', (tester) async {
    await _pump(tester, _rideThenPaddle());
    expect(find.textContaining('Ride → Paddle'), findsOneWidget);
  });

  testWidgets('FR12: the Author\'s instructions ride along with it', (tester) async {
    await _pump(tester, _rideThenPaddle(
      title: 'Put-in at Lyons',
      instructions: 'Stash the bikes behind the outhouse.',
    ));

    expect(
      find.textContaining('Ride → Paddle: Put-in at Lyons — Stash the bikes behind the outhouse.'),
      findsOneWidget,
    );
  });

  testWidgets('only the first line of a multi-line instruction reaches the row',
      (tester) async {
    // A cue-sheet row is a glance, not a page; the whole note is on the
    // transition itself for anyone who opens it.
    await _pump(tester, _rideThenPaddle(
      instructions: 'Put in below the bridge.\nSecond line the row must not swallow.',
    ));

    expect(find.textContaining('Put in below the bridge.'), findsOneWidget);
    expect(find.textContaining('Second line'), findsNothing);
  });

  testWidgets('B2\'s gap is tagged on the row, where a Character is looking for the next leg',
      (tester) async {
    final day = resequencePassages(Day(
      id: 'day-1',
      index: 1,
      segments: [
        Segment(
          id: 'a',
          mode: 'cycling',
          shape: 'point_to_point',
          start: const [-105.30, 40.00],
          end: const [-105.30, 40.00],
          metrics: RouteMetrics(distanceM: 12000),
        ),
        Segment(
          id: 'b',
          mode: 'paddling',
          shape: 'point_to_point',
          start: const [-105.29, 40.00],
          end: const [-105.25, 40.00],
          metrics: RouteMetrics(distanceM: 8000),
        ),
      ],
    ));
    await _pump(tester, day);

    expect(find.textContaining('GAP 852 M'), findsOneWidget);
  });

  testWidgets('a day with one passage has no junction to report', (tester) async {
    await _pump(
      tester,
      resequencePassages(
          Day(id: 'day-1', index: 1, segments: [_passage('a', mode: 'cycling')])),
    );
    expect(find.textContaining('→'), findsNothing);
  });

  testWidgets('two passages of the same mode read as a transition, not a mode change',
      (tester) async {
    await _pump(
      tester,
      resequencePassages(Day(id: 'day-1', index: 1, segments: [
        _passage('a', mode: 'cycling'),
        _passage('b', mode: 'cycling'),
      ])),
    );
    expect(find.textContaining('Ride → Ride'), findsNothing);
    expect(find.textContaining('Transition'), findsOneWidget);
  });
}
