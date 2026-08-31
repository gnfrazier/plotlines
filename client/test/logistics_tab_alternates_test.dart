// Story C4 (issue #40), FR20 [AMENDED v2.0] — the alternate authoring
// surface (Flow 11). An alternate is one of two things: an *accommodation*
// alternate (an effort option a Character may take on their own copy) or a
// *branch* (a story choice carrying its own note, anchors, narration, and
// reveal). This covers the create dialog's intent vocabulary, the editor's
// branch-vs-accommodation shape, the branch→accommodation orphan prompt, and
// the `currentTripProvider` mutations underneath — wired through a real
// provider the same way the C1/C2/C3 Logistics tests are.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/logistics_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

Segment _leg(String id, {List<Alternate> alternates = const []}) => Segment(
      id: id,
      mode: 'cycling',
      shape: 'point_to_point',
      alternates: alternates,
    );

Alternate _branch(String id) => Alternate(
      id: id,
      kind: 'extension',
      intent: 'branch',
      label: 'Past the Sugarloaf mine',
      note: 'Three miles of old tramway grade.',
      narration: Narration(triggerDistanceM: 100.0, text: 'The portal.'),
      reveal: 'on_arrival',
      geometry: LineString(coordinates: const [], source: 'authored'),
    );

Future<ProviderContainer> _pump(WidgetTester tester, Day day, {List<Anchor> anchors = const []}) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(currentTripProvider.notifier).open(
        Trip(
          id: 't1',
          title: 'Test trip',
          createdAt: '2026-01-01T00:00:00Z',
          updatedAt: '2026-01-01T00:00:00Z',
          days: [day],
          anchors: anchors,
        ),
      );
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

Alternate _onlyAlternate(ProviderContainer c) =>
    c.read(currentTripProvider).days.single.segments.single.alternates.single;

void main() {
  group('currentTripProvider — alternate mutations', () {
    test('addAlternateToSegment mints an alternate with the given intent, kind, and label', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(currentTripProvider.notifier);
      n.open(Trip(
        id: 't',
        title: 't',
        createdAt: 'x',
        updatedAt: 'x',
        days: [Day(id: 'd1', index: 1, segments: [_leg('s1')])],
      ));

      final made = n.addAlternateToSegment('d1', 's1', intent: 'branch', kind: 'extension', label: '  Mine road  ');

      expect(made.isBranch, isTrue);
      expect(made.kind, 'extension');
      expect(made.label, 'Mine road'); // trimmed
      expect(made.geometry.coordinates, isEmpty); // not drawn yet
      expect(_onlyAlternate(container).id, made.id);
    });

    test('convertAlternateIntent branch → accommodation drops the branch content', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(currentTripProvider.notifier);
      n.open(Trip(
        id: 't',
        title: 't',
        createdAt: 'x',
        updatedAt: 'x',
        days: [
          Day(id: 'd1', index: 1, segments: [_leg('s1', alternates: [_branch('a1')])]),
        ],
      ));

      n.convertAlternateIntent('d1', 's1', 'a1', 'accommodation');

      final a = _onlyAlternate(container);
      expect(a.isBranch, isFalse);
      expect(a.note, isNull);
      expect(a.narration, isNull);
      expect(a.reveal, isNull);
      expect(a.kind, 'extension'); // shape kept
    });

    test('removeAlternateFromSegment takes only the named alternate', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(currentTripProvider.notifier);
      n.open(Trip(
        id: 't',
        title: 't',
        createdAt: 'x',
        updatedAt: 'x',
        days: [
          Day(id: 'd1', index: 1, segments: [
            _leg('s1', alternates: [_branch('a1'), _branch('a2')]),
          ]),
        ],
      ));

      n.removeAlternateFromSegment('d1', 's1', 'a1');

      final alts = container.read(currentTripProvider).days.single.segments.single.alternates;
      expect(alts.map((a) => a.id), ['a2']);
    });
  });

  group('the authoring surface', () {
    testWidgets('a passage with no alternates shows only the Add alternate affordance', (tester) async {
      await _pump(tester, Day(id: 'd1', index: 1, segments: [_leg('s1')]));
      expect(find.text('Add alternate'), findsOneWidget);
      expect(find.text('ACCOMMODATION'), findsNothing);
      expect(find.text('BRANCH'), findsNothing);
    });

    testWidgets('existing alternates are grouped by intent', (tester) async {
      await _pump(
        tester,
        Day(id: 'd1', index: 1, segments: [
          _leg('s1', alternates: [
            Alternate(
                id: 'acc',
                kind: 'bypass',
                label: 'Toe River road',
                geometry: LineString(coordinates: const [], source: 'authored')),
            _branch('br'),
          ]),
        ]),
      );
      expect(find.text('ACCOMMODATION'), findsOneWidget);
      expect(find.text('BRANCH'), findsOneWidget);
      expect(find.text('Toe River road'), findsOneWidget);
      expect(find.text('Past the Sugarloaf mine'), findsOneWidget);
    });

    testWidgets('the create dialog names the intent, then opens the editor with the branch fields', (tester) async {
      final container = await _pump(tester, Day(id: 'd1', index: 1, segments: [_leg('s1')]));

      await tester.tap(find.text('Add alternate'));
      await tester.pumpAndSettle();

      // Vocabulary moment — pick Branch, name it, create.
      expect(find.text('What kind of alternate is this?'), findsOneWidget);
      await tester.tap(find.text('Branch'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'Mine road');
      await tester.pump();
      await tester.tap(find.text('Create branch'));
      await tester.pumpAndSettle();

      // Straight into the editor; the branch-only fields are present.
      expect(find.text('WHAT IS DIFFERENT ON THIS PATH'), findsOneWidget);
      expect(find.text('REVEAL FOR THIS BRANCH'), findsOneWidget);

      final made = _onlyAlternate(container);
      expect(made.isBranch, isTrue);
      expect(made.label, 'Mine road');
    });

    testWidgets('an accommodation editor has no branch fields', (tester) async {
      await _pump(
        tester,
        Day(id: 'd1', index: 1, segments: [
          _leg('s1', alternates: [
            Alternate(
                id: 'acc',
                kind: 'bypass',
                label: 'Toe River road',
                geometry: LineString(coordinates: const [], source: 'authored')),
          ]),
        ]),
      );

      await tester.tap(find.text('Toe River road'));
      await tester.pumpAndSettle();

      expect(find.text('WHAT IS DIFFERENT ON THIS PATH'), findsNothing);
      expect(find.text('REVEAL FOR THIS BRANCH'), findsNothing);
      expect(find.text('Make this a branch'), findsOneWidget);
    });

    testWidgets('turning a branch with content into an accommodation asks first', (tester) async {
      final container = await _pump(
        tester,
        Day(id: 'd1', index: 1, segments: [
          _leg('s1', alternates: [_branch('a1')]),
        ]),
      );

      await tester.tap(find.text('Past the Sugarloaf mine'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Make this an accommodation'));
      await tester.pumpAndSettle();

      // The scope prompt, not a silent conversion.
      expect(find.text('Turn this branch into an effort option?'), findsOneWidget);
      expect(_onlyAlternate(container).isBranch, isTrue); // nothing changed yet

      await tester.tap(find.text('Give up the content and convert'));
      await tester.pumpAndSettle();

      final a = _onlyAlternate(container);
      expect(a.isBranch, isFalse);
      expect(a.note, isNull);
    });
  });
}
