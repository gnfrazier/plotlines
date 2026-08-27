// D4a (FR78a, FR123) — RosterTab's widget-level AC coverage: toggling the
// request set, adding a Character to the roster stub, and the
// granted/declined/volunteered status view (including the "never
// auto-grants" and "not buried" AC lines).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

    await tester.tap(find.text('Volunteer a field'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Medical conditions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add').last);
    await tester.pump();

    expect(find.text('VOLUNTEERED UNPROMPTED'), findsOneWidget);
    expect(find.text('VOLUNTEERED'), findsOneWidget);
  });
}
