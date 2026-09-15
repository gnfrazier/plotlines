// FR142b, K12 / N4a (issue #384) — regression coverage for the anchors
// view's "attached" status and its attach/detach action.
//
// Before this fix, `_isAttached` guessed attachment from a title-string
// match against `Day.nodes` — two same-titled objects with no real
// structural link would read as attached, and a same-titled node scoped to
// a `Segment` (rather than the day directly) would never match at all.
// These tests exercise the real link (`Role.dayId`/`Role.segmentId`) N4a's
// own AC requires: unattached anchors must be findable *and re-attachable*
// through this view.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/screens/plan_tabs/layers_tab.dart';
import 'package:plotlines_client/state/current_trip_provider.dart';

Trip _tripWithTitleCollisionButNoLink() => Trip(
      id: 't1',
      title: 'Test trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: [
        Day(id: 'd1', index: 1, title: 'Approach day', nodes: [
          // Same title as the anchor below, but nothing on this node
          // references the anchor's id — the old heuristic's false positive.
          Node(id: 'n1', kind: NodeKind.poi, coord: const [-105.27, 40.02], title: 'Overlook'),
        ]),
      ],
      anchors: [
        Anchor(
          id: 'a1',
          coord: const [-105.27, 40.02],
          title: 'Overlook',
          roles: [Role(id: 'r1', kind: RoleKind.narrative)],
        ),
      ],
    );

Trip _tripWithDaysAndSegment() => Trip(
      id: 't1',
      title: 'Test trip',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      days: [
        Day(id: 'd1', index: 1, title: 'Warm-up'),
        Day(
          id: 'd2',
          index: 2,
          title: 'Ridge day',
          segments: [Segment(id: 'seg1', mode: 'cycling', shape: 'point_to_point', title: 'Ridge climb')],
        ),
      ],
      anchors: [
        Anchor(
          id: 'a1',
          coord: const [-105.27, 40.02],
          title: 'Overlook',
          roles: [Role(id: 'r1', kind: RoleKind.narrative)],
        ),
      ],
    );

Future<void> _pump(WidgetTester tester, Trip trip) => tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentTripProvider.overrideWith((ref) => CurrentTripNotifier(ref)..open(trip)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(builder: (context, ref, _) {
              final t = ref.watch(currentTripProvider);
              return AnchorsView(trip: t);
            }),
          ),
        ),
      ),
    );

// The "Unattached"/"Attached" filter chips share their label text with the
// per-role status line, so status assertions are scoped to the role list
// (the chips live in the `Wrap` above it, outside the `ListView`).
Finder _status(String text) => find.descendant(of: find.byType(ListView), matching: find.text(text));

void main() {
  testWidgets('a title match with no real link reads as unattached (regression)', (tester) async {
    await _pump(tester, _tripWithTitleCollisionButNoLink());
    expect(_status('Unattached'), findsOneWidget);
    expect(find.textContaining('Day 1'), findsNothing);
  });

  testWidgets('attaching a role to a day updates its status', (tester) async {
    await _pump(tester, _tripWithDaysAndSegment());
    expect(_status('Unattached'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.link));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Day 2 — Ridge day'));
    await tester.pumpAndSettle();

    expect(_status('Unattached'), findsNothing);
    expect(_status('Day 2 — Ridge day'), findsOneWidget);
  });

  testWidgets('attaching to a specific passage narrows the status below the day', (tester) async {
    await _pump(tester, _tripWithDaysAndSegment());

    await tester.tap(find.byIcon(Icons.link));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Day 2 — Ridge day · Ridge climb'));
    await tester.pumpAndSettle();

    expect(_status('Day 2 — Ridge day · Ridge climb'), findsOneWidget);
  });

  testWidgets('detach clears the attachment back to unattached', (tester) async {
    await _pump(tester, _tripWithDaysAndSegment());

    await tester.tap(find.byIcon(Icons.link));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Day 2 — Ridge day'));
    await tester.pumpAndSettle();
    expect(_status('Day 2 — Ridge day'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.link));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Detach'));
    await tester.pumpAndSettle();

    expect(_status('Unattached'), findsOneWidget);
  });

  testWidgets('the attached/unattached filter reflects the real link, not a title guess', (tester) async {
    await _pump(tester, _tripWithTitleCollisionButNoLink());

    await tester.tap(find.widgetWithText(ChoiceChip, 'Attached'));
    await tester.pumpAndSettle();
    expect(find.text('Overlook'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Unattached'));
    await tester.pumpAndSettle();
    expect(find.text('Overlook'), findsOneWidget);
  });
}
