/// FR140/FR140a (Story Q3) — the stale list: derived work (routes, cue
/// sheets, metrics, elevation) an edit has invalidated, surfaced on its own
/// (never through M13's shared error surface, FR140a) rather than
/// recomputed or prompted about at edit time. `SolveProvenance.stale`
/// (ARCH D30) is the one flag this reads; nothing new is stored, per FR140's
/// "reusing solve.stale — no new mechanism."
library;

import 'trip.dart';

/// One stale item in the list: a segment naming what it is and which day
/// it's on, per Q3's AC — "each item named by what it is and which day
/// it's on."
class StaleItem {
  const StaleItem({
    required this.dayId,
    required this.dayIndex,
    required this.segmentId,
    required this.mode,
    required this.shape,
  });

  final String dayId;
  final int dayIndex;
  final String segmentId;
  final String mode;
  final String shape;

  /// e.g. "Day 3 — cycling loop", the stale list's row label.
  String get label => 'Day $dayIndex — $mode ${shape.replaceAll('_', ' ')}';
}

/// Every currently-stale segment in [trip], across every day, in day order —
/// the stale list's contents (Q3's AC, FR140a).
List<StaleItem> tripStaleItems(Trip trip) => [
      for (final day in trip.days)
        for (final s in day.segments)
          if (s.solve?.stale ?? false)
            StaleItem(
              dayId: day.id,
              dayIndex: day.index,
              segmentId: s.id,
              mode: s.mode,
              shape: s.shape,
            ),
    ];

/// Q3's AC: "while planning this is passive only — a marker on the object
/// and a count in the dashboard" — this is that count.
int tripStaleCount(Trip trip) => tripStaleItems(trip).length;

/// Q3's AC: "a stale route stays viewable but is not exportable or
/// printable" — export and print both gate on this before proceeding;
/// whichever finds it false opens the stale list instead of erroring.
bool tripReadyToExport(Trip trip) => tripStaleItems(trip).isEmpty;
