// FR139/FR140 (Story Q2) — the "may I remove this" gate before authored
// content disappears.
//
// #235 B5. `passage_removal_prompt.dart` shipped at 0% coverage while being
// reachable from `weights_rail.dart:490`. It is a destructive-action gate on
// authored content, so "the dialog renders and the buttons return the right
// answer" is worth pinning: a `Keep` that returns true, or a barrier dismiss
// that returns true, removes a passage the Author was trying to save.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/domain/domain.dart';
import 'package:plotlines_client/presentation/widgets/passage_removal_prompt.dart';

Node _transition({String? instructions}) => Node(
      id: 'n-t',
      kind: NodeKind.transition,
      coord: const [-105.27, 40.02],
      instructions: instructions,
    );

Node _poi() => Node(
      id: 'n-p',
      kind: NodeKind.poi,
      coord: const [-105.26, 40.02],
      title: 'Overlook',
    );

Segment _segment({
  List<Node> nodes = const [],
  List<Hazard> hazards = const [],
  String? arcStage,
}) =>
    Segment(
      id: 's1',
      mode: 'cycling',
      shape: 'loop',
      start: const [-105.27, 40.02],
      nodes: nodes,
      hazards: hazards,
      arcStage: arcStage,
    );

/// Holds the Author's answer once the dialog closes.
///
/// A plain `Future<bool?>` return would deadlock: awaiting `_open` would await
/// the dialog's own future, which cannot complete until a button is tapped —
/// which the awaiting test never gets to do.
class _Answer {
  bool? value;
  bool settled = false;
}

/// Pumps the prompt over a trivial host and returns the holder its answer
/// lands in.
Future<_Answer> _open(WidgetTester tester, SegmentContentSummary summary) async {
  final answer = _Answer();
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            answer.value = await showPassageRemovalPrompt(context, summary: summary);
            answer.settled = true;
          },
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return answer;
}

void main() {
  group('what counts as authored content', () {
    // FR139: "the prompt is triggered by authored content, not by object
    // type". The caller reads `hasAuthoredContent` to decide whether to
    // prompt at all, so the summary is half of this gate.
    test('a bare passage is a mis-click, tidied without friction', () {
      expect(summarizeSegmentContent(_segment()).hasAuthoredContent, isFalse);
    });

    test('a node, a hazard or an arc stage each make it authored', () {
      expect(summarizeSegmentContent(_segment(nodes: [_poi()])).hasAuthoredContent,
          isTrue);
      expect(
          summarizeSegmentContent(_segment(hazards: [
            Hazard(id: 'h1', severity: 'high', title: 'Weir'),
          ])).hasAuthoredContent,
          isTrue);
      expect(
          summarizeSegmentContent(_segment(arcStage: 'rising')).hasAuthoredContent,
          isTrue);
    });

    test('only transition nodes carrying instructions are named separately', () {
      final summary = summarizeSegmentContent(_segment(nodes: [
        _poi(),
        _transition(), // a transition with nothing written on it
        _transition(instructions: 'Stash the bikes behind the outhouse.'),
      ]));

      expect(summary.nodeCount, 3);
      expect(summary.instructedTransitionNodes, hasLength(1));
      expect(summary.instructedTransitionNodes.single.instructions,
          'Stash the bikes behind the outhouse.');
    });
  });

  group('the prompt', () {
    testWidgets('names what the passage carries', (tester) async {
      await _open(
          tester,
          summarizeSegmentContent(_segment(nodes: [_poi()], hazards: [
            Hazard(id: 'h1', severity: 'high', title: 'Weir'),
          ])));

      expect(find.text('Remove this passage?'), findsOneWidget);
      expect(find.textContaining('1 node'), findsOneWidget);
      expect(find.textContaining('1 hazard'), findsOneWidget);
    });

    testWidgets('counts read naturally in the plural', (tester) async {
      await _open(
          tester,
          summarizeSegmentContent(_segment(nodes: [_poi(), _transition()], hazards: [
            Hazard(id: 'h1', severity: 'high'),
            Hazard(id: 'h2', severity: 'caution'),
          ])));

      expect(find.textContaining('2 nodes'), findsOneWidget);
      expect(find.textContaining('2 hazards'), findsOneWidget);
    });

    testWidgets('says nothing about hazards when there are none', (tester) async {
      await _open(tester, summarizeSegmentContent(_segment(nodes: [_poi()])));

      expect(find.textContaining('hazard'), findsNothing);
    });

    testWidgets('promises the anchors survive, because they do', (tester) async {
      // `CurrentTripNotifier.removeSegment` moves the anchors onto the day
      // rather than deleting them. The dialog says so, and that sentence is
      // the difference between a confident Remove and an abandoned edit.
      await _open(tester, summarizeSegmentContent(_segment(nodes: [_poi()])));

      expect(find.textContaining('anchors survive unattached'), findsOneWidget);
    });

    testWidgets('quotes the transition instructions that would be lost',
        (tester) async {
      await _open(
          tester,
          summarizeSegmentContent(_segment(nodes: [
            _transition(instructions: 'Stash the bikes behind the outhouse.'),
          ])));

      expect(find.text('TRANSITION INSTRUCTIONS ON THIS PASSAGE'), findsOneWidget);
      expect(find.textContaining('Stash the bikes behind the outhouse.'),
          findsOneWidget);
    });

    testWidgets('omits the instructions block when there are none',
        (tester) async {
      await _open(tester, summarizeSegmentContent(_segment(nodes: [_poi()])));

      expect(find.text('TRANSITION INSTRUCTIONS ON THIS PASSAGE'), findsNothing);
    });

    testWidgets('lists every instructed transition, not just the first',
        (tester) async {
      await _open(
          tester,
          summarizeSegmentContent(_segment(nodes: [
            _transition(instructions: 'Put in below the bridge.'),
            Node(
              id: 'n-t2',
              kind: NodeKind.transition,
              coord: const [-105.25, 40.02],
              instructions: 'Take out at the gravel bar.',
            ),
          ])));

      expect(find.textContaining('Put in below the bridge.'), findsOneWidget);
      expect(find.textContaining('Take out at the gravel bar.'), findsOneWidget);
    });
  });

  group('the answer', () {
    testWidgets('Remove passage confirms', (tester) async {
      final answer =
          await _open(tester, summarizeSegmentContent(_segment(nodes: [_poi()])));

      await tester.tap(find.text('Remove passage'));
      await tester.pumpAndSettle();

      expect(answer.settled, isTrue);
      expect(answer.value, isTrue);
    });

    testWidgets('Keep declines', (tester) async {
      final answer =
          await _open(tester, summarizeSegmentContent(_segment(nodes: [_poi()])));

      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();

      expect(answer.value, isFalse);
    });

    testWidgets('dismissing the dialog is not a confirmation', (tester) async {
      // The caller treats null as "keep" (`confirmed ?? false`). Pinning it
      // here as well, because the failure mode — a dismissed dialog reading as
      // consent — is silent and destroys authored work.
      final answer =
          await _open(tester, summarizeSegmentContent(_segment(nodes: [_poi()])));

      Navigator.of(tester.element(find.text('Keep'))).pop();
      await tester.pumpAndSettle();

      expect(answer.settled, isTrue);
      expect(answer.value ?? false, isFalse);
    });
  });
}
