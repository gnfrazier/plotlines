// F1 / FR133 (the Frodo principle) — a node's amenities (C5: water, toilets,
// food, shelter) are woven into its cue line in the Export tab's cue-sheet
// preview, not broken out into a separate logistics list. Exercised through
// the authored-content fallback path, same reasoning
// `export_tab_mode_change_test.dart` documents: no trip bbox means no
// sidecar call, and it's also what a Character sees when cue derivation is
// unreachable.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plotlines_ui/plotlines_ui.dart';
import 'package:printing/printing.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/export_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/settings_provider.dart';

Future<ProviderContainer> _pump(WidgetTester tester, Day day) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(
        Trip(
          id: 't1',
          title: 'Test trip',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          days: [day],
        ),
      );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ExportTab(trip: ref.watch(currentTripProvider)),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('a node with amenities is tagged PROVISION and its amenities are woven into the line',
      (tester) async {
    final day = Day(id: 'day-1', index: 1, segments: [
      Segment(
        id: 'seg-1',
        mode: 'cycling',
        shape: 'point_to_point',
        metrics: RouteMetrics(distanceM: 12000),
        nodes: [
          Node(
            id: 'n1',
            kind: NodeKind.poi,
            coord: const [-105.29, 40.0],
            distanceAlongM: 3000,
            title: 'Overlook Camp',
            amenities: const ['water', 'toilets'],
          ),
        ],
      ),
    ]);
    await _pump(tester, day);

    expect(find.textContaining('Overlook Camp — water, toilets'), findsOneWidget);
    expect(find.text('PROVISION'), findsOneWidget);
  });

  testWidgets('a node with no amenities carries no PROVISION tag', (tester) async {
    final day = Day(id: 'day-1', index: 1, segments: [
      Segment(
        id: 'seg-1',
        mode: 'cycling',
        shape: 'point_to_point',
        metrics: RouteMetrics(distanceM: 12000),
        nodes: [
          Node(id: 'n1', kind: NodeKind.poi, coord: const [-105.29, 40.0], title: 'Scenic view'),
        ],
      ),
    ]);
    await _pump(tester, day);

    expect(find.text('Scenic view'), findsOneWidget);
    expect(find.text('PROVISION'), findsNothing);
  });

  testWidgets('a segment surfaced constraint shows as an ON ROUTE cue line (FR128 / A11, issue #209)',
      (tester) async {
    final day = Day(id: 'day-1', index: 1, segments: [
      Segment(
        id: 'seg-1',
        mode: 'cycling',
        shape: 'point_to_point',
        metrics: RouteMetrics(distanceM: 12000),
        surfacedConstraints: [
          SurfacedConstraint(from: 10, to: 11, flags: const ['bicycle=dismount']),
          SurfacedConstraint(from: 40, to: 41, flags: const ['barrier=gate', 'ford=yes']),
        ],
      ),
    ]);
    await _pump(tester, day);

    expect(find.text('bicycle dismount'), findsOneWidget);
    expect(find.text('barrier gate, ford yes'), findsOneWidget);
    expect(find.text('ON ROUTE'), findsNWidgets(2));
  });

  testWidgets('a surfaced constraint sits at its distance-along, not the passage start (issue #401)',
      (tester) async {
    final day = Day(id: 'day-1', index: 1, segments: [
      Segment(
        id: 'seg-1',
        mode: 'cycling',
        shape: 'point_to_point',
        metrics: RouteMetrics(distanceM: 12000),
        nodes: [
          Node(
            id: 'n1',
            kind: NodeKind.poi,
            coord: const [-105.29, 40.0],
            distanceAlongM: 2000,
            title: 'Old mill',
          ),
        ],
        surfacedConstraints: [
          SurfacedConstraint(
              from: 10, to: 11, flags: const ['bicycle=dismount'],
              distanceAlongM: 3500, lengthM: 40),
          // Recorded before the engine measured one: passage start, as before.
          SurfacedConstraint(from: 40, to: 41, flags: const ['barrier=gate']),
        ],
      ),
    ]);
    final container = await _pump(tester, day);
    final df = container.read(displayFormatProvider);

    String mileOf(String instruction) => tester
        .widget<CueSheetRow>(find.byWidgetPredicate(
            (w) => w is CueSheetRow && w.instruction == instruction))
        .mile;
    expect(mileOf('bicycle dismount'), df.formatDistance(3500));
    expect(mileOf('barrier gate'), df.formatDistance(0));

    // Reading order follows distance: the mill at 2 km comes before the
    // dismount at 3.5 km, which #216 had pinned to the passage start.
    final rows = tester
        .widgetList<CueSheetRow>(find.byType(CueSheetRow))
        .map((r) => r.instruction)
        .toList();
    expect(rows.indexOf('Old mill'), lessThan(rows.indexOf('bicycle dismount')));
    expect(rows.indexOf('barrier gate'), lessThan(rows.indexOf('Old mill')));
  });

  testWidgets('the day cue section opens the shared previewer (issue #326)', (tester) async {
    final day = Day(id: 'day-1', index: 1, segments: [
      Segment(
        id: 'seg-1',
        mode: 'cycling',
        shape: 'point_to_point',
        metrics: RouteMetrics(distanceM: 12000),
        nodes: [
          Node(
            id: 'n1',
            kind: NodeKind.poi,
            coord: const [-105.29, 40.0],
            distanceAlongM: 3000,
            title: 'Overlook Camp',
            amenities: const ['water'],
          ),
        ],
      ),
    ]);
    await _pump(tester, day);

    await tester.tap(find.text('Print preview').last);
    // Not `pumpAndSettle`: the previewer's rasterizing spinner never settles
    // under this harness (no platform channel to answer it) — bounded pumps
    // clear the attribution fetch, the two vendored-font asset reads, and the
    // page-route transition instead.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    // The previewer is now `print_preview.dart`'s shared, paginated `PdfPreview`
    // (issue #326) rather than a `SelectableText` echo in a bare `Dialog` — the
    // content itself is a rendered PDF page, not a widget-tree string, so the
    // regression this suite guards against is the wiring (right day, right
    // surface), which the on-screen cue-list assertions above already cover
    // for the entries themselves.
    expect(find.byType(PdfPreview), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Day 1'), findsOneWidget);
  });

  testWidgets(
      "a day's own print preview blocks with no override while its route is stale (FR140/Flow 9)",
      (tester) async {
    final day = Day(id: 'day-1', index: 1, segments: [
      Segment(
        id: 'seg-1',
        mode: 'cycling',
        shape: 'point_to_point',
        metrics: RouteMetrics(distanceM: 12000),
        solve: SolveProvenance(stale: true),
      ),
    ]);
    await _pump(tester, day);

    await tester.tap(find.text('Print preview').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('stale'), findsWidgets);
    expect(find.byType(PdfPreview), findsNothing);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
  });
}
