/// FR139 (Story Q1/Q2) — the "what would be affected and how much" scope
/// description a removal or reduction must show before it proceeds, and the
/// shared vocabulary (keep / adjust / merge-into-adjacent / remove
/// explicitly) FR139 uses across every case it names. One generalized
/// mechanism per FR139's own framing ("one rule rather than five"), not a
/// bespoke prompt per object type — `trip_bbox_shrink_prompt.dart`'s
/// three-choice shape (FR120) is the shape this generalizes to a fourth
/// choice (merge-into-adjacent) for the day-count case.
library;

import 'day.dart';
import 'node.dart';
import 'segment.dart';

/// What a day (or a run of days) holds, for the prompt FR139 requires before
/// a day-count reduction removes anything: *"day 5 and day 6 hold 4
/// passages, 7 anchors, and 2 scheduled events."* [anchors] counts day- and
/// segment-scoped [Node]s the same way `tripAnchorsProvider` already does
/// (the pre-Anchor-model authored places story O1 hasn't migrated onto it
/// yet), minus whichever of those carry a [Node.scheduled] window — those
/// are counted as [scheduledEvents] instead so the three figures never
/// double-count the same node.
class DayContentSummary {
  const DayContentSummary({this.passages = 0, this.anchors = 0, this.scheduledEvents = 0});

  static const zero = DayContentSummary();

  final int passages;
  final int anchors;
  final int scheduledEvents;

  /// FR139's carve-out: "empty days are removed without a prompt."
  bool get isEmpty => passages == 0 && anchors == 0 && scheduledEvents == 0;

  DayContentSummary operator +(DayContentSummary other) => DayContentSummary(
        passages: passages + other.passages,
        anchors: anchors + other.anchors,
        scheduledEvents: scheduledEvents + other.scheduledEvents,
      );
}

DayContentSummary summarizeDayContent(Day day) {
  final nodes = [...day.nodes, for (final s in day.segments) ...s.nodes];
  final scheduled = nodes.where((n) => n.scheduled != null).length;
  return DayContentSummary(
    passages: day.segments.length,
    anchors: nodes.length - scheduled,
    scheduledEvents: scheduled,
  );
}

DayContentSummary summarizeDaysContent(Iterable<Day> days) =>
    days.map(summarizeDayContent).fold(DayContentSummary.zero, (a, b) => a + b);

/// Which of [days] a reduction to [targetCount] days would remove — the
/// highest-indexed ones, the "fewer days" shape a day-count control implies.
/// Returned sorted by [Day.index] ascending, the order the prompt should
/// name them in. Empty when [targetCount] would not actually remove any day.
List<Day> daysBeyondCount(List<Day> days, int targetCount) {
  if (targetCount < 0) throw ArgumentError.value(targetCount, 'targetCount', 'must not be negative');
  if (targetCount >= days.length) return const [];
  final sorted = [...days]..sort((a, b) => a.index.compareTo(b.index));
  return sorted.sublist(targetCount);
}

/// FR139 — what removing [segment] would carry away with it: whether it
/// holds any authored content at all (nodes, hazards, an arc stage), and
/// specifically any transition node carrying Author instructions (FR12/B3's
/// parking/gear-stash/put-in notes) so the prompt can name those by what
/// they are, per Q2's AC.
class SegmentContentSummary {
  const SegmentContentSummary({
    this.nodeCount = 0,
    this.hazardCount = 0,
    this.hasArcStage = false,
    this.instructedTransitionNodes = const [],
  });

  final int nodeCount;
  final int hazardCount;
  final bool hasArcStage;
  final List<Node> instructedTransitionNodes;

  /// FR139: "the prompt is triggered by authored content, not by object
  /// type" — a segment with none of this is a mis-click, tidied without
  /// friction (Q2's AC).
  bool get hasAuthoredContent =>
      nodeCount > 0 || hazardCount > 0 || hasArcStage || instructedTransitionNodes.isNotEmpty;
}

SegmentContentSummary summarizeSegmentContent(Segment segment) => SegmentContentSummary(
      nodeCount: segment.nodes.length,
      hazardCount: segment.hazards.length,
      hasArcStage: segment.arcStage != null,
      instructedTransitionNodes: [
        for (final n in segment.nodes)
          if (n.kind == NodeKind.transition && n.instructions != null) n,
      ],
    );
