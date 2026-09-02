// Issue #230 C2 — the trip date range on a desktop surface.
//
// The Material picker this replaces was a ~370 px scrolling column of months
// centred in a 1918 px window, with a range band in a colour from no token
// file, a range that broke into two slabs at a row wrap, and today drawn in
// the same hue as the selection. These pin the properties that fix those.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import 'package:plotlines_client/presentation/widgets/plot_date_range_picker.dart';

/// Opens the picker and leaves it open, so a test can inspect it without
/// also driving it to a result.
Future<void> _open(
  WidgetTester tester, {
  DateTimeRange? initial,
  DateTime? first,
  DateTime? last,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: PlotTheme.light(),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => showPlotDateRangePicker(
              context,
              firstDate: first ?? DateTime(2026, 1, 1),
              lastDate: last ?? DateTime(2027, 12, 31),
              initialRange: initial,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('two months are visible at once, no scrolling to see a range', (tester) async {
    await _open(tester,
        initial: DateTimeRange(start: DateTime(2026, 9, 5), end: DateTime(2026, 9, 7)));

    expect(find.text('September 2026'), findsOneWidget);
    expect(find.text('October 2026'), findsOneWidget);
    // Each month carries its own weekday row, under its own name — not one
    // detached row above the first month.
    expect(find.text('S'), findsNWidgets(4)); // Sun + Sat, twice
  });

  testWidgets('the header states the range and its length in days', (tester) async {
    await _open(tester,
        initial: DateTimeRange(start: DateTime(2026, 9, 5), end: DateTime(2026, 9, 7)));

    // C2's "no link back to trip length": the picker says how long the trip
    // it is describing actually is.
    expect(find.textContaining('3 days'), findsOneWidget);
    expect(find.textContaining('Sep 5'), findsOneWidget);
  });

  testWidgets('picking two days returns exactly that range', (tester) async {
    DateTimeRange? captured;
    await tester.pumpWidget(MaterialApp(
      theme: PlotTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                captured = await showPlotDateRangePicker(
                  context,
                  firstDate: DateTime(2026, 1, 1),
                  lastDate: DateTime(2027, 12, 31),
                  initialRange: DateTimeRange(
                      start: DateTime(2026, 9, 1), end: DateTime(2026, 9, 1)),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('10').first);
    await tester.pump();
    await tester.tap(find.text('14').first);
    await tester.pump();
    await tester.tap(find.text('Use these dates'));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.start, DateTime(2026, 9, 10));
    expect(captured!.end, DateTime(2026, 9, 14));
  });

  testWidgets('a backwards second pick becomes the start, not an inverted range',
      (tester) async {
    DateTimeRange? captured;
    await tester.pumpWidget(MaterialApp(
      theme: PlotTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                captured = await showPlotDateRangePicker(
                  context,
                  firstDate: DateTime(2026, 1, 1),
                  lastDate: DateTime(2027, 12, 31),
                  initialRange: DateTimeRange(
                      start: DateTime(2026, 9, 1), end: DateTime(2026, 9, 1)),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('20').first);
    await tester.pump();
    await tester.tap(find.text('12').first);
    await tester.pump();
    await tester.tap(find.text('Use these dates'));
    await tester.pumpAndSettle();

    expect(captured!.start, DateTime(2026, 9, 12));
    expect(captured!.end, DateTime(2026, 9, 20));
  });

  testWidgets('the primary action is disabled until both ends are chosen', (tester) async {
    await _open(tester);

    ElevatedButton use() => tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Use these dates'));
    expect(use().onPressed, isNull);
    expect(find.text('Pick the first day'), findsOneWidget);

    await tester.tap(find.text('10').first);
    await tester.pump();
    // One end is not a range: still disabled, and it says which end is missing.
    expect(use().onPressed, isNull);
    expect(find.textContaining('pick the last day'), findsOneWidget);

    await tester.tap(find.text('12').first);
    await tester.pump();
    expect(use().onPressed, isNotNull);
  });

  testWidgets('today and the selection are told apart by more than fill', (tester) async {
    // C2 — both were an orange circle, one outlined and one filled. The
    // legend names the two marks, and today's outline is drawn in ink, not
    // in the selection hue.
    await _open(tester);
    expect(find.text('First and last day'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
  });

  testWidgets('cancelling returns null, distinct from an empty range', (tester) async {
    DateTimeRange? captured;
    var completed = false;
    await tester.pumpWidget(MaterialApp(
      theme: PlotTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                captured = await showPlotDateRangePicker(
                  context,
                  firstDate: DateTime(2026, 1, 1),
                  lastDate: DateTime(2027, 12, 31),
                );
                completed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(completed, isTrue);
    expect(captured, isNull);
  });
}
