// X1 (issue #180) — the custom titlebar is the only window chrome the app
// ships on desktop, so its controls have to actually be wired to
// window_manager. This pumps `AppTitleBar` against a faked `window_manager`
// channel and checks each control invokes the right platform call, the
// maximise button reflects window state, and the drag region moves the
// window.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_client/presentation/widgets/app_title_bar.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'support/fake_window_manager.dart';

void main() {
  late FakeWindowManager wm;

  setUp(() => wm = FakeWindowManager());
  tearDown(() => wm.dispose());

  Future<void> pumpBar(WidgetTester tester, {ThemeData? theme}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? PlotTheme.light(),
        home: const Scaffold(
          body: Column(children: [AppTitleBar()]),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('renders the app title and the three window controls',
      (tester) async {
    await pumpBar(tester);

    expect(find.text('Plotlines'), findsOneWidget);
    expect(find.byKey(const Key('window-button-minimize')), findsOneWidget);
    expect(find.byKey(const Key('window-button-maximize')), findsOneWidget);
    expect(find.byKey(const Key('window-button-close')), findsOneWidget);
    expect(find.bySemanticsLabel('Maximise'), findsOneWidget);
  });

  testWidgets('minimise button calls windowManager.minimize', (tester) async {
    await pumpBar(tester);
    await tester.tap(find.byKey(const Key('window-button-minimize')));
    await tester.pump();
    expect(wm.calls, contains('minimize'));
  });

  testWidgets('close button calls windowManager.close', (tester) async {
    await pumpBar(tester);
    await tester.tap(find.byKey(const Key('window-button-close')));
    await tester.pump();
    expect(wm.calls, contains('close'));
  });

  testWidgets('maximise button toggles window state and the control label flips',
      (tester) async {
    await pumpBar(tester);

    await tester.tap(find.byKey(const Key('window-button-maximize')));
    await tester.pumpAndSettle();
    expect(wm.calls, contains('maximize'));
    // WindowListener isn't driven by the fake channel, so the widget syncs
    // from isMaximized() after the tap — the label must now read "Restore".
    expect(find.bySemanticsLabel('Restore'), findsOneWidget);
    expect(find.bySemanticsLabel('Maximise'), findsNothing);

    await tester.tap(find.byKey(const Key('window-button-maximize')));
    await tester.pumpAndSettle();
    expect(wm.calls, contains('unmaximize'));
    expect(find.bySemanticsLabel('Maximise'), findsOneWidget);
  });

  testWidgets('double-clicking the drag region toggles maximise', (tester) async {
    await pumpBar(tester);

    await tester.tap(find.text('Plotlines'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Plotlines'));
    await tester.pumpAndSettle();

    expect(wm.calls, contains('maximize'));
  });

  testWidgets('dragging the title region starts a window move', (tester) async {
    await pumpBar(tester);

    await tester.drag(find.text('Plotlines'), const Offset(40, 0));
    await tester.pumpAndSettle();

    expect(wm.calls, contains('startDragging'));
  });

  testWidgets('titlebar background follows the active theme', (tester) async {
    await pumpBar(tester, theme: PlotTheme.dark());

    final decorated = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(AppTitleBar),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final decoration = decorated.decoration as BoxDecoration;
    expect(decoration.color, PlotColors.dark.surfaceApp);
  });
}
