// Review fixes — the rail's text fields were seeded once from the value they
// edit and never again, so a value that changed underneath them (another
// segment's band of the same attribute, a new target re-banding FR8's
// distance row, Reset planning controls) left the field showing the old
// number, and the next keystroke wrote the old number's other half back.
// An emptied bound also never reached the stored band (`Band.copyWith`
// cannot clear a field), so the field read empty over a stored value.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/weights_rail.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';
import 'support/display_units.dart';

Finder _field(String hint) =>
    find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == hint);

String _text(WidgetTester tester, Finder f) => tester.widget<TextField>(f).controller!.text;

Future<void> _pumpRow(WidgetTester tester, Band band, {ValueChanged<Band>? onChanged}) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BandRow(key: const ValueKey('row'), band: band, onChanged: onChanged ?? (_) {}),
      ),
    ));

Trip _trip(Segment segment) => Trip(
      id: 'trip-1',
      title: 'Test trip',
      createdAt: '2026-08-25T00:00:00Z',
      updatedAt: '2026-08-25T00:00:00Z',
      days: [Day(id: 'day-1', index: 1, segments: [segment])],
    );

/// The rail as the Route tab mounts it: its segment read live off the trip,
/// so a notifier edit reaches the kept rail state as a new widget.
Future<ProviderContainer> _pumpRail(WidgetTester tester, Segment segment) async {
  final container = ProviderContainer(overrides: [
    metricUnits(),
    dayPlanningModeProvider('day-1').overrideWith((ref) => PlanningMode.explore),
  ]);
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(_trip(segment));
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) => WeightsRail(
            dayId: 'day-1',
            segment: ref.watch(currentTripProvider).days.single.segments.single,
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  return container;
}

void main() {
  testWidgets('a band row re-seeds when a different band arrives on the kept state',
      (tester) async {
    await _pumpRow(tester, Band(attribute: 'climb_m', min: 0, max: 500));
    await _pumpRow(tester, Band(attribute: 'climb_m', min: 1000, max: 2000));

    expect(_text(tester, _field('min')), '1000.0');
    expect(_text(tester, _field('max')), '2000.0');
  });

  testWidgets('a band row leaves text that already reads as the stored bound alone',
      (tester) async {
    await _pumpRow(tester, Band(attribute: 'climb_m', min: 0, max: 500));
    await tester.enterText(_field('min'), '12.');
    await _pumpRow(tester, Band(attribute: 'climb_m', min: 12, max: 500));

    expect(_text(tester, _field('min')), '12.');
  });

  testWidgets('emptying one bound clears it in the emitted band', (tester) async {
    Band? emitted;
    await _pumpRow(tester, Band(attribute: 'climb_m', min: 100, max: 500),
        onChanged: (b) => emitted = b);
    await tester.enterText(_field('min'), '');

    expect(emitted!.min, isNull);
    expect(emitted!.max, 500);
  });

  testWidgets('the distance band row follows a new target distance', (tester) async {
    final container = await _pumpRail(
      tester,
      Segment(id: 'seg-1', mode: 'cycling', shape: 'loop', start: const [-105.27, 40.02]),
    );
    final notifier = container.read(currentTripProvider.notifier);
    notifier.updateSegmentTargetDistance('day-1', 'seg-1', 50000);
    await tester.pump();
    notifier.updateSegmentTargetDistance('day-1', 'seg-1', 80000);
    await tester.pump();

    final stored = container.read(currentTripProvider).days.single.segments.single.targetDistance!;
    expect(_text(tester, _field('min')), stored.minM.toString());
    expect(_text(tester, _field('max')), stored.maxM.toString());
  });

  testWidgets('the target-distance field clears when Reset planning controls clears the target',
      (tester) async {
    final container = await _pumpRail(
      tester,
      Segment(
        id: 'seg-1',
        mode: 'cycling',
        shape: 'loop',
        start: const [-105.27, 40.02],
        targetDistance: TargetDistance(valueM: 50000),
      ),
    );
    final target = find.widgetWithText(TextField, 'Target distance (km)');
    expect(_text(tester, target), isNotEmpty);

    container.read(currentTripProvider.notifier).resetSegmentPlanning('day-1', 'seg-1');
    await tester.pump();

    expect(container.read(currentTripProvider).days.single.segments.single.targetDistance, isNull);
    expect(_text(tester, target), isEmpty);
  });
}
