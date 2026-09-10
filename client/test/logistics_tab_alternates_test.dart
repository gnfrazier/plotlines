// Story C4 (issue #40), FR20 [AMENDED v2.0] — the alternate authoring
// surfaces (Flow 11), reworked under issue #324. An alternate is one of two
// things: an *accommodation* alternate (an effort option a Character may take
// on their own copy) or a *branch* (a story choice carrying its own note,
// anchors, narration, and reveal).
//
// #324 inverted the order. Creation is a map gesture on a route that exists
// (`alternate_draft_test.dart` covers that half); the naming dialog and the
// card open *after* geometry, and the card is an inspector — it leads with
// where the path leaves the day, where it comes back, and what it costs. What
// this file asserts about that: the Logistics list no longer offers to create
// one, `not drawn` is gone from the row, the card shows the divergence, and
// the five blocks of standing prose that explained the model are now a
// tooltip, a teaching block, and two registry empty states.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/logistics_tab.dart';
import 'package:plotlines_client/presentation/widgets/alternate_editor_dialog.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';
import 'support/display_units.dart';

/// A straight west→east line at 40°N — the passage an alternate diverges from.
const _route = <Coord>[
  [-105.4, 40.0],
  [-105.0, 40.0],
];

LineString _drawn([List<Coord> coords = const [
  [-105.3, 40.0],
  [-105.2, 40.05],
  [-105.1, 40.0],
]]) =>
    LineString(coordinates: coords, source: 'authored');

Segment _leg(String id, {List<Alternate> alternates = const []}) => Segment(
      id: id,
      mode: 'cycling',
      shape: 'point_to_point',
      geometry: LineString(coordinates: _route),
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
      divergesAtM: 8000.0,
      rejoinsAtM: 24000.0,
      geometry: _drawn(),
    );

Alternate _accommodation(String id) => Alternate(
      id: id,
      kind: 'bypass',
      label: 'Toe River road',
      divergesAtM: 8000.0,
      rejoinsAtM: 24000.0,
      geometry: _drawn(),
    );

Future<ProviderContainer> _pump(WidgetTester tester, Day day, {List<Anchor> anchors = const []}) async {
  final container = ProviderContainer(overrides: [metricUnits()]);
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

/// The naming dialog, over a finished draft, on its own — the Route tab is
/// where it is opened from in the app, and the map canvas is not what this is
/// testing.
Future<AlternateNaming?> _pumpNaming(WidgetTester tester, AlternateDraft draft) async {
  AlternateNaming? result;
  final container = ProviderContainer(overrides: [metricUnits()]);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showAlternateNamingDialog(context, draft: draft);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

AlternateDraft _completeDraft() => AlternateDraft.on(_route)
    .tap(const [-105.3, 40.0])
    .tap(const [-105.1, 40.0])
    .tap(const [-105.2, 40.1]);

Alternate _onlyAlternate(ProviderContainer c) =>
    c.read(currentTripProvider).days.single.segments.single.alternates.single;

void main() {
  group('currentTripProvider — alternate mutations', () {
    test('addAlternateToSegment mints an alternate with the drawn path and its marks', () {
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

      final draft = _completeDraft();
      final made = n.addAlternateToSegment(
        'd1',
        's1',
        intent: 'branch',
        kind: 'extension',
        label: '  Mine road  ',
        geometry: draft.geometry!,
        divergesAtM: draft.divergesAtM,
        rejoinsAtM: draft.rejoinsAtM,
      );

      expect(made.isBranch, isTrue);
      expect(made.kind, 'extension');
      expect(made.label, 'Mine road'); // trimmed
      // #324 — an alternate arrives drawn. There is no "not drawn" state to
      // author into, and `$defs/line_string` would not have accepted one.
      expect(made.geometry.coordinates.length, greaterThanOrEqualTo(2));
      expect(made.geometry.source, 'authored');
      expect(made.divergesAtM, isNotNull);
      expect(made.rejoinsAtM, greaterThan(made.divergesAtM!));
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
      // The path and its marks are shape, not branch content — they survive.
      expect(a.geometry.coordinates.length, 3);
      expect(a.divergesAtM, 8000.0);
      expect(a.rejoinsAtM, 24000.0);
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

  group('the Logistics list', () {
    // #324 A — the card was in the wrong place in the flow. Creating an
    // alternate from a list, before any path exists, is what produced a form
    // for an abstraction; the list now points at the gesture instead.
    testWidgets('a passage with no alternates offers no create form, only where to draw one',
        (tester) async {
      await _pump(tester, Day(id: 'd1', index: 1, segments: [_leg('s1')]));

      expect(find.text('Add alternate'), findsNothing);
      final copy = emptyStateRegistry[EmptyStateContext.passageNoAlternates]!;
      expect(find.text('${copy.message} ${copy.nextAction}'), findsOneWidget);
      expect(copy.nextAction, contains('Route tab'));
      expect(find.text('ACCOMMODATION'), findsNothing);
      expect(find.text('BRANCH'), findsNothing);
    });

    testWidgets('existing alternates are grouped by intent', (tester) async {
      await _pump(
        tester,
        Day(id: 'd1', index: 1, segments: [
          _leg('s1', alternates: [_accommodation('acc'), _branch('br')]),
        ]),
      );
      expect(find.text('ACCOMMODATION'), findsOneWidget);
      expect(find.text('BRANCH'), findsOneWidget);
      expect(find.text('Toe River road'), findsOneWidget);
      expect(find.text('Past the Sugarloaf mine'), findsOneWidget);
    });

    // #324 — `not drawn` ceases to be an authorable state, and the row says
    // where the path goes instead of apologising for not having one.
    testWidgets('a row states where the alternate leaves and rejoins, never "not drawn"',
        (tester) async {
      await _pump(
        tester,
        Day(id: 'd1', index: 1, segments: [
          _leg('s1', alternates: [_accommodation('acc')]),
        ]),
      );

      expect(find.textContaining('not drawn'), findsNothing);
      expect(find.textContaining('leaves 8.0 km'), findsOneWidget);
      expect(find.textContaining('rejoins 24.0 km'), findsOneWidget);
    });
  });

  group('naming, after the path is drawn', () {
    testWidgets('the dialog measures the drawn path before it asks anything', (tester) async {
      final draft = _completeDraft();
      await _pumpNaming(tester, draft);

      expect(find.text('Name this alternate'), findsWidgets);
      expect(find.text('WHERE IT LEAVES AND REJOINS'), findsOneWidget);
      expect(find.text('LEAVES'), findsOneWidget);
      expect(find.text('REJOINS'), findsOneWidget);
      // Not a solve — and it says so rather than borrowing a solved line's
      // authority.
      expect(find.text('THIS PATH'), findsOneWidget);
      expect(find.text('DIFFERENCE'), findsOneWidget);
      expect(find.text('Measured off the line as drawn, not solved.'), findsOneWidget);
    });

    // #324 B — the two intent descriptions were a full paragraph each.
    testWidgets('each intent is one line, with the rest on the control as a tooltip',
        (tester) async {
      await _pumpNaming(tester, _completeDraft());

      expect(find.text('The same day at a different effort.'), findsOneWidget);
      expect(find.text('A choice that changes what the day contains.'), findsOneWidget);
      expect(
        find.textContaining('A Character can take it on their own copy'),
        findsNothing,
        reason: 'the accommodation paragraph is a tooltip now, not body copy',
      );
      expect(
        find.textContaining('its own plot points, its own narration'),
        findsNothing,
        reason: 'the branch paragraph is a tooltip now, not body copy',
      );
      // Both explanations are still reachable, on the controls they describe.
      final tooltips = tester.widgetList<Tooltip>(find.byType(Tooltip)).toList();
      expect(
        tooltips.any((t) => (t.message ?? '').contains('bypass takes the easiest line')),
        isTrue,
      );
      expect(
        tooltips.any((t) => (t.message ?? '').contains('chosen in the field')),
        isTrue,
      );
    });

    testWidgets('the shape defaults to what the drawn line measures', (tester) async {
      // A detour north of a straight route is longer than what it replaces.
      final long = _completeDraft();
      expect(long.impliedKind, 'extension');
      await _pumpNaming(tester, long);
      final shape = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(shape.selected, {'extension'});
    });

    testWidgets('naming returns the intent, the shape and the name', (tester) async {
      AlternateNaming? captured;
      final container = ProviderContainer(overrides: [metricUnits()]);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    captured = await showAlternateNamingDialog(
                      context,
                      draft: _completeDraft(),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Branch'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'Mine road');
      await tester.pump();
      await tester.tap(find.text('Create branch'));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured!.intent, 'branch');
      expect(captured!.label, 'Mine road');
    });

    // Issue #271, Finding 14 — the name field shipped a worked example from
    // the requirements conversation as its placeholder. A hint has to teach
    // the shape of the answer, not read as a half-filled form.
    testWidgets('the name placeholder is guidance, not a leftover requirements example',
        (tester) async {
      await _pumpNaming(tester, _completeDraft());
      expect(find.text('A short name the group will recognise'), findsOneWidget);
      expect(find.text('Toe River road'), findsNothing);
    });
  });

  group('the card, opened on a path that exists', () {
    testWidgets('leads with where it leaves, where it rejoins, and the difference',
        (tester) async {
      await _pump(
        tester,
        Day(id: 'd1', index: 1, segments: [
          _leg('s1', alternates: [_branch('a1')]),
        ]),
      );
      await tester.tap(find.text('Past the Sugarloaf mine'));
      await tester.pumpAndSettle();

      expect(find.text('WHERE IT LEAVES AND REJOINS'), findsOneWidget);
      expect(find.text('8.0 km'), findsOneWidget); // leaves
      expect(find.text('24.0 km'), findsOneWidget); // rejoins
      expect(find.text('DIFFERENCE'), findsOneWidget);
      expect(find.textContaining('not drawn'), findsNothing);
    });

    testWidgets('the branch note placeholder is guidance, not a requirements example',
        (tester) async {
      await _pump(
        tester,
        Day(id: 'd1', index: 1, segments: [
          _leg('s1', alternates: [_branch('a1')]),
        ]),
      );
      await tester.tap(find.text('Past the Sugarloaf mine'));
      await tester.pumpAndSettle();

      expect(find.text('What this path adds or avoids, in a sentence'), findsOneWidget);
      expect(
          find.text('Three miles of the old tramway grade, then the portal itself…'),
          findsNothing);
    });

    // #324 B — the hazard invariant (PRD §1.4–1.5) is real and must stay
    // reachable, but as a reveal-control tooltip rather than standing body
    // copy under the control.
    testWidgets('the hazard invariant is on the reveal control, not in the body',
        (tester) async {
      await _pump(
        tester,
        Day(id: 'd1', index: 1, segments: [
          _leg('s1', alternates: [_branch('a1')]),
        ]),
      );
      await tester.tap(find.text('Past the Sugarloaf mine'));
      await tester.pumpAndSettle();

      expect(find.text(kBranchRevealHazardNote), findsNothing,
          reason: 'no longer standing body copy');
      final tooltips = tester.widgetList<Tooltip>(find.byType(Tooltip)).toList();
      expect(
        tooltips.where((t) => t.message == kBranchRevealHazardNote).length,
        greaterThanOrEqualTo(1),
        reason: 'still reachable at the control it qualifies',
      );
      expect(kBranchRevealHazardNote, contains('Hazards on this path are shown to everyone'));
    });

    // #324 B — the anchor-by-reference paragraph is teaching material, and
    // `teaching.dart` exists for exactly this.
    testWidgets('the by-reference rule is a dismissible teaching block, not body copy',
        (tester) async {
      await _pump(
        tester,
        Day(id: 'd1', index: 1, segments: [
          _leg('s1', alternates: [_branch('a1')]),
        ]),
        anchors: [
          Anchor(
            id: 'anc1',
            title: 'The portal',
            coord: const [-105.2, 40.05],
            roles: [
              Role(id: 'r1', kind: RoleKind.narrative, reveal: RevealPolicy.onArrival),
            ],
          ),
        ],
      );
      await tester.tap(find.text('Past the Sugarloaf mine'));
      await tester.pumpAndSettle();

      final teaching = teachingRegistry[TeachingMoment.branchAnchorsByReference]!;
      expect(find.text(teaching.message), findsOneWidget);
      expect(find.text('Got it'), findsOneWidget);

      await tester.ensureVisible(find.text('Got it'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      expect(find.text(teaching.message), findsNothing);

      // K12a's reachability half: the help affordance the registry names is
      // on the surface, carrying the same copy.
      final help = tester.widget<Tooltip>(
        find.byKey(ValueKey(teaching.helpAffordance)),
      );
      expect(help.message, teaching.message);
    });

    // #324 — empty states are one line plus an action.
    testWidgets('the anchors and narration empty states are one line plus their next action',
        (tester) async {
      await _pump(
        tester,
        Day(id: 'd1', index: 1, segments: [
          _leg('s1', alternates: [
            Alternate(
              id: 'a1',
              kind: 'extension',
              intent: 'branch',
              label: 'Past the Sugarloaf mine',
              divergesAtM: 8000.0,
              rejoinsAtM: 24000.0,
              geometry: _drawn(),
            ),
          ]),
        ]),
      );
      await tester.tap(find.text('Past the Sugarloaf mine'));
      await tester.pumpAndSettle();

      final anchors = emptyStateRegistry[EmptyStateContext.branchNoAnchors]!;
      final narration = emptyStateRegistry[EmptyStateContext.branchNoNarration]!;
      expect(find.text('${anchors.message} ${anchors.nextAction}'), findsOneWidget);
      expect(find.text('${narration.message} ${narration.nextAction}'), findsOneWidget);
      expect(
        find.textContaining('Attached by reference, never copied'),
        findsNothing,
        reason: 'the teaching moved out of the empty state',
      );
    });

    testWidgets('an accommodation card has no branch fields', (tester) async {
      await _pump(
        tester,
        Day(id: 'd1', index: 1, segments: [
          _leg('s1', alternates: [_accommodation('acc')]),
        ]),
      );

      await tester.tap(find.text('Toe River road'));
      await tester.pumpAndSettle();

      expect(find.text('WHAT IS DIFFERENT ON THIS PATH'), findsNothing);
      expect(find.text('REVEAL FOR THIS BRANCH'), findsNothing);
      expect(find.text('Make this a branch'), findsOneWidget);
      // One line, and the action is the button above.
      expect(
        find.text('This alternate carries nothing of its own — the same day at a '
            'different effort.'),
        findsOneWidget,
      );
    });

    testWidgets('turning a branch with content into an accommodation asks first',
        (tester) async {
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
