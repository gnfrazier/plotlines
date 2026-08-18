// Ephemeral UI-only state — not part of the trip payload, so it lives
// outside domain/ entirely. Just enough for the planner to hand the New
// Route flow a target day without routing path params.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/domain.dart';

/// Set before navigating to `/new` when adding a segment to an existing
/// day; null means "start a new day". Read once by NewRouteScreen and reset.
final plannerTargetDayIdProvider = StateProvider<String?>((ref) => null);

/// Which segment is focused on the planner's map/metrics pane.
final selectedSegmentProvider = StateProvider<(String dayId, String segmentId)?>((ref) => null);

/// Resolves [selectedSegmentProvider]'s `(dayId, segmentId)` tuple against a
/// [Trip] — shared by the Route and Content tabs (`plan_tabs/route_tab.dart`,
/// `plan_tabs/content_tab.dart`) so there's exactly one lookup to keep
/// correct, not two hand-rolled scans that can silently drift.
(Day, Segment)? resolveSelectedSegment(Trip trip, (String, String)? selected) {
  if (selected == null) return null;
  for (final d in trip.days) {
    if (d.id != selected.$1) continue;
    for (final s in d.segments) {
      if (s.id == selected.$2) return (d, s);
    }
  }
  return null;
}
