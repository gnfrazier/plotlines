// Issue #326 — the shared print previewer both Export tab entry points call
// (`export_tab.dart`'s itinerary and per-day cue sections). Exercised
// directly here, independent of `ExportTab`, since `print_preview.dart` is
// the actual thing this issue delivers: one previewer, several documents.
//
// Two properties carry the weight. FR140/Flow 9's "print blocks with no
// override" — a stale printed page is believed for hours with nothing to
// re-check it against, so this has to refuse outright rather than route
// through export's resolvable stale list. And attribution — K10/K11 — has
// to come from the loaded layer set, falling back to the bundled static
// credits only when no sidecar is reachable, never silently empty.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:printing/printing.dart';

import 'package:plotlines_client/data/routing_client.dart';
import 'package:plotlines_client/domain/attribution_line.dart';
import 'package:plotlines_client/domain/stale_work.dart';
import 'package:plotlines_client/presentation/widgets/print_preview.dart';

StaleItem _staleItem() => const StaleItem(
      dayId: 'd1',
      dayIndex: 1,
      segmentId: 's1',
      mode: 'cycling',
      shape: 'loop',
    );

Future<void> _pumpTrigger(
  WidgetTester tester, {
  required List<StaleItem> staleItems,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPrintPreview(
              context,
              document: const CueSheetPrintDocument(title: 'Day 1', lines: []),
              staleItems: staleItems,
              attribution: aboutStaticAttribution,
            ),
            child: const Text('Print preview'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Print preview'));
  // Not `pumpAndSettle`: a clean document's `PdfPreview` shows an
  // indeterminate rasterizing spinner while it waits on a platform channel
  // this test harness never answers, which never settles. A few bounded
  // pumps are enough to clear the attribution fetch, the two vendored-font
  // asset reads, the page-route transition, and the previewer's first frame.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  group('showPrintPreview — FR140/Flow 9 stale gate', () {
    testWidgets('a clean document opens the paginated previewer', (tester) async {
      await _pumpTrigger(tester, staleItems: const []);

      expect(find.byType(PdfPreview), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Day 1'), findsOneWidget);
    });

    testWidgets('one stale item blocks outright, no override, naming the count',
        (tester) async {
      await _pumpTrigger(tester, staleItems: [_staleItem()]);

      expect(find.textContaining('1 stale item needs re-solving'), findsOneWidget);
      expect(find.byType(PdfPreview), findsNothing);

      // No override anywhere on the block — the only action is dismissal.
      expect(find.text('Close'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(PdfPreview), findsNothing);
    });

    testWidgets('several stale items pluralize the count', (tester) async {
      await _pumpTrigger(tester, staleItems: [_staleItem(), _staleItem()]);

      expect(find.textContaining('2 stale items need re-solving'), findsOneWidget);
    });
  });

  group('fetchPrintAttribution', () {
    test('falls back to the bundled static credits when the sidecar is unreachable', () async {
      // Port 0 refuses immediately rather than hanging — no fake HTTP layer
      // needed to exercise the catch branch.
      final client = RoutingClient('http://127.0.0.1:0');

      final lines = await fetchPrintAttribution(client);

      expect(lines, aboutStaticAttribution);
    });
  });
}
