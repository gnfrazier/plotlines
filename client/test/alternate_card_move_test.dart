// Issue #344 — the alternate card's half of `Move on the map`, and what the
// card says about a path whose numbers have gone stale.
//
// The card led with `WHERE IT LEAVES AND REJOINS` (#324) and showed both marks
// with no way to change either: an Author whose fork sat 400 m too early had
// to delete the alternate and draw it again, losing the name, the note, the
// attached anchors, the narration and the reveal along with the geometry. Flow
// 11 §03 and §04 both put a `Move on the map` action directly under that block,
// on the branch card and the accommodation card alike.
//
// The card cannot run the gesture itself — it is a dialog and the gesture
// happens on the Route tab's map — so what it does is *ask*, by closing with
// the request. That handoff is what the second group here pins.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/logistics_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';
import 'support/display_units.dart';

const _route = <Coord>[
  [-105.4, 40.0],
  [-105.0, 40.0],
];

LineString _drawn() => LineString(
      coordinates: const [
        [-105.3, 40.0],
        [-105.2, 40.05],
        [-105.1, 40.0],
      ],
      source: 'authored',
    );

Alternate _alternate({
  String intent = 'branch',
  String label = 'Past the Sugarloaf mine',
  SolveProvenance? solve,
  RouteMetrics? metrics,
}) =>
    Alternate(
      id: 'a1',
      kind: 'extension',
      intent: intent,
      label: label,
      geometry: _drawn(),
      metrics: metrics,
      divergesAtM: 8000.0,
      rejoinsAtM: 24000.0,
      solve: solve,
      note: intent == 'branch' ? 'Three miles of old tramway grade.' : null,
    );

Segment _leg(List<Alternate> alternates) => Segment(
      id: 's1',
      mode: 'cycling',
      shape: 'point_to_point',
      geometry: LineString(coordinates: _route),
      alternates: alternates,
    );

/// The Logistics tab, which is where FR142(b)/K12 says an alternate is found
/// again — and therefore the harder of the card's two callers, because the map
/// is not even on screen when `Move on the map` is asked for.
Future<({ProviderContainer container, List<(String, String)> opened})> _pump(
  WidgetTester tester,
  Alternate alternate,
) async {
  final opened = <(String, String)>[];
  final container = ProviderContainer(overrides: [metricUnits()]);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(Trip(
        id: 't1',
        title: 'Test trip',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        days: [
          Day(id: 'd1', index: 1, segments: [
            _leg([alternate])
          ])
        ],
      ));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => LogisticsTab(
              trip: ref.watch(currentTripProvider),
              onOpenSegment: (d, s) => opened.add((d, s)),
            ),
          ),
        ),
      ),
    ),
  );
  return (container: container, opened: opened);
}

Future<void> _openCard(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  group('Move on the map is on both cards', () {
    testWidgets('a branch card offers it', (tester) async {
      await _pump(tester, _alternate());
      await _openCard(tester, 'Past the Sugarloaf mine');
      expect(find.text('Move on the map'), findsOneWidget);
    });

    testWidgets('an accommodation card offers it too', (tester) async {
      await _pump(tester, _alternate(intent: 'accommodation', label: 'Toe River road'));
      await _openCard(tester, 'Toe River road');
      expect(find.text('Move on the map'), findsOneWidget);
    });
  });

  group('asking for the gesture from a surface that has no map', () {
    testWidgets('closes the card, names the alternate, and opens the passage',
        (tester) async {
      final harness = await _pump(tester, _alternate());
      await _openCard(tester, 'Past the Sugarloaf mine');

      await tester.tap(find.text('Move on the map'));
      await tester.pumpAndSettle();

      // The card is gone — the gesture happens on the map, not behind a modal.
      expect(find.text('WHERE IT LEAVES AND REJOINS'), findsNothing);
      // The request survives the tab switch, and the passage it belongs to is
      // selected so the Route tab has a line to measure the marks along.
      expect(harness.container.read(alternateToMoveProvider), 'a1');
      expect(harness.opened, [('d1', 's1')]);
    });

    testWidgets('closing the card any other way asks for nothing', (tester) async {
      final harness = await _pump(tester, _alternate());
      await _openCard(tester, 'Past the Sugarloaf mine');

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(harness.container.read(alternateToMoveProvider), isNull);
      expect(harness.opened, isEmpty);
    });
  });

  group('FR140 / Q3 — the distances say which solve they came from', () {
    testWidgets('an unsolved path says its numbers came off the line as drawn',
        (tester) async {
      await _pump(tester, _alternate());
      await _openCard(tester, 'Past the Sugarloaf mine');

      expect(find.text('Measured off the line as drawn, not solved.'), findsOneWidget);
      expect(find.text('STALE'), findsNothing);
      // Never solved is not the same as stale, so the action reads as the
      // first solve it would be.
      expect(find.text('Solve this path'), findsOneWidget);
    });

    testWidgets('a solved, current path qualifies nothing and offers a re-solve',
        (tester) async {
      await _pump(
        tester,
        _alternate(
          solve: SolveProvenance(solvedAt: '2026-09-10T16:28:00Z', stale: false),
          metrics: RouteMetrics(distanceM: 17500),
        ),
      );
      await _openCard(tester, 'Past the Sugarloaf mine');

      expect(find.text('Measured off the line as drawn, not solved.'), findsNothing);
      expect(find.text('STALE'), findsNothing);
      expect(find.text('Re-solve this branch'), findsOneWidget);
      expect(find.textContaining('SOLVED '), findsOneWidget);
    });

    testWidgets('a stale path says its distances are the ones it was solved with',
        (tester) async {
      await _pump(
        tester,
        _alternate(
          solve: SolveProvenance(solvedAt: '2026-09-10T16:28:00Z', stale: true),
          metrics: RouteMetrics(distanceM: 17500),
        ),
      );
      await _openCard(tester, 'Past the Sugarloaf mine');

      expect(
        find.text('These distances are the ones this path was solved with, before it moved.'),
        findsOneWidget,
      );
      // A small marker on the object, per Q3's "passive only while planning" —
      // and the *when* rendered as data beside it rather than folded into the
      // sentence, so a display preference never reaches a stored value.
      expect(find.text('STALE'), findsOneWidget);
      expect(find.textContaining('SOLVED '), findsOneWidget);
      // FR140a: this is the stale list's own idiom, never M13's error surface.
      expect(find.textContaining('Error'), findsNothing);
    });

    testWidgets('an accommodation card says re-solve without calling itself a branch',
        (tester) async {
      await _pump(
        tester,
        _alternate(
          intent: 'accommodation',
          label: 'Toe River road',
          solve: SolveProvenance(stale: true),
        ),
      );
      await _openCard(tester, 'Toe River road');
      expect(find.text('Re-solve this path'), findsOneWidget);
    });
  });

  group('the Logistics row carries the marker too', () {
    testWidgets('a stale alternate is marked in the list, passively', (tester) async {
      await _pump(tester, _alternate(solve: SolveProvenance(stale: true)));

      expect(find.byIcon(Icons.sync_problem), findsWidgets);
      expect(find.textContaining('stale'), findsWidgets);
      // Passive: a marker and a count, no banner and no modal.
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('1 stale item needs re-solving'), findsOneWidget);
    });

    testWidgets('an unsolved alternate is not marked', (tester) async {
      await _pump(tester, _alternate());
      expect(find.byIcon(Icons.sync_problem), findsNothing);
      expect(find.textContaining('stale item'), findsNothing);
    });
  });
}
