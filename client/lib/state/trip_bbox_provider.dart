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

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/sidecar_manager.dart' show CapabilityStatus;
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

/// Issue #246 (OSM acquisition Phase 0, review §5.5 · addendum P3) — how long
/// the accepted bbox must hold still before a `/regions` POST goes out.
///
/// The settle window lives on the **accepted-bbox → `ensureRegion` edge**,
/// not on pointer events (the map already proposes only on pointer-up —
/// `trip_area_map.dart` `_onPointerUp` / `_onCornerPointerUp` — so there is
/// nothing mid-drag to debounce). #238 measured five *completed* corner-drag
/// gestures accepted in ~30 s (07:39:59 → 07:40:29), each one POSTing
/// `/regions` immediately and each POST fanning into one Overpass query per
/// sub-polygon above `max_query_area_size`. Ten seconds comfortably spans
/// that burst's inter-gesture gaps (~6–8 s) so a flurry of refinements
/// collapses to a single build for the box the Author actually settled on,
/// and it is a small fraction of the 37–117 s graph build that follows — a
/// wait the FR121 surface names honestly ("waiting for the trip area to
/// settle") rather than hiding.
const tripRegionSettleWindow = Duration(seconds: 10);

/// The lifecycle of the trip bbox's routing region, as the FR121 capability
/// surface needs to see it. A plain `AsyncValue<String?>` cannot say
/// "waiting for the accepted bbox to stop changing" — a real, on-screen wait
/// (issue #246) that is neither a failure nor a POST in flight yet — so the
/// states are named explicitly.
sealed class TripRegionKeyState {
  const TripRegionKeyState();
}

/// No bbox drawn yet — routing has nothing to prepare a region for.
class TripRegionNoBbox extends TripRegionKeyState {
  const TripRegionNoBbox();
}

/// A bbox is accepted but still being revised; the settle window is running.
/// No `/regions` POST has been sent. [pending] is the box that will be
/// ensured once it holds still for [tripRegionSettleWindow].
class TripRegionSettling extends TripRegionKeyState {
  const TripRegionSettling(this.pending);
  final TripBbox pending;
}

/// The settled bbox's `POST /regions` is in flight.
class TripRegionEnsuring extends TripRegionKeyState {
  const TripRegionEnsuring(this.bbox);
  final TripBbox bbox;
}

/// `/regions` returned a region key for the settled bbox. Screens gate
/// routing controls on `sidecarManagerProvider`'s
/// `capabilities.routing.forRegion(key)` using this key.
class TripRegionResolved extends TripRegionKeyState {
  const TripRegionResolved(this.key);
  final String key;
}

/// `/regions` could not be reached or errored for the settled bbox. The
/// error is carried for logging only — never rendered (issue #230 B3).
class TripRegionFailed extends TripRegionKeyState {
  const TripRegionFailed(this.error);
  final Object error;
}

/// FR120/D41 (issue #154), settle window + supersede-in-flight (issue #246) —
/// owns the trip bbox's routable-graph region: waits for the accepted bbox to
/// stop changing, then POSTs `/regions` once for the box the Author settled
/// on, and drops any region whose bbox was superseded before its build could
/// be observed.
///
/// Issue #208 — the graph is per travel mode (`network_type`). This warms
/// **only** the `bike` region: it is the stable gate/warm-up anchor every
/// existing caller expects, and the one graph an Author is guaranteed to
/// need. The other declared modes' graphs (`walk`, `drive`, `all`) are each
/// a full-region OSMnx build in their own right — fanning all of them out
/// here, the moment a bbox is accepted, put three-plus county-scale builds
/// on the sidecar at once. That saturated it badly enough that `/health`
/// timed out, M12 restarted it mid-build, and the restart re-triggered the
/// same fan-out (see the Buncombe County incident). The per-segment
/// solve/cue/diagnose paths (`current_trip_provider`, `weights_rail`)
/// already `ensureRegion` for their own mode's `network_type` on demand, so
/// a `walk`/`drive` graph is still built before anything routes against it —
/// just when a segment of that mode actually exists, not speculatively.
class TripRegionKeyNotifier extends StateNotifier<TripRegionKeyState> {
  TripRegionKeyNotifier(this._ref, {Duration? settleWindow})
      : _settleWindow = settleWindow ?? tripRegionSettleWindow,
        super(const TripRegionNoBbox()) {
    _ref.listen<TripBbox?>(
      tripBboxProvider,
      (_, next) => _onBboxAccepted(next),
      fireImmediately: true,
    );
  }

  final Ref _ref;
  final Duration _settleWindow;

  Timer? _settleTimer;

  /// Bumped on every accepted bbox and every [retry]. Any settle-timer
  /// callback or in-flight `ensureRegion` whose generation is stale by the
  /// time it resumes is a superseded region and is dropped — it never
  /// reaches [state].
  int _generation = 0;

  /// The last bbox accepted from [tripBboxProvider]; the box [retry] re-POSTs.
  TripBbox? _lastAccepted;

  void _onBboxAccepted(TripBbox? bbox) {
    // Re-setting the identical box (an idempotent re-watch, a screen
    // remount) is not a revision and must not restart the settle clock.
    if (bbox == _lastAccepted) return;
    _lastAccepted = bbox;
    _settleTimer?.cancel();
    final generation = ++_generation;

    if (bbox == null) {
      state = const TripRegionNoBbox();
      return;
    }

    state = TripRegionSettling(bbox);
    _settleTimer = Timer(_settleWindow, () => _ensure(generation, bbox));
  }

  Future<void> _ensure(int generation, TripBbox bbox, {bool manual = false}) async {
    if (generation != _generation) return; // superseded during the settle window
    state = TripRegionEnsuring(bbox);
    try {
      final client = _ref.read(routingClientProvider);
      // `manual` is the Author's explicit "Try again" (issue #247) — the only
      // path that may re-queue a settled-failed build inside the sidecar's
      // post-failure cooldown. The settle-window path leaves it false.
      final key = await client.ensureRegion(bbox.bboxWsen, retry: manual);
      // A stale generation is a superseded region; `!mounted` is the screen
      // torn down mid-POST. Either way the result is dropped.
      if (!mounted || generation != _generation) return;
      state = TripRegionResolved(key);
    } catch (e) {
      if (!mounted || generation != _generation) return;
      state = TripRegionFailed(e);
    }
  }

  /// FR121 "Try again" (issue #229) — re-POST `/regions` for the current
  /// settled bbox without the Author redrawing the trip area. The sidecar
  /// resets a settled-failed region and re-queues its build. No-op with no
  /// bbox; skips straight past the settle window since the Author is asking
  /// to build the box as it stands now.
  ///
  /// Sent as `retry: true` (issue #247), which is what lets it re-queue inside
  /// the sidecar's post-failure cooldown — once per cooldown window; a second
  /// press before the window elapses is refused with the remaining wait shown
  /// on the routing capability, not silently swallowed.
  void retry() {
    final bbox = _lastAccepted;
    if (bbox == null) return;
    _settleTimer?.cancel();
    _ensure(++_generation, bbox, manual: true);
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    super.dispose();
  }
}

/// FR120/D41 (issue #154) — the trip bbox's routing region, settle-windowed
/// (issue #246) so a burst of bbox revisions produces one `/regions` POST for
/// the box the Author settled on rather than one per accepted revision.
final tripRegionKeyProvider =
    StateNotifierProvider<TripRegionKeyNotifier, TripRegionKeyState>(
  (ref) => TripRegionKeyNotifier(ref),
);

/// Maps a [TripRegionKeyState] onto the FR121 [CapabilityStatus] a routing
/// control shows while it is disabled. [sidecarRegionStatus] is the sidecar's
/// own per-region `/health` entry (`capabilities.routing.forRegion(key)`),
/// which only exists once the key has resolved.
///
/// Pure and exported so each phase's reading is directly testable — in
/// particular that the settle window (issue #246) reads as an honest wait:
/// `CapabilityStatus.failed` stays false for [TripRegionSettling] (a non-null
/// `progress` sees to that), so the FR121 surface shows the quiet one-line
/// warming notice, never the failure card and never nothing at all.
CapabilityStatus routingCapabilityForRegion(
  TripRegionKeyState region,
  CapabilityStatus? sidecarRegionStatus,
) {
  switch (region) {
    case TripRegionNoBbox():
      return const CapabilityStatus(
        ready: false,
        reason: 'draw the trip area before routing is available',
      );
    case TripRegionSettling():
      return const CapabilityStatus(
        ready: false,
        reason: 'waiting for the trip area to settle',
        progress: 0,
      );
    case TripRegionEnsuring():
      return const CapabilityStatus(
        ready: false,
        reason: 'ensuring the routing region',
      );
    case TripRegionResolved():
      return sidecarRegionStatus ??
          const CapabilityStatus(ready: false, reason: 'ensuring the routing region');
    case TripRegionFailed():
      return const CapabilityStatus(
        ready: false,
        reason: 'failed:the trip area could not be prepared for routing',
      );
  }
}

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
