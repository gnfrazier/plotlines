// FR74b (Story G2b) — the scope picker states what a clone will and will not
// bring *before* it runs, and the statement tracks the selected scope.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/domain/clone.dart';
import 'package:plotlines_client/presentation/widgets/clone_scope_dialog.dart';

/// Holds the pending dialog result so awaiting [_openDialog] does not itself
/// block on the dialog being dismissed.
class _Harness {
  late Future<CloneRequest?> result;
}

Future<_Harness> _openDialog(WidgetTester tester) async {
  final h = _Harness();
  await tester.pumpWidget(MaterialApp(
    theme: PlotTheme.light(),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => h.result =
                showCloneScopeDialog(context, tripTitle: 'Blue Ridge Traverse'),
            child: const Text('go'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
  return h;
}

void main() {
  testWidgets('defaults to whole trip and lists carried + not-carried contents', (tester) async {
    await _openDialog(tester);

    expect(find.text('Clone "Blue Ridge Traverse"'), findsOneWidget);
    expect(find.text('CARRIES'), findsOneWidget);
    expect(find.text('DOES NOT CARRY'), findsOneWidget);
    expect(find.text('Roster membership'), findsOneWidget);
    expect(
      find.text('Profile grants — every Character re-grants for this trip'),
      findsOneWidget,
    );
  });

  testWidgets('switching to Roster only updates the statement and flags trip initiation',
      (tester) async {
    await _openDialog(tester);

    await tester.tap(find.text('Roster only'));
    await tester.pumpAndSettle();

    expect(find.text('Roster membership'), findsOneWidget);
    expect(find.textContaining('Days, passages, anchors, and content'), findsOneWidget);
    expect(find.textContaining('starts trip initiation'), findsOneWidget);
  });

  testWidgets('Authored trip only shows an empty roster in the not-carried list', (tester) async {
    await _openDialog(tester);

    await tester.tap(find.text('Authored trip only'));
    await tester.pumpAndSettle();

    expect(find.textContaining('The roster — this clone starts with nobody'), findsOneWidget);
  });

  testWidgets('per-part with nothing ticked disables Clone', (tester) async {
    await _openDialog(tester);

    await tester.tap(find.text('Choose parts'));
    await tester.pumpAndSettle();

    // The dialog body scrolls; make each checkbox visible before tapping it.
    await tester.ensureVisible(find.text('Authored trip'));
    await tester.tap(find.text('Authored trip'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Roster'));
    await tester.tap(find.text('Roster'));
    await tester.pumpAndSettle();

    final cloneButton =
        tester.widget<PlotButton>(find.widgetWithText(PlotButton, 'Clone'));
    expect(cloneButton.onPressed, isNull);
  });

  testWidgets('choosing a scope returns the CloneRequest', (tester) async {
    final h = await _openDialog(tester);

    await tester.tap(find.text('Authored trip only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clone'));
    await tester.pumpAndSettle();

    final request = await h.result;
    expect(request, isNotNull);
    expect(request!.scope, CloneScope.authoredTripOnly);
  });

  testWidgets('Cancel returns null', (tester) async {
    final h = await _openDialog(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(await h.result, isNull);
  });
}
