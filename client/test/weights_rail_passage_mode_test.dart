// Issue #319 — the Route tab rail's PASSAGE MODE control. It used to offer
// all eight wire modes as chips regardless of the trip; now it is the same
// `PassageModePicker` New Route uses — a single-select pick from the trip's
// own mode set, with "add a mode to the trip" on the control — and changing
// the parent mode still marks the route stale (FR139/Q2, FR140/Q3).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/passage_mode_picker.dart';
import 'package:plotlines_client/presentation/widgets/plot_toggle_chip.dart';
import 'package:plotlines_client/presentation/widgets/weights_rail.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'support/display_units.dart';

Segment _segment({String mode = 'cycling'}) => Segment(
      id: 'seg-1',
      mode: mode,
      shape: 'point_to_point',
      start: const [-105.27, 40.02],
      end: const [-105.2, 40.05],
      solve: SolveProvenance(solvedAt: '2026-08-25T00:00:00Z', stale: false),
    );

Trip _trip(Segment segment, Set<String> modes) => Trip(
      id: 'trip-1',
      title: 'Test trip',
      createdAt: '2026-08-25T00:00:00Z',
      updatedAt: '2026-08-25T00:00:00Z',
      modes: modes,
      days: [Day(id: 'day-1', index: 1, segments: [segment])],
    );

Future<void> _pump(WidgetTester tester, Segment segment,
    {Set<String> modes = const {'cycling', 'hiking'}}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentTripProvider
            .overrideWith((ref) => CurrentTripNotifier(ref)..open(_trip(segment, modes))),
        metricUnits(),
      ],
      child: MaterialApp(
        home: Scaffold(body: WeightsRail(dayId: 'day-1', segment: segment)),
      ),
    ),
  );
  await tester.pump();
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(WeightsRail)));

Segment _current(WidgetTester tester) =>
    _container(tester).read(currentTripProvider).days.single.segments.single;

Finder _segmentLabel(String label) =>
    find.descendant(of: find.byType(SegmentedButton<String>), matching: find.text(label));

void main() {
  testWidgets('offers only the trip\'s modes, as one segmented single-select', (tester) async {
    await _pump(tester, _segment(), modes: const {'cycling', 'hiking'});

    expect(find.text('PASSAGE MODE'), findsOneWidget);
    expect(find.text('MODE'), findsNothing);
    expect(find.byType(PassageModePicker), findsOneWidget);
    expect(_segmentLabel('RIDE'), findsOneWidget);
    expect(_segmentLabel('HIKE'), findsOneWidget);
    for (final absent in ['PADDLE', 'SKI', 'DRIVE', 'TRANSIT']) {
      expect(_segmentLabel(absent), findsNothing, reason: absent);
      expect(find.widgetWithText(ChoiceChip, absent), findsNothing, reason: absent);
    }
    expect(tester.widget<SegmentedButton<String>>(find.byType(SegmentedButton<String>)).selected,
        {'cycling'});
  });

  testWidgets('picking another of the trip\'s modes changes the passage and marks it stale',
      (tester) async {
    await _pump(tester, _segment());

    await tester.ensureVisible(_segmentLabel('HIKE'));
    await tester.tap(_segmentLabel('HIKE'));
    await tester.pump();

    expect(_current(tester).mode, 'hiking');
    expect(_current(tester).solve?.stale, isTrue);
  });

  testWidgets('a passage whose mode the set somehow lacks is still shown selected',
      (tester) async {
    // Belt and braces: `open` and `_replaceDay` fold this in, but the control
    // itself must never render a passage with nothing lit.
    await _pump(tester, _segment(mode: 'driving'), modes: const {'cycling'});

    expect(_segmentLabel('DRIVE'), findsOneWidget);
    expect(tester.widget<SegmentedButton<String>>(find.byType(SegmentedButton<String>)).selected,
        {'driving'});
  });

  testWidgets('"Add a mode to the trip" opens the trip-mode prompt and the new mode '
      'is then offered here', (tester) async {
    await _pump(tester, _segment(), modes: const {'cycling'});
    expect(_segmentLabel('DRIVE'), findsNothing);

    await tester.ensureVisible(find.text('Add a mode to the trip'));
    await tester.tap(find.text('Add a mode to the trip'));
    await tester.pumpAndSettle();

    expect(find.text('How will you travel?'), findsOneWidget);
    final dialog = find.byType(AlertDialog);
    await tester.tap(find.descendant(of: dialog, matching: find.widgetWithText(PlotToggleChip, 'Drive')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(_container(tester).read(currentTripProvider).modes, {'cycling', 'driving'});
    expect(_segmentLabel('DRIVE'), findsOneWidget);
    // The passage itself is untouched by adding a mode to the trip.
    expect(_current(tester).mode, 'cycling');
    expect(_current(tester).solve?.stale, isNot(isTrue));
  });
}
