// N1 (PRD FR120) — the trip's authoring bbox: drawn at trip initiation,
// revisable throughout authoring.
//
// **Session-only, not yet persisted** — the same accepted limitation
// `trip_authoring_meta_provider.dart` documents for party size/primary
// modes, and for the same reason: there is no schema home for it yet.
// `docs/Plotlines_ARCHITECTURE_v2.md` (§11.6, D41) is explicit that adding
// the trip bbox to `trip_payload.schema.json` is "a schema version bump
// with a migration, not an additive edit" bundled with anchors/roles/
// polygons/arc-on-passages — none of which exist in this codebase yet.
// Reopening a saved trip starts bbox selection over, same as party size.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/trip_bbox.dart';
import '../domain/trip_bbox_revision.dart';
import 'current_trip_provider.dart';

class TripBboxNotifier extends StateNotifier<TripBbox?> {
  TripBboxNotifier() : super(null);

  void reset() => state = null;

  /// Sets the bbox to an already-resolved value — the initial draw, an
  /// enlargement, or a shrink the Author has confirmed via the shrink
  /// prompt (`presentation/widgets/trip_bbox_shrink_prompt.dart`). Callers
  /// are expected to have run the revision through that prompt first when
  /// anchors could fall outside; this notifier does not re-check.
  void set(TripBbox bbox) => state = bbox;
}

final tripBboxProvider =
    StateNotifierProvider<TripBboxNotifier, TripBbox?>((ref) => TripBboxNotifier());

/// Anchors currently promoted into the open trip, which a bbox shrink must
/// never silently drop. Epic N (Story N3, FR99) is the first thing that
/// promotes anything: a promoted candidate becomes a day- or segment-scoped
/// `Node` (see `current_trip_provider.dart`'s `promoteCandidate`, and its
/// doc comment on why that's a `Node` rather than a real `Anchor` type —
/// ARCH B3's anchor/role migration hasn't landed yet). Every node counts
/// here, not just promoted ones, since a hand-placed POI is exactly as
/// authored as a promoted candidate and a bbox shrink must protect both.
final tripAnchorsProvider = Provider<List<AnchorLocation>>((ref) {
  final trip = ref.watch(currentTripProvider);
  return [
    for (final day in trip.days) ...[
      for (final node in day.nodes)
        AnchorLocation(id: node.id, label: node.title ?? node.kind.wireValue, point: node.coord),
      for (final segment in day.segments)
        for (final node in segment.nodes)
          AnchorLocation(id: node.id, label: node.title ?? node.kind.wireValue, point: node.coord),
    ],
  ];
});
