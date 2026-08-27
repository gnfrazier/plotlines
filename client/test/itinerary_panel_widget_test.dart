// F2 (FR48, FR133) — the Export tab's itinerary section: master/individual
// scope toggle, per-day attendance filtering, and the print-preview
// document. File export (`getSaveLocation`) opens a native OS dialog and
// isn't exercised here, matching the rest of this test suite's coverage of
// `export_tab.dart` (no test drives the GPX/TCX/GeoJSON export buttons
// either) — this covers everything upstream of that native call.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/export_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

Segment _passage(String id, {required String mode, double distanceM = 12000}) => Segment(
      id: id,
      mode: mode,
      shape: 'point_to_point',
      metrics: RouteMetrics(distanceM: distanceM),
    );

Future<void> _pump(WidgetTester tester, List<Day> days) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(
        Trip(
          id: 't1',
          title: 'Test trip',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          days: days,
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
}

List<Day> _twoDayTrip() => [
      Day(id: 'd1', index: 1, title: 'To the Gap', segments: [
        _passage('s1', mode: 'cycling', distanceM: 42000),
      ]),
      Day(id: 'd2', index: 2, title: 'To the Overlook', segments: [
        _passage('s2', mode: 'hiking', distanceM: 8000),
      ]),
    ];

void main() {
  group('ItinerarySection — master (default)', () {
    testWidgets('previews every day\'s heading and narrative account', (tester) async {
      await _pump(tester, _twoDayTrip());

      expect(find.text('Day 1 — To the Gap'), findsOneWidget);
      expect(find.text('Day 2 — To the Overlook'), findsOneWidget);
      expect(find.textContaining('Ride (42.0 km)'), findsOneWidget);
      expect(find.textContaining('Hike (8.0 km)'), findsOneWidget);
    });
  });

  group('ItinerarySection — individual', () {
    testWidgets('shows no days until at least one is marked attended', (tester) async {
      await _pump(tester, _twoDayTrip());

      await tester.tap(find.text('INDIVIDUAL'));
      await tester.pumpAndSettle();

      expect(find.text('No days selected yet.'), findsOneWidget);
      expect(find.text('Day 1 — To the Gap'), findsNothing);
    });

    testWidgets('reflects only the attended day, dropping the other', (tester) async {
      await _pump(tester, _twoDayTrip());

      await tester.tap(find.text('INDIVIDUAL'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('DAY 1'));
      await tester.pumpAndSettle();

      expect(find.text('Day 1 — To the Gap'), findsOneWidget);
      expect(find.text('Day 2 — To the Overlook'), findsNothing);
    });

    testWidgets('switching back to master restores every day', (tester) async {
      await _pump(tester, _twoDayTrip());

      await tester.tap(find.text('INDIVIDUAL'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('DAY 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MASTER'));
      await tester.pumpAndSettle();

      expect(find.text('Day 1 — To the Gap'), findsOneWidget);
      expect(find.text('Day 2 — To the Overlook'), findsOneWidget);
    });
  });

  group('ItinerarySection — print preview', () {
    testWidgets('opens a chrome-free document with the same narrative content', (tester) async {
      await _pump(tester, _twoDayTrip());

      await tester.tap(find.text('Print preview'));
      await tester.pumpAndSettle();

      expect(find.textContaining('# Test trip'), findsOneWidget);
      expect(find.textContaining('## Day 1 — To the Gap'), findsOneWidget);
      expect(find.textContaining('Ride (42.0 km)'), findsWidgets);
    });
  });
}
