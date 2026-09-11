// Story C14 (issue #51), FR35 — the Logistics tab's offline-buffer input:
// enterable in the Author's active unit (mi/km), stored as a trip-level
// download parameter distinct from any day, and cleared when the field is
// emptied.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/logistics_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'support/display_units.dart';

/// The offline-buffer field is the only `TextField` on the tab with this
/// hint — `_TripDurationCard`'s day-count field and `_DayLimitRow`'s
/// min/max fields all use their own distinct hints.
final Finder _bufferField =
    find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'none');

Future<ProviderContainer> _pump(WidgetTester tester, Trip trip, {List<Override> extra = const []}) async {
  final container = ProviderContainer(overrides: [metricUnits(), ...extra]);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(trip);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => LogisticsTab(
              trip: ref.watch(currentTripProvider),
              onOpenSegment: (_, _) {},
            ),
          ),
        ),
      ),
    ),
  );
  return container;
}

Trip _trip({double? offlineBufferM}) => Trip(
      id: 't1',
      title: 'Test trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      offlineBufferM: offlineBufferM,
    );

void main() {
  testWidgets('shows the offline buffer field labeled with the active unit', (tester) async {
    await _pump(tester, _trip());
    expect(find.text('Offline buffer around the finished route'), findsOneWidget);
    expect(find.text('km'), findsOneWidget);
  });

  testWidgets('an unset buffer shows an empty field', (tester) async {
    await _pump(tester, _trip());
    expect(tester.widget<TextField>(_bufferField).controller!.text, isEmpty);
  });

  testWidgets('a set buffer pre-fills the field in the active unit (km)', (tester) async {
    await _pump(tester, _trip(offlineBufferM: 8000.0));
    expect(tester.widget<TextField>(_bufferField).controller!.text, '8');
  });

  testWidgets('typing a value stores it as metres, distinct from the authoring bbox/home region',
      (tester) async {
    final container = await _pump(tester, _trip());

    await tester.enterText(_bufferField, '8');
    await tester.pump();

    expect(container.read(currentTripProvider).offlineBufferM, 8000.0);
  });

  testWidgets('typing under miles converts to metres before it reaches the trip', (tester) async {
    final container = await _pump(tester, _trip(), extra: [imperialUnits()]);

    await tester.enterText(_bufferField, '5');
    await tester.pump();

    expect(container.read(currentTripProvider).offlineBufferM, closeTo(8046.72, 0.01));
  });

  testWidgets('clearing the field clears the stored buffer', (tester) async {
    final container = await _pump(tester, _trip(offlineBufferM: 8000.0));

    await tester.enterText(_bufferField, '');
    await tester.pump();

    expect(container.read(currentTripProvider).offlineBufferM, isNull);
  });
}
