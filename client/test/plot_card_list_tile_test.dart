// Bug #185 — a ListTile-family widget placed inside a PlotCard must not trip
// the framework assertion "ListTile background color or ink splashes may be
// invisible" (a DecoratedBox with a background sitting between the tile and
// its nearest Material). PlotCard now interposes a transparent Material.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

void main() {
  testWidgets('ListTile inside PlotCard raises no framework assertion',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlotCard(
            padding: EdgeInsets.zero,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: const Text('Row one'),
                  selected: true,
                  onTap: () {},
                ),
                RadioListTile<int>(
                  value: 1,
                  groupValue: 1,
                  onChanged: (_) {},
                  title: const Text('Row two'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Row one'), findsOneWidget);
    expect(find.text('Row two'), findsOneWidget);
  });
}
