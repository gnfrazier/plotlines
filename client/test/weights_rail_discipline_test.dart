// Issue #338 — the per-passage discipline picker, passage-inspector half. A
// discipline row is revealed in the weights rail under the passage's mode
// category, filtered to `disciplinesForCategory(mode)`, single-select and
// optional ("CATEGORY DEFAULT" = the category's own profile). Changing it
// marks the route stale, exactly as the MODE row already does, and
// tuned-vs-generic is read off `Discipline.tier` rather than chip order.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/weights_rail.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'support/display_units.dart';

Segment _segment({String mode = 'cycling', String? discipline}) => Segment(
      id: 'seg-1',
      mode: mode,
      discipline: discipline,
      shape: 'point_to_point',
      start: const [-105.27, 40.02],
      end: const [-105.2, 40.05],
      solve: SolveProvenance(solvedAt: '2026-08-25T00:00:00Z'),
    );

Trip _trip(Segment segment) {
  final day = Day(id: 'day-1', index: 1, segments: [segment]);
  return Trip(
    id: 'trip-1',
    title: 'Test trip',
    createdAt: '2026-08-25T00:00:00Z',
    updatedAt: '2026-08-25T00:00:00Z',
    days: [day],
  );
}

Future<void> _pump(WidgetTester tester, Segment segment) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentTripProvider.overrideWith((ref) => CurrentTripNotifier(ref)..open(_trip(segment))),
        metricUnits(),
      ],
      child: MaterialApp(
        home: Scaffold(body: WeightsRail(dayId: 'day-1', segment: segment)),
      ),
    ),
  );
  await tester.pump();
}

Segment _current(WidgetTester tester) => ProviderScope
        .containerOf(tester.element(find.byType(WeightsRail)))
    .read(currentTripProvider)
    .days
    .single
    .segments
    .single;

void main() {
  testWidgets('a cycling passage gets a discipline row: category default plus '
      'its three cycle disciplines', (tester) async {
    await _pump(tester, _segment());

    expect(find.text('DISCIPLINE'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'CATEGORY DEFAULT'), findsOneWidget);
    for (final label in ['ROAD', 'GRAVEL', 'MOUNTAIN']) {
      expect(find.widgetWithText(ChoiceChip, label), findsOneWidget, reason: label);
    }
    // A discipline the picker must not offer here — it belongs to hiking.
    expect(find.widgetWithText(ChoiceChip, 'TRAIL RUN'), findsNothing);
  });

  testWidgets('a transit passage — a category with no disciplines — shows no '
      'discipline row', (tester) async {
    await _pump(tester, _segment(mode: 'transit'));

    expect(find.text('DISCIPLINE'), findsNothing);
    expect(find.widgetWithText(ChoiceChip, 'CATEGORY DEFAULT'), findsNothing);
  });

  testWidgets('picking a discipline sets it on the passage and marks the route '
      'stale', (tester) async {
    await _pump(tester, _segment());

    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'GRAVEL'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'GRAVEL'));
    await tester.pump();

    expect(_current(tester).discipline, 'gravel');
    expect(_current(tester).solve?.stale, isTrue);
  });

  testWidgets('CATEGORY DEFAULT clears a discipline back to the category profile',
      (tester) async {
    await _pump(tester, _segment(discipline: 'mountain'));

    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'CATEGORY DEFAULT'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'CATEGORY DEFAULT'));
    await tester.pump();

    expect(_current(tester).discipline, isNull);
    expect(_current(tester).solve?.stale, isTrue);
  });

  testWidgets('the tuned-vs-generic line is read off the tier, not chip order',
      (tester) async {
    // `gravel` is first-class (SPIKE-03's measured theme); `run` is extended.
    await _pump(tester, _segment(discipline: 'gravel'));
    expect(find.text('Tuned dials, measured against real routes.'), findsOneWidget);

    await _pump(tester, _segment(mode: 'hiking', discipline: 'run'));
    expect(
      find.text('Its own dials — a first estimate, not tuned against real routes yet.'),
      findsOneWidget,
    );
  });
}
