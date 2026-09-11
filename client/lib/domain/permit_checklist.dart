/// FR26 / C10 — "Characters get a pre-trip permit/pass checklist." The client
/// half of `plotlines_core.trips.permits` (`collect_permits` /
/// `permit_checklist`): the same one-traversal-plus-ordering rule, mirrored
/// here because the client assembles trips locally without round-tripping a
/// service call the way `hazard_rollup.dart` documents for C11. A drift
/// between the two is a bug in this file.
library;

import 'permit.dart';
import 'trip.dart';

/// Where a permit is pinned. `anchor` / `passage` when [Permit.anchorId] /
/// [Permit.segmentId] is set; `trip` covers an all-trip obligation pinned to
/// neither.
const List<String> permitScopes = ['trip', 'passage', 'anchor'];

/// FR26 — everything short of `confirmed` still needs attention before
/// departure. `denied` is included deliberately: a rejected permit is the
/// opposite of resolved.
const Set<String> needsAttentionPermitStatuses = {'required', 'applied', 'denied'};

/// The checklist's own worst-first order: `denied` (blocks the trip as
/// planned), then `required`, then `applied`, then `confirmed` last.
const List<String> _statusRank = ['denied', 'required', 'applied', 'confirmed'];

/// One permit on the trip, plus enough context to render or route to it —
/// `plotlines_core.trips.permits.LocatedPermit`.
class LocatedPermit {
  LocatedPermit({
    required this.permit,
    required this.scope,
    this.anchorTitle,
  });

  final Permit permit;

  /// One of [permitScopes].
  final String scope;

  /// Resolved against `Trip.anchors` when that anchor has one.
  final String? anchorTitle;

  /// FR26 — this permit still needs attention before departure.
  bool get needsAttention => needsAttentionPermitStatuses.contains(permit.status);
}

/// FR26 — the pre-trip checklist: every permit on the trip, ordered
/// worst-first (denied, then required, then applied, then confirmed), plus
/// the tally a Character-facing summary reads before showing the full list.
class PermitChecklist {
  const PermitChecklist({required this.permits});

  const PermitChecklist.empty() : permits = const [];

  final List<LocatedPermit> permits;

  int get needsAttentionCount => permits.where((lp) => lp.needsAttention).length;

  /// True when every permit on the trip is confirmed — also true when the
  /// trip carries none at all (nothing outstanding is nothing outstanding).
  /// A caller wanting "is there anything to show" should check [permits],
  /// not this.
  bool get isClear => needsAttentionCount == 0;

  /// `plotlines_core.trips.permits.collect_permits` / `permit_checklist`,
  /// mirrored over a trip assembled locally.
  factory PermitChecklist.fromTrip(Trip trip) {
    final anchorTitles = <String, String>{
      for (final a in trip.anchors)
        if (a.title != null) a.id: a.title!,
    };

    LocatedPermit locate(Permit p) {
      final scope = p.anchorId != null
          ? 'anchor'
          : (p.segmentId != null ? 'passage' : 'trip');
      return LocatedPermit(
        permit: p,
        scope: scope,
        anchorTitle: p.anchorId == null ? null : anchorTitles[p.anchorId],
      );
    }

    final located = trip.permits.map(locate).toList()
      ..sort((a, b) {
        var c = _statusRank.indexOf(a.permit.status).compareTo(_statusRank.indexOf(b.permit.status));
        if (c != 0) return c;
        c = a.permit.title.toLowerCase().compareTo(b.permit.title.toLowerCase());
        if (c != 0) return c;
        return a.permit.id.compareTo(b.permit.id);
      });
    return PermitChecklist(permits: located);
  }
}
