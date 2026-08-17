// Ephemeral UI-only state — not part of the trip payload, so it lives
// outside domain/ entirely. Just enough for the planner to hand the New
// Route flow a target day without routing path params.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Set before navigating to `/new` when adding a segment to an existing
/// day; null means "start a new day". Read once by NewRouteScreen and reset.
final plannerTargetDayIdProvider = StateProvider<String?>((ref) => null);

/// Which segment is focused on the planner's map/metrics pane.
final selectedSegmentProvider = StateProvider<(String dayId, String segmentId)?>((ref) => null);
