// FR9 / A6 — the named-conflict + relaxation modal (wireframe "02 Constraint
// Conflict").
//
// #235 B5. `conflict_dialog.dart` shipped at 0% coverage while being reachable
// from `weights_rail.dart:592`. What matters beyond rendering is the callback
// contract: the dialog pops *before* invoking the caller's action, so a handler
// that pushes its own UI does not fight a modal that is still closing, and the
// caller is told exactly which relaxation was chosen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/presentation/widgets/conflict_dialog.dart';
import 'package:plotlines_client/presentation/widgets/error_states.dart';

const _widen = RelaxationOffer(
  from: 'climb at least 600 m',
  to: 'climb at least 420 m',
  tradeOff: 'a flatter day',
  metric: 'climb_m',
);

const _quieter = RelaxationOffer(
  from: 'traffic at most 0.1',
  to: 'traffic at most 0.2',
  tradeOff: 'more cars on the middle third',
  metric: 'traffic',
);

/// What the dialog handed back to its caller.
class _Actions {
  final applied = <RelaxationOffer>[];
  int viaDropped = 0;
}

Future<_Actions> _open(
  WidgetTester tester, {
  String explanation = 'climb_m cannot be met inside the distance band',
  List<RelaxationOffer> relaxations = const [_widen],
  bool viaImplicated = false,
  bool withDropVia = true,
}) async {
  final actions = _Actions();
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showConflictDialog(
            context,
            explanation: explanation,
            relaxations: relaxations,
            viaImplicated: viaImplicated,
            onDropVia: withDropVia ? () => actions.viaDropped++ : null,
            onApplyRelaxation: actions.applied.add,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return actions;
}

void main() {
  group('naming the conflict', () {
    testWidgets('leads with what failed, in the solver\'s own words',
        (tester) async {
      // A6: the conflict is *named*. "No route found" is the thing this screen
      // exists so the Author never sees.
      await _open(tester,
          explanation: 'climb_m cannot be met inside the distance band');

      expect(find.text('No route fits every constraint'), findsOneWidget);
      expect(find.text('climb_m cannot be met inside the distance band'),
          findsOneWidget);
    });

    testWidgets('offers each relaxation with its trade-off', (tester) async {
      await _open(tester, relaxations: const [_widen, _quieter]);

      expect(find.text('SUGGESTED RELAXATIONS'), findsOneWidget);
      expect(find.text('climb at least 600 m  →  climb at least 420 m'),
          findsOneWidget);
      expect(find.text('a flatter day'), findsOneWidget);
      expect(find.text('more cars on the middle third'), findsOneWidget);
      expect(find.text('Apply'), findsNWidgets(2));
    });

    testWidgets('says so plainly when it has nothing to suggest',
        (tester) async {
      // An empty relaxation list is a real solver outcome, not an empty state
      // to leave blank.
      await _open(tester, relaxations: const []);

      expect(find.textContaining('No automatic relaxation was found'),
          findsOneWidget);
      expect(find.text('SUGGESTED RELAXATIONS'), findsNothing);
      expect(find.text('Apply'), findsNothing);
    });
  });

  group('the via-node escape hatch', () {
    testWidgets('is offered when the via nodes are implicated', (tester) async {
      await _open(tester, viaImplicated: true);

      expect(find.text('Drop via-node(s) and route'), findsOneWidget);
    });

    testWidgets('is absent when they are not', (tester) async {
      // Offering to drop via-nodes that had nothing to do with the conflict
      // would push the Author into discarding work for no reason.
      await _open(tester, viaImplicated: false);

      expect(find.text('Drop via-node(s) and route'), findsNothing);
    });

    testWidgets('is hidden when the caller offers no handler for it',
        (tester) async {
      // Showing an action the caller cannot carry out would be worse than
      // omitting it.
      await _open(tester, viaImplicated: true, withDropVia: false);

      expect(find.text('Drop via-node(s) and route'), findsNothing);
    });

    testWidgets('closes the dialog and tells the caller', (tester) async {
      final actions = await _open(tester, viaImplicated: true);

      await tester.tap(find.text('Drop via-node(s) and route'));
      await tester.pumpAndSettle();

      expect(actions.viaDropped, 1);
      expect(find.text('No route fits every constraint'), findsNothing);
    });
  });

  group('applying a relaxation', () {
    testWidgets('hands the caller the offer that was tapped', (tester) async {
      // Two offers differing only in their metric — the dialog must not pass
      // back "the first one" or "the one it happened to render last".
      final actions = await _open(tester, relaxations: const [_widen, _quieter]);

      await tester.tap(find.text('Apply').last);
      await tester.pumpAndSettle();

      expect(actions.applied, hasLength(1));
      expect(actions.applied.single.metric, 'traffic');
    });

    testWidgets('the first offer is reachable too', (tester) async {
      final actions = await _open(tester, relaxations: const [_widen, _quieter]);

      await tester.tap(find.text('Apply').first);
      await tester.pumpAndSettle();

      expect(actions.applied.single.metric, 'climb_m');
    });

    testWidgets('closes before the caller acts', (tester) async {
      // The pop happens first so a handler that opens its own surface is not
      // racing a dismissing modal.
      final actions = await _open(tester);

      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(find.text('No route fits every constraint'), findsNothing);
      expect(actions.applied, hasLength(1));
    });
  });

  group('leaving without applying anything', () {
    testWidgets('Adjust manually closes and changes nothing', (tester) async {
      // A6 always leaves the manual route open — an offered relaxation is a
      // suggestion, never the only way out.
      final actions = await _open(tester);

      await tester.tap(find.text('Adjust manually'));
      await tester.pumpAndSettle();

      expect(find.text('No route fits every constraint'), findsNothing);
      expect(actions.applied, isEmpty);
      expect(actions.viaDropped, 0);
    });

    testWidgets('Dismiss closes and changes nothing', (tester) async {
      final actions = await _open(tester);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();

      expect(find.text('No route fits every constraint'), findsNothing);
      expect(actions.applied, isEmpty);
    });
  });

  testWidgets('a long list of relaxations scrolls rather than overflowing',
      (tester) async {
    // The offer list is solver-sized, not designer-sized.
    final many = [
      for (var i = 0; i < 12; i++)
        RelaxationOffer(
            from: 'band $i', to: 'band $i widened', tradeOff: 'trade $i'),
    ];

    await _open(tester, relaxations: many);

    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsWidgets);
  });
}
