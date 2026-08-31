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

import '../domain/travel_mode.dart';
import '../domain/trip_bbox.dart';
import '../domain/trip_bbox_revision.dart';
import 'current_trip_provider.dart';
import 'providers.dart';

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

/// FR120/D41, issue #154 — the region key for the trip's own bbox, ensuring
/// a routable graph exists for exactly that area rather than routing
/// silently against whatever region happened to be loaded. Recomputes (and
/// re-POSTs `/regions`, idempotently and cheaply — a dict lookup
/// server-side once already built) whenever [tripBboxProvider] changes; null
/// before any bbox has been drawn. Screens gate routing controls on
/// `sidecarManagerProvider`'s `capabilities.routing.forRegion(key)` using
/// the key this resolves to, per FR121's disabled-with-a-reason house style.
///
/// Issue #208 — the graph is per travel mode (`network_type`), so this also
/// kicks off a build for every *declared* mode's `network_type` (a hiking
/// trip's `walk` graph, a driving leg's `drive` graph) rather than only
/// `bike`. The returned key is still the `bike` region — it is the stable
/// gate/warm-up anchor every existing caller expects — and the per-segment
/// solve/cue/diagnose calls each ensure their own mode's region regardless.
final tripRegionKeyProvider = FutureProvider<String?>((ref) async {
  final bbox = ref.watch(tripBboxProvider);
  if (bbox == null) return null;
  final client = ref.watch(routingClientProvider);
  final declaredModes = ref.watch(currentTripProvider).declaredModes;
  final networkTypes = {
    'bike',
    for (final mode in declaredModes)
      if (isRoutedMode(mode)) networkTypeForMode(mode),
  };
  final keys = <String, String>{};
  for (final networkType in networkTypes) {
    keys[networkType] =
        await client.ensureRegion(bbox.bboxWsen, networkType: networkType);
  }
  return keys['bike'];
});

/// Anchors currently promoted into the open trip, which a bbox shrink must
/// never silently drop. Two sources feed this, both counted: `layers_tab
/// .dart`'s candidate-to-`Node` promotion (`current_trip_provider.dart`'s
/// `promoteCandidate` — pre-dates the Anchor/role model and hasn't been
/// migrated onto it, see that method's doc comment) and `trip.anchors`
/// proper, the FR106/FR110 (Story O1) model. Every node counts here, not
/// just promoted ones, since a hand-placed POI is exactly as authored as a
/// promoted candidate and a bbox shrink must protect both.
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
    for (final anchor in trip.anchors) ...[
      AnchorLocation(id: anchor.id, label: anchor.title ?? anchor.roles.first.kind.wireValue, point: anchor.coord),
      // FR107 (O2) — a role's own offset is exactly as authored as the
      // anchor it sits on (the overlook 400 m up the spur, not the parking
      // lot); a bbox shrink must protect it too, or it silently drops the
      // one thing O2 exists to place correctly.
      for (final role in anchor.roles)
        if (role.coord != null)
          AnchorLocation(id: '${anchor.id}:${role.id}', label: anchor.title ?? role.kind.wireValue, point: role.coord!),
    ],
  ];
});
