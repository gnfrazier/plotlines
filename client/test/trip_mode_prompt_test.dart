// FR144/N0 — the mode-declaration dialog itself: at least one required,
// every real mode always offered, Cancel aborts distinctly from an empty
// selection. `trip_library_screen_test.dart` covers this wired into the
// New Trip flow; this pins the dialog's own contract in isolation.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/presentation/widgets/plot_toggle_chip.dart';
import 'package:plotlines_client/presentation/widgets/trip_mode_prompt.dart';

/// Opens the dialog and leaves it open (never taps Continue/Cancel) so a
/// test can inspect its contents without also driving it to a result.
Future<void> _open(WidgetTester tester, {Set<String> initialModes = const {}}) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: ElevatedButton(
          onPressed: () => showTripModePrompt(context, initialModes: initialModes),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('every real mode is offered, and none is preselected by default', (tester) async {
    await _open(tester);

    for (final label in ['Ride', 'Hike', 'Paddle', 'Transit']) {
      expect(find.text(label), findsOneWidget);
      final chip = tester.widget<PlotToggleChip>(find.widgetWithText(PlotToggleChip, label));
      expect(chip.selected, isFalse);
    }
    // FR109/O4 — never offered as a travel mode.
    for (final label in ['Climbing', 'Canyoneering', 'Jumaring']) {
      expect(find.text(label), findsNothing);
    }
  });

  testWidgets('Continue is disabled until at least one mode is selected', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _HarnessScreen()));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    ElevatedButton continueButton() =>
        tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Continue'));

    expect(continueButton().onPressed, isNull);

    await tester.tap(find.text('Hike'));
    await tester.pump();
    expect(continueButton().onPressed, isNotNull);

    await tester.tap(find.text('Hike'));
    await tester.pump();
    expect(continueButton().onPressed, isNull);
  });

  testWidgets('choosing modes and confirming returns exactly that set', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _HarnessScreen()));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ride'));
    await tester.pump();
    await tester.tap(find.text('Hike'));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(_HarnessScreenState.lastResult, {'cycling', 'hiking'});
  });

  testWidgets('Cancel returns null, distinct from an intentional empty result', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _HarnessScreen()));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ride')); // prove a selection existed and was discarded
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(_HarnessScreenState.lastResult, isNull);
  });

  testWidgets('initialModes preselects an edit of an already-declared set', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => showTripModePrompt(context, initialModes: const {'paddling'}),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Continue is already enabled — a preselected edit isn't "nothing chosen yet".
    final continueButton =
        tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Continue'));
    expect(continueButton.onPressed, isNotNull);
  });
}

class _HarnessScreen extends StatefulWidget {
  const _HarnessScreen();
  @override
  State<_HarnessScreen> createState() => _HarnessScreenState();
}

class _HarnessScreenState extends State<_HarnessScreen> {
  static Set<String>? lastResult;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ElevatedButton(
        onPressed: () async {
          lastResult = await showTripModePrompt(context);
        },
        child: const Text('open'),
      ),
    );
  }
}
