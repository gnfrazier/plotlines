/// FR140/FR140a (Story Q3) — the stale list: derived work (routes, cue
/// sheets, metrics, elevation) an edit has invalidated, surfaced on its own
/// (never through M13's shared error surface, FR140a) rather than
/// recomputed or prompted about at edit time. `SolveProvenance.stale`
/// (ARCH D30) is the one flag this reads; nothing new is stored, per FR140's
/// "reusing solve.stale — no new mechanism."
///
/// Two kinds of thing can be stale (issue #344). A **passage** goes stale when
/// an authored input it was solved from changes — a via-node, a weight, a
/// target distance. An **alternate** goes stale when the Author moves where it
/// forks from or rejoins the passage: its own `geometry`/`metrics`/`elevation`
/// then describe a path that has moved, while the passage's describe exactly
/// the route they were solved for. Both are `solve.stale` on the object that
/// owns the invalidated numbers, which is why the alternate needed a `solve` of
/// its own rather than a flag borrowed from its parent.
library;

import 'trip.dart';

/// One stale item in the list: named by what it is and which day it's on, per
/// Q3's AC — "each item named by what it is and which day it's on."
class StaleItem {
  const StaleItem({
    required this.dayId,
    required this.dayIndex,
    required this.segmentId,
    required this.mode,
    required this.shape,
    this.alternateId,
    this.alternateLabel,
    this.alternateIsBranch = false,
  });

  final String dayId;
  final int dayIndex;

  /// The passage this item is, or — when [alternateId] is set — the passage the
  /// stale alternate hangs off. Either way it is what a re-solve needs to find
  /// the object again.
  final String segmentId;
  final String mode;
  final String shape;

  /// Set when the stale thing is an alternate *on* [segmentId] rather than the
  /// passage itself. The passage is untouched in that case and must not be
  /// re-solved with it — an edit to a branch is not an edit to the day.
  final String? alternateId;

  /// The alternate's own name, so the row says which branch moved rather than
  /// only which day it was on. Null for an alternate the Author never named.
  final String? alternateLabel;

  /// Whether that alternate is a branch (a story choice carrying its own
  /// content) rather than an accommodation (an effort option). It changes what
  /// dropping the item would destroy, so the list has to know.
  final bool alternateIsBranch;

  /// True when this item is an alternate rather than the passage itself.
  bool get isAlternate => alternateId != null;

  /// e.g. "Day 3 — cycling loop", or "Day 3 — branch “Past the mine” on the
  /// cycling loop", the stale list's row label.
  String get label {
    final passage = 'Day $dayIndex — $mode ${shape.replaceAll('_', ' ')}';
    if (!isAlternate) return passage;
    final kind = alternateIsBranch ? 'branch' : 'alternate';
    final named = alternateLabel == null ? kind : '$kind “$alternateLabel”';
    return 'Day $dayIndex — $named on the $mode ${shape.replaceAll('_', ' ')}';
  }
}

/// Every currently-stale item in [trip], across every day, in day order — the
/// stale list's contents (Q3's AC, FR140a). A passage comes before its own
/// alternates, which is the order they were authored in and the order a
/// re-solve-all should walk: re-solving the day's line first means an
/// alternate's re-solve measures against the route it will actually hang off.
///
/// An object with no `solve` at all is never stale. For a passage that means
/// never solved; for an alternate it means an Author-drawn line whose distances
/// are measured off the line itself and say so — there is no derived work to
/// invalidate, so moving it owes no re-solve and must not block an export.
List<StaleItem> tripStaleItems(Trip trip) => [
      for (final day in trip.days)
        for (final s in day.segments) ...[
          if (s.solve?.stale ?? false)
            StaleItem(
              dayId: day.id,
              dayIndex: day.index,
              segmentId: s.id,
              mode: s.mode,
              shape: s.shape,
            ),
          for (final a in s.alternates)
            if (a.solve?.stale ?? false)
              StaleItem(
                dayId: day.id,
                dayIndex: day.index,
                segmentId: s.id,
                mode: s.mode,
                shape: s.shape,
                alternateId: a.id,
                alternateLabel: a.label,
                alternateIsBranch: a.isBranch,
              ),
        ],
    ];

/// Q3's AC: "while planning this is passive only — a marker on the object
/// and a count in the dashboard" — this is that count.
int tripStaleCount(Trip trip) => tripStaleItems(trip).length;

/// Q3's AC: "a stale route stays viewable but is not exportable or
/// printable" — export and print both gate on this before proceeding;
/// whichever finds it false opens the stale list instead of erroring.
bool tripReadyToExport(Trip trip) => tripStaleItems(trip).isEmpty;
