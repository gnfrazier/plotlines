/// FR12 / B3 — a day read as a Character reads it: passages and the mode
/// changes between them, in order, each mode change carrying the Author's
/// instructions for it.
///
/// A `Transition` is a first-class member of the day, not a node on either
/// passage, "because it belongs to neither" (`transition.dart`, ARCH §6.1).
/// That is structurally right and it has one consequence this file exists to
/// fix: nothing that walks a day's *passages* will ever see it. The Export
/// tab's cue preview concatenated per-passage cue sheets and skipped straight
/// over every junction between them; a Character reading that sheet was never
/// told to get off the bike.
///
/// [dayTimeline] is the ordered reading the Character surfaces share — the cue
/// preview today, H3's timeline and print when they are built — so the rule for
/// *where* a mode change sits in a day is written once. Distances are cumulative
/// across the day's passages, which is the frame every one of those surfaces
/// already uses.
///
/// **Reveal (FR114–FR116, O5) does not gate any of this.** Transition
/// instructions are provision content in the PRD's sense — where to park, where
/// to stash the bikes, where to put in — and provision is always visible. They
/// live on `Node.instructions`, not on a `Role`, so the reveal resolver has no
/// opinion to express and the M14 lint's ban on Presentation reading
/// `Role.title`/`note`/`media` is not in play. A Character who cannot read the
/// put-in instruction until they arrive at the put-in is standing on a riverbank
/// holding a boat.
library;

import 'day.dart';
import 'json_utils.dart';
import 'passage_sequence.dart';
import 'segment.dart';
import 'transition.dart';

/// One entry in a day's Character-facing reading. Sealed: a day is passages
/// and the joins between them, and a surface that renders it must handle both.
sealed class DayTimelineEntry {
  const DayTimelineEntry({required this.distanceAlongDayM});

  /// Metres from the start of the day. `null` when the day has no measured
  /// distance yet (an unsolved passage) — absence is stated, never rendered
  /// as zero.
  final double? distanceAlongDayM;
}

/// A passage, at the point in the day where it begins.
class PassageEntry extends DayTimelineEntry {
  const PassageEntry({
    required this.passage,
    required this.position,
    required super.distanceAlongDayM,
  });

  final Segment passage;

  /// 0-based place in the day.
  final int position;

  String get mode => passage.mode;
}

/// The junction between two passages — FR12's transition, at the distance the
/// preceding passage ends.
class ModeChangeEntry extends DayTimelineEntry {
  const ModeChangeEntry({
    required this.transition,
    required super.distanceAlongDayM,
  });

  final Transition transition;

  String? get fromMode => transition.fromMode;
  String? get toMode => transition.toMode;

  /// FR12 — the Author's parking / gear-stash / put-in instructions.
  String? get instructions => transition.instructions;

  /// Where the Author placed the transition node, if they placed one.
  Coord? get coord => transition.node?.coord;

  /// True when the two passages are actually different modes. A junction
  /// between two rides is still a junction — it can carry instructions and a
  /// gap — but it is not a mode change, and a surface that says "mode change"
  /// about it is lying.
  bool get isModeChange => transition.isModeChange;

  /// B2's adjacency warning, carried through so a Character surface can say
  /// the two legs do not meet without re-measuring.
  bool get gapWarning => transition.gapWarning ?? false;
  double? get gapM => transition.gapM;

  /// Whether an Author has placed a node here at all. A junction with no node
  /// is still on the timeline — the mode change happens whether or not anyone
  /// wrote about it — it simply has nothing to say.
  bool get hasNode => transition.node != null;
}

/// [day] as an ordered sequence of passages and the junctions between them.
///
/// A rest day, or a day with no passages, has an empty timeline: there is no
/// sequence to read.
List<DayTimelineEntry> dayTimeline(Day day) {
  final entries = <DayTimelineEntry>[];
  var cumulativeM = 0.0;
  var measured = true;

  for (var i = 0; i < day.segments.length; i++) {
    if (i > 0) {
      final transition = transitionBefore(day, i);
      if (transition != null) {
        entries.add(ModeChangeEntry(
          transition: transition,
          distanceAlongDayM: measured ? cumulativeM : null,
        ));
      }
    }
    entries.add(PassageEntry(
      passage: day.segments[i],
      position: i,
      distanceAlongDayM: measured ? cumulativeM : null,
    ));
    final distanceM = day.segments[i].metrics?.distanceM;
    // One unsolved passage makes every distance after it a guess, so the
    // timeline stops claiming them rather than reporting a running total that
    // silently omits a leg.
    if (distanceM == null) {
      measured = false;
    } else {
      cumulativeM += distanceM;
    }
  }
  return entries;
}

/// Only the mode changes, in order — what a surface showing "where do I switch
/// activities today" needs, without walking the passages.
List<ModeChangeEntry> dayModeChanges(Day day) =>
    [for (final e in dayTimeline(day)) if (e is ModeChangeEntry) e];

/// Every junction in [day] carrying Author instructions. FR12's payload, and
/// the set a gear list or a day briefing would read.
List<ModeChangeEntry> instructedModeChanges(Day day) =>
    [for (final e in dayModeChanges(day)) if (e.instructions != null) e];

/// Where a transition node belongs when an Author places one at the junction
/// before the passage at [index] and has not picked a point on the map.
///
/// The preceding passage's end, not the midpoint of the gap: the transition is
/// the moment a Character finishes one leg, and where they finish it is where
/// they are standing when they read the instruction. Falls back to the next
/// passage's start, then to `null` when neither passage has a position yet.
Coord? defaultTransitionCoord(Day day, int index) {
  if (index <= 0 || index >= day.segments.length) return null;
  return passageEnd(day.segments[index - 1]) ?? passageStart(day.segments[index]);
}
