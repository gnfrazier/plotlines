// D4a (FR78a, FR123) — RosterTab's widget-level AC coverage: toggling the
// request set, adding a Character to the roster stub, and the
// granted/declined/volunteered status view (including the "never
// auto-grants" and "not buried" AC lines).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/presentation/screens/plan_tabs/roster_tab.dart';

// The tab's content (request catalog + roster cards) runs taller than the
// default test surface, and `ListView`'s sliver realizes children lazily by
// viewport extent same as `.builder` would — a default-size surface would
// leave the roster section (and its granted/declined/volunteered rows)
// unbuilt and unfindable. A generously tall surface keeps every row mounted
// without the tests having to scroll to reach it.
Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    const ProviderScope(
      child: MaterialApp(home: Scaffold(body: RosterTab())),
    ),
  );
}

void main() {
  testWidgets('shows the empty-roster next action before any Character is added', (tester) async {
    await _pump(tester);
    expect(find.textContaining('No Characters on this trip\'s roster yet'), findsOneWidget);
  });

  testWidgets('adding a Character shows every default-requested field pending, never granted',
      (tester) async {
    await _pump(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Character name'), 'Bob');
    await tester.tap(find.text('Add'));
    await tester.pump();

    expect(find.text('Bob'), findsOneWidget);
    // full_name, phone, emergency_contact default in. "Full name" now
    // appears twice: the catalog checkbox row and Bob's status row.
    expect(find.text('Full name'), findsNWidgets(2));
    expect(find.text('PENDING'), findsNWidgets(3));
    expect(find.text('GRANTED'), findsNothing);
  });

  testWidgets('unchecking a default field removes it from every Character\'s status view',
      (tester) async {
    await _pump(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Character name'), 'Bob');
    await tester.tap(find.text('Add'));
    await tester.pump();
    expect(find.text('Full name'), findsNWidgets(2)); // catalog checkbox row + Bob's status row

    await tester.tap(find.text('Full name').first);
    await tester.pump();
    // Only the catalog checkbox row remains; Bob's status row is gone since
    // the field is no longer requested (and was never volunteered).
    expect(find.text('Full name'), findsOneWidget);
  });

  testWidgets('recording a grant flips the badge from pending to granted', (tester) async {
    await _pump(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Character name'), 'Bob');
    await tester.tap(find.text('Add'));
    await tester.pump();

    await tester.tap(find.byTooltip('Record as granted').first);
    await tester.pump();

    expect(find.text('GRANTED'), findsOneWidget);
    expect(find.text('PENDING'), findsNWidgets(2)); // the other two default fields
  });

  testWidgets('a volunteered field is surfaced in its own section, not interleaved', (tester) async {
    await _pump(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Character name'), 'Bob');
    await tester.tap(find.text('Add'));
    await tester.pump();

    await tester.tap(find.text('Record a field they volunteered'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Medical conditions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add').last);
    await tester.pump();

    expect(find.text('VOLUNTEERED UNPROMPTED'), findsOneWidget);
    expect(find.text('VOLUNTEERED'), findsOneWidget);
  });

  // D4b (FR78a) — the Author fills in a value they already hold.
  testWidgets('entering a value shows its provenance and leaves the request pending',
      (tester) async {
    await _pump(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Character name'), 'Bob');
    await tester.tap(find.text('Add'));
    await tester.pump();

    // Three default-requested fields, each with a fill-in affordance.
    expect(find.byTooltip('Fill in what they already told you'), findsNWidgets(3));

    await tester.tap(find.byTooltip('Fill in what they already told you').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Value'), '555-0100');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // The value is shown, tagged as Author-entered, never as granted...
    expect(find.text('555-0100'), findsOneWidget);
    expect(find.text('ENTERED BY YOU'), findsOneWidget);
    expect(find.text('GRANTED'), findsNothing);
    // ...and the request is still outstanding: all three rows read PENDING.
    expect(find.text('PENDING'), findsNWidgets(3));
  });

  testWidgets('recording the Character\'s grant supersedes the entered value', (tester) async {
    await _pump(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Character name'), 'Bob');
    await tester.tap(find.text('Add'));
    await tester.pump();

    await tester.tap(find.byTooltip('Fill in what they already told you').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Value'), '555-0100');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('ENTERED BY YOU'), findsOneWidget);

    await tester.tap(find.byTooltip('Record as granted').first);
    await tester.pump();

    // The Character's response replaces the Author's entry rather than merging,
    // but the field still shows that an Author-entered value existed (AC).
    expect(find.text('GRANTED'), findsOneWidget);
    expect(find.text('ENTERED BY YOU'), findsNothing);
    expect(find.text('555-0100'), findsNothing); // no longer the live value
    expect(find.textContaining('replaced the value you had entered (555-0100)'),
        findsOneWidget);
  });

  // Review fix — the Character cards were unkeyed, so a field picked (not yet
  // added) in Ann's "Record a field they volunteered" dropdown moved to Bob's
  // card when Ann was removed, and Add recorded it as volunteered by Bob: a
  // disclosure attributed to someone who never made it.
  testWidgets('removing a Character never hands their pending volunteered pick to the next card',
      (tester) async {
    await _pump(tester);
    for (final name in ['Ann', 'Bob']) {
      await tester.enterText(find.widgetWithText(TextField, 'Character name'), name);
      await tester.tap(find.text('Add').first);
      await tester.pump();
    }

    await tester.tap(find.text('Record a field they volunteered').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Medical conditions').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Remove Ann from roster'));
    await tester.pumpAndSettle();

    expect(find.text('Ann'), findsNothing);
    expect(find.text('Medical conditions'), findsOneWidget); // the catalog row only
    final add = find.widgetWithText(PlotButton, 'Add').last;
    expect(tester.widget<PlotButton>(add).onPressed, isNull);
    expect(find.text('VOLUNTEERED UNPROMPTED'), findsNothing);
  });
}
