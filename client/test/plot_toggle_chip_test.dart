// Issue #230 A1 / B5 — the chip's label is a control label, and its selected
// state does not depend on colour.
//
// Selected and unselected differed by hue alone (Blaze border, text and icon
// against neutral), which is WCAG 1.4.1; and the label was set in
// `PlotTypography.data` — mono at 12 px with 0.12em tracking, which is right
// for `NORTH` and wrong for `quiet scenic`.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/presentation/widgets/plot_toggle_chip.dart';

Widget _host(Widget child) => MaterialApp(
      theme: PlotTheme.light(),
      home: Scaffold(body: Center(child: child)),
    );

TextStyle _labelStyle(WidgetTester tester, String label) =>
    tester.widget<Text>(find.text(label)).style!;

void main() {
  testWidgets('a chip label is sans, not tracked mono', (tester) async {
    await tester.pumpWidget(_host(
      PlotToggleChip(label: 'quiet scenic', selected: false, onTap: () {}),
    ));

    final style = _labelStyle(tester, 'quiet scenic');
    expect(style.fontFamily, 'Archivo');
    expect(style.fontSize, 14);
    // The 0.12em tracking that made a multi-word label read as spaced
    // letters is gone.
    expect(style.letterSpacing ?? 0, 0);
  });

  testWidgets('selection carries a mark, not only a colour', (tester) async {
    await tester.pumpWidget(_host(
      PlotToggleChip(label: 'Ride', selected: false, onTap: () {}),
    ));
    expect(find.byIcon(Icons.check), findsNothing);

    await tester.pumpWidget(_host(
      PlotToggleChip(label: 'Ride', selected: true, onTap: () {}),
    ));
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('a selected chip is filled as well as outlined', (tester) async {
    await tester.pumpWidget(_host(
      PlotToggleChip(label: 'Ride', selected: true, onTap: () {}),
    ));
    final decoration = tester
        .widget<Container>(find.descendant(
          of: find.byType(PlotToggleChip),
          matching: find.byType(Container),
        ))
        .decoration as BoxDecoration;
    expect(decoration.color, isNot(PlotColors.light.surfaceCard));
  });

  testWidgets('the selected state reaches assistive technology', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(
      PlotToggleChip(label: 'Ride', selected: true, onTap: () {}),
    ));
    final node = tester.getSemantics(find.byType(PlotToggleChip));
    expect(node.hasFlag(SemanticsFlag.isSelected), isTrue);
    expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(node.label, 'Ride');
    handle.dispose();
  });
}
