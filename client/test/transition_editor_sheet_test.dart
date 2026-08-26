// Story B3 (issue #32), FR12 — the transition editor, reached from the day
// timeline strip's junction glyph, and the reorder prompt that stops a move
// from silently dropping what an Author wrote there (FR139).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/day_timeline_strip.dart';
import 'package:plotlines_client/presentation/widgets/transition_editor_sheet.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'package:plotlines_client/state/planner_ui_state.dart';

Segment _passage(String id, {String mode = 'cycling', Coord? start, Coord? end}) =>
    Segment(
      id: id,
      mode: mode,
      shape: 'point_to_point',
      start: start,
      end: end,
      metrics: RouteMetrics(distanceM: 12000),
    );

Future<ProviderContainer> _pump(
  WidgetTester tester,
  List<Segment> segments, {
  String? selectedId,
}) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(
        Trip(
          id: 't1',
          title: 'Test trip',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          days: [Day(id: 'day-1', index: 1, segments: segments)],
        ),
      );
  if (selectedId != null) {
    container.read(selectedSegmentProvider.notifier).state = ('day-1', selectedId);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => DayTimelineStrip(
              trip: ref.watch(currentTripProvider),
              activeDayId: 'day-1',
              onSelectDay: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  return container;
}

Day _day(ProviderContainer c) => c.read(currentTripProvider).days.single;

List<Segment> _rideThenPaddle() => [
      _passage('a', mode: 'cycling', start: const [-105.30, 40.00], end: const [-105.29, 40.00]),
      _passage('b', mode: 'paddling', start: const [-105.29, 40.00], end: const [-105.25, 40.00]),
    ];

Future<void> _openJunction(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.compare_arrows));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the junction between two passages opens the transition editor', (tester) async {
    await _pump(tester, _rideThenPaddle());
    await _openJunction(tester);

    expect(find.text('Mode change'), findsOneWidget);
    // Both modes named, with the shared labels — scoped to the sheet, since
    // the passage chips behind it carry the same words.
    Finder inSheet(String text) => find.descendant(
        of: find.byType(TransitionEditorForm), matching: find.text(text));
    expect(inSheet('Ride'), findsOneWidget);
    expect(inSheet('Paddle'), findsOneWidget);
  });

  testWidgets('FR12: instructions typed there attach to the junction', (tester) async {
    final container = await _pump(tester, _rideThenPaddle());
    await _openJunction(tester);

    await tester.enterText(find.widgetWithText(TextField, 'Title (e.g. "Put-in at Lyons")'),
        'Put-in at Lyons');
    await tester.enterText(find.widgetWithText(TextField, 'Instructions'),
        'Stash the bikes behind the outhouse.');
    await tester.tap(find.text('Save transition'));
    await tester.pumpAndSettle();

    final t = _day(container).transitions.single;
    expect(t.node?.kind, NodeKind.transition);
    expect(t.node?.title, 'Put-in at Lyons');
    expect(t.instructions, 'Stash the bikes behind the outhouse.');
  });

  testWidgets('a junction carrying instructions is distinguishable on the strip',
      (tester) async {
    final container = await _pump(tester, _rideThenPaddle());
    container.read(currentTripProvider.notifier).setTransitionNode(
        'day-1', _day(container).transitions.single.id,
        instructions: 'Put in below the bridge.');
    await tester.pump();

    // A different glyph, not just a different colour.
    expect(find.byIcon(Icons.sticky_note_2), findsOneWidget);
    expect(find.byIcon(Icons.compare_arrows), findsNothing);
  });

  testWidgets('reopening shows what was written, and Remove takes it off', (tester) async {
    final container = await _pump(tester, _rideThenPaddle());
    container.read(currentTripProvider.notifier).setTransitionNode(
        'day-1', _day(container).transitions.single.id,
        instructions: 'Put in below the bridge.');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.sticky_note_2));
    await tester.pumpAndSettle();
    expect(find.text('Put in below the bridge.'), findsOneWidget);

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(_day(container).transitions.single.node, isNull);
    // The junction itself survives — two passages still meet there.
    expect(_day(container).transitions.length, 1);
  });

  testWidgets('a junction between two passages of the same mode says so plainly',
      (tester) async {
    await _pump(tester, [
      _passage('a', mode: 'cycling', start: const [-105.30, 40.00], end: const [-105.29, 40.00]),
      _passage('b', mode: 'cycling', start: const [-105.29, 40.00], end: const [-105.25, 40.00]),
    ]);
    await _openJunction(tester);

    expect(find.text('Transition'), findsWidgets);
    expect(find.textContaining('same mode'), findsOneWidget);
  });

  testWidgets('the editor names B2\'s gap when the two passages do not meet', (tester) async {
    await _pump(tester, [
      _passage('a', mode: 'cycling', start: const [-105.30, 40.00], end: const [-105.30, 40.00]),
      _passage('b', mode: 'paddling', start: const [-105.29, 40.00], end: const [-105.25, 40.00]),
    ]);
    // The warning glyph replaces the plain one when the endpoints are apart.
    await tester.tap(find.byIcon(Icons.compare_arrows));
    await tester.pumpAndSettle();

    expect(find.textContaining('do not meet'), findsOneWidget);
    expect(find.textContaining('852 m'), findsOneWidget);
  });

  group('FR139 — a reorder that would strand instructions asks first', () {
    Future<ProviderContainer> pumpThreeWithInstruction(WidgetTester tester) async {
      final container = await _pump(
        tester,
        [
          _passage('a', start: const [-105.30, 40.00], end: const [-105.29, 40.00]),
          _passage('b', mode: 'paddling', start: const [-105.29, 40.00], end: const [-105.25, 40.00]),
          _passage('c', mode: 'hiking', start: const [-105.25, 40.00], end: const [-105.24, 40.00]),
        ],
        selectedId: 'b',
      );
      container.read(currentTripProvider.notifier).setTransitionNode(
          'day-1', _day(container).transitions.first.id,
          instructions: 'Stash the bikes behind the outhouse.');
      await tester.pump();
      return container;
    }

    testWidgets('names the instructions it would drop, and cancelling keeps the order',
        (tester) async {
      final container = await pumpThreeWithInstruction(tester);

      await tester.tap(find.byTooltip('Move earlier in the day'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Stash the bikes behind the outhouse.'), findsOneWidget);
      await tester.tap(find.text('Leave the order'));
      await tester.pumpAndSettle();

      expect(_day(container).segments.map((s) => s.id), ['a', 'b', 'c']);
      expect(_day(container).transitions.first.instructions,
          'Stash the bikes behind the outhouse.');
    });

    testWidgets('confirming carries the move out', (tester) async {
      final container = await pumpThreeWithInstruction(tester);

      await tester.tap(find.byTooltip('Move earlier in the day'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move anyway'));
      await tester.pumpAndSettle();

      expect(_day(container).segments.map((s) => s.id), ['b', 'a', 'c']);
      expect(_day(container).transitions.every((t) => t.instructions == null), isTrue);
    });

    testWidgets('a move that strands nothing authored just happens', (tester) async {
      final container = await _pump(
        tester,
        [_passage('a'), _passage('b'), _passage('c')],
        selectedId: 'b',
      );

      await tester.tap(find.byTooltip('Move earlier in the day'));
      await tester.pumpAndSettle();

      expect(find.text('Move anyway'), findsNothing);
      expect(_day(container).segments.map((s) => s.id), ['b', 'a', 'c']);
    });
  });
}
