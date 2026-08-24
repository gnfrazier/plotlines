// N1 (PRD FR120) / Author Flows MVP Flow 9 "Shrinking the bounding box" —
// "nothing is discarded silently... choose what happens to each, or move
// the bounds instead." Exercises the three choices end to end through
// `reviseTripBbox`, plus the no-prompt path when nothing would be excluded.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/trip_bbox.dart';
import 'package:plotlines_client/domain/trip_bbox_revision.dart';
import 'package:plotlines_client/presentation/widgets/trip_bbox_shrink_prompt.dart';

const _original = TripBbox(minLat: 40.0, minLon: -105.3, maxLat: 40.2, maxLon: -105.1);
const _survivingAnchor = AnchorLocation(id: 'a1', label: 'Survives', point: [-105.2, 40.1]);
const _excludedAnchor =
    AnchorLocation(id: 'a2', label: 'Roan Mountain gardens', point: [-105.11, 40.19]);

Widget _harness({
  required TripBbox proposed,
  required List<AnchorLocation> anchors,
  required ValueChanged<TripBbox> onApply,
  ValueChanged<List<AnchorLocation>>? onRemoveAnchors,
}) {
  return MaterialApp(
    home: Builder(builder: (context) {
      return ElevatedButton(
        onPressed: () => reviseTripBbox(
          context,
          proposed: proposed,
          anchors: anchors,
          onApply: onApply,
          onRemoveAnchors: onRemoveAnchors,
        ),
        child: const Text('revise'),
      );
    }),
  );
}

void main() {
  testWidgets('a revision that excludes no anchors applies immediately, no dialog', (tester) async {
    TripBbox? applied;
    final enlarged = _original.expandToInclude([[-105.0, 40.3]]);
    await tester.pumpWidget(_harness(
      proposed: enlarged,
      anchors: const [_survivingAnchor],
      onApply: (b) => applied = b,
    ));
    await tester.tap(find.text('revise'));
    await tester.pumpAndSettle();

    expect(applied, enlarged);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a shrink that would exclude an anchor shows the prompt naming it', (tester) async {
    TripBbox? applied;
    final shrunk = _original.copyWith(maxLon: -105.15, maxLat: 40.15);
    await tester.pumpWidget(_harness(
      proposed: shrunk,
      anchors: const [_survivingAnchor, _excludedAnchor],
      onApply: (b) => applied = b,
    ));
    await tester.tap(find.text('revise'));
    await tester.pump();

    expect(find.text('1 anchor would fall outside'), findsOneWidget);
    expect(find.text(_excludedAnchor.label), findsOneWidget);
    expect(find.text(_survivingAnchor.label), findsNothing);
    expect(applied, isNull); // still waiting on the Author's choice
  });

  testWidgets('keep the bounds: cancels the change, nothing is applied', (tester) async {
    TripBbox? applied;
    final shrunk = _original.copyWith(maxLon: -105.15, maxLat: 40.15);
    await tester.pumpWidget(_harness(
      proposed: shrunk,
      anchors: const [_excludedAnchor],
      onApply: (b) => applied = b,
    ));
    await tester.tap(find.text('revise'));
    await tester.pump();

    await tester.tap(find.text('Keep the bounds where they are'));
    await tester.pumpAndSettle();

    expect(applied, isNull);
  });

  testWidgets('move the bounds: applies the smallest box that includes every excluded anchor',
      (tester) async {
    TripBbox? applied;
    final shrunk = _original.copyWith(maxLon: -105.15, maxLat: 40.15);
    await tester.pumpWidget(_harness(
      proposed: shrunk,
      anchors: const [_excludedAnchor],
      onApply: (b) => applied = b,
    ));
    await tester.tap(find.text('revise'));
    await tester.pump();

    await tester.tap(find.text('Move the bounds to include it'));
    await tester.pumpAndSettle();

    expect(applied, isNotNull);
    expect(applied!.contains(_excludedAnchor.point), isTrue);
    // Grows only as far as needed to include the anchor, from the proposed
    // (shrunk) box — not back to the original extent.
    expect(applied!.maxLon, _excludedAnchor.point[0]);
    expect(applied!.maxLat, _excludedAnchor.point[1]);
    expect(applied!.minLat, shrunk.minLat);
    expect(applied!.minLon, shrunk.minLon);
  });

  testWidgets('remove these anchors: applies the shrink and reports exactly the excluded anchors',
      (tester) async {
    TripBbox? applied;
    List<AnchorLocation>? removed;
    final shrunk = _original.copyWith(maxLon: -105.15, maxLat: 40.15);
    await tester.pumpWidget(_harness(
      proposed: shrunk,
      anchors: const [_survivingAnchor, _excludedAnchor],
      onApply: (b) => applied = b,
      onRemoveAnchors: (a) => removed = a,
    ));
    await tester.tap(find.text('revise'));
    await tester.pump();

    await tester.tap(find.text('Remove this anchor'));
    await tester.pumpAndSettle();

    expect(applied, shrunk);
    expect(removed, [_excludedAnchor]);
  });

  testWidgets('dismissing the dialog without a choice behaves like keep bounds', (tester) async {
    TripBbox? applied;
    final shrunk = _original.copyWith(maxLon: -105.15, maxLat: 40.15);
    await tester.pumpWidget(_harness(
      proposed: shrunk,
      anchors: const [_excludedAnchor],
      onApply: (b) => applied = b,
    ));
    await tester.tap(find.text('revise'));
    await tester.pump();

    // Tap outside the dialog to dismiss it via the barrier.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(applied, isNull);
  });

  testWidgets('multiple excluded anchors are all named and all removable', (tester) async {
    const second = AnchorLocation(id: 'a3', label: 'Carver\'s Gap', point: [-105.12, 40.18]);
    List<AnchorLocation>? removed;
    final shrunk = _original.copyWith(maxLon: -105.15, maxLat: 40.15);
    await tester.pumpWidget(_harness(
      proposed: shrunk,
      anchors: const [_excludedAnchor, second],
      onApply: (_) {},
      onRemoveAnchors: (a) => removed = a,
    ));
    await tester.tap(find.text('revise'));
    await tester.pump();

    expect(find.text('2 anchors would fall outside'), findsOneWidget);
    expect(find.text(_excludedAnchor.label), findsOneWidget);
    expect(find.text(second.label), findsOneWidget);

    await tester.tap(find.text('Remove these 2 anchors'));
    await tester.pumpAndSettle();

    expect(removed, [_excludedAnchor, second]);
  });
}
