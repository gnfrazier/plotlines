// Issue #344 — the panel that runs `Move on the map` on the Route tab.
//
// The draft bar (#324) never leaves the Author holding a disabled button with
// no explanation, and this one inherits that: at every stage it says what the
// next tap does. The one thing it has to do that drawing never did is let the
// Author say *which* handle they mean before a tap can move anything — and it
// has to say, before they commit, what moving a solved path will cost, since
// FR140/D-O guarantees they will never be asked afterwards.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/alternate_move_bar.dart';
import 'package:plotlines_client/presentation/widgets/plot_toggle_chip.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

const _route = <Coord>[
  [-105.4, 40.0],
  [-105.0, 40.0],
];

Alternate _alternate({SolveProvenance? solve}) => Alternate(
      id: 'a1',
      kind: 'extension',
      intent: 'branch',
      label: 'Past the Sugarloaf mine',
      geometry: LineString(
        coordinates: const [
          [-105.3, 40.0],
          [-105.2, 40.05],
          [-105.1, 40.0],
        ],
        source: 'authored',
      ),
      // The real distances along `_route`, not round numbers: the blocker
      // that catches a fork dragged onto the rejoin compares them to the
      // metre, and an approximated fixture would never trip it.
      divergesAtM: haversineM(_route.first, const [-105.3, 40.0]),
      rejoinsAtM: haversineM(_route.first, const [-105.1, 40.0]),
      solve: solve,
    );

Future<void> _pump(
  WidgetTester tester,
  AlternateEdit edit, {
  void Function(AlternateHandle, int)? onGrab,
  VoidCallback? onAddPoint,
  VoidCallback? onRemovePoint,
  VoidCallback? onDone,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: PlotTheme.light(),
      home: Scaffold(
        body: AlternateMoveBar(
          edit: edit,
          label: 'Past the Sugarloaf mine',
          displayFormat: const DisplayFormat(), // kilometres / metres
          onGrab: onGrab ?? (_, __) {},
          onAddPoint: onAddPoint ?? () {},
          onRemovePoint: onRemovePoint,
          onCancel: () {},
          onDone: onDone,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('names the path being moved and offers every handle in path order',
      (tester) async {
    await _pump(tester, AlternateEdit.of(_alternate(), _route));

    expect(find.text('MOVING PAST THE SUGARLOAF MINE'), findsOneWidget);
    // Leaves, the points along it, rejoins — the row reads as the line does.
    final chips = tester
        .widgetList<PlotToggleChip>(find.byType(PlotToggleChip))
        .map((c) => c.label)
        .toList();
    expect(chips, ['Leaves', 'Point 1', 'Rejoins']);
  });

  testWidgets('with nothing grabbed it says so rather than implying a tap will act',
      (tester) async {
    await _pump(tester, AlternateEdit.of(_alternate(), _route));
    expect(find.text('Pick a mark to move, or add a point to the path.'), findsOneWidget);
  });

  testWidgets('grabbing a handle says what the next tap does', (tester) async {
    await _pump(tester, AlternateEdit.of(_alternate(), _route).grab(AlternateHandle.fork));
    expect(find.text('Tap the route where this path should leave it.'), findsOneWidget);

    await _pump(tester, AlternateEdit.of(_alternate(), _route).grab(AlternateHandle.rejoin));
    expect(find.text('Tap the route where this path should come back.'), findsOneWidget);

    await _pump(tester,
        AlternateEdit.of(_alternate(), _route).grab(AlternateHandle.shapePoint, index: 0));
    expect(find.text('Tap where this point should go.'), findsOneWidget);

    await _pump(
        tester, AlternateEdit.of(_alternate(), _route).grab(AlternateHandle.newShapePoint));
    expect(find.text('Tap to add a point to the path.'), findsOneWidget);
  });

  testWidgets('tapping a chip grabs that handle', (tester) async {
    AlternateHandle? grabbed;
    var index = -1;
    await _pump(tester, AlternateEdit.of(_alternate(), _route),
        onGrab: (h, i) {
      grabbed = h;
      index = i;
    });

    await tester.tap(find.text('Point 1'));
    await tester.pumpAndSettle();
    expect(grabbed, AlternateHandle.shapePoint);
    expect(index, 0);
  });

  testWidgets('Remove point is inert unless a shaping point is in hand', (tester) async {
    // The fork and the rejoin are what make this a divergence rather than a
    // second unrelated line; removing one is deleting the alternate, which
    // confirms, and is a different action on the card.
    await _pump(tester, AlternateEdit.of(_alternate(), _route).grab(AlternateHandle.fork));
    expect(
      tester.widget<PlotButton>(find.widgetWithText(PlotButton, 'Remove point')).onPressed,
      isNull,
    );

    var removed = false;
    await _pump(
      tester,
      AlternateEdit.of(_alternate(), _route).grab(AlternateHandle.shapePoint, index: 0),
      onRemovePoint: () => removed = true,
    );
    await tester.tap(find.text('Remove point'));
    await tester.pumpAndSettle();
    expect(removed, isTrue);
  });

  testWidgets('states where the path leaves, where it rejoins and what it costs',
      (tester) async {
    await _pump(tester, AlternateEdit.of(_alternate(), _route));
    expect(find.text('LEAVES 8.5 KM'), findsOneWidget);
    expect(find.text('REJOINS 25.6 KM'), findsOneWidget);
    expect(find.textContaining('+'), findsOneWidget);
  });

  testWidgets('Done is unavailable while the move is blocked, and the panel says why',
      (tester) async {
    // Fork dragged onto the rejoin: a divergence with nowhere to go.
    final edit = AlternateEdit.of(_alternate(), _route)
        .grab(AlternateHandle.fork)
        .tap(const [-105.1, 40.0])
        .release();
    await _pump(tester, edit, onDone: () {});

    expect(find.text('The fork and the rejoin are the same point on the route.'),
        findsOneWidget);
    await _pump(tester, edit);
    expect(
      tester.widget<PlotButton>(find.widgetWithText(PlotButton, 'Done')).onPressed,
      isNull,
    );
  });

  group('FR140 / Q3 — what it says about staleness before the Author commits', () {
    testWidgets('a solved path says it will go stale, and that nothing is lost',
        (tester) async {
      final edit = AlternateEdit.of(_alternate(solve: SolveProvenance(stale: false)), _route)
          .grab(AlternateHandle.fork)
          .tap(const [-105.35, 40.0]);
      await _pump(tester, edit, onDone: () {});

      final notice = find.textContaining('stale');
      expect(notice, findsOneWidget);
      expect(find.textContaining('nothing is lost'), findsOneWidget);
      expect(find.textContaining('nothing re-solves on its own'), findsOneWidget);
      // Not a confirmation and not a blocker — Done stays live. Deliberateness
      // is reserved for destruction, and this destroys nothing.
      expect(
        tester.widget<PlotButton>(find.widgetWithText(PlotButton, 'Done')).onPressed,
        isNotNull,
      );
    });

    testWidgets('an unsolved path says nothing about staleness', (tester) async {
      final edit = AlternateEdit.of(_alternate(), _route)
          .grab(AlternateHandle.fork)
          .tap(const [-105.35, 40.0]);
      await _pump(tester, edit, onDone: () {});
      expect(find.textContaining('stale'), findsNothing);
    });

    testWidgets('nothing moved yet says nothing either', (tester) async {
      await _pump(tester,
          AlternateEdit.of(_alternate(solve: SolveProvenance(stale: false)), _route));
      expect(find.textContaining('stale'), findsNothing);
    });
  });
}
