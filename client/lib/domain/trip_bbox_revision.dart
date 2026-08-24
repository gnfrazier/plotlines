// N1 (PRD FR120) / Author Flows MVP Flow 9 — "shrinking prompts with the
// promoted anchors that would fall outside... never silently discards
// authored work." [AnchorLocation] is a minimal stand-in for a promoted
// Anchor: Epic N's candidate/promotion pipeline (PRD §5, ARCH D36) isn't
// built in this codebase yet, so nothing currently produces one. The check
// below is real and unit-tested; today it just always finds zero anchors to
// protect (see `state/trip_bbox_provider.dart`'s `tripAnchorsProvider`).
library;

import 'trip_bbox.dart';

/// A promoted anchor, reduced to what a bbox revision needs to know about
/// it: enough to identify it and to test whether it still falls inside the
/// proposed extent.
class AnchorLocation {
  const AnchorLocation({required this.id, required this.label, required this.point});

  final String id;
  final String label;
  final LatLon point;
}

/// Which of [anchors] would no longer be inside [proposed]. Enlarging the
/// bbox (a pure superset of whatever produced [anchors]) always returns
/// empty, since every anchor was inside the smaller box already — that's
/// what lets a single check stand in for both "is this a shrink" and "does
/// it lose anything," per FR120's actual invariant (no second extent, not
/// bbox immutability).
List<AnchorLocation> anchorsOutsideBbox(TripBbox proposed, List<AnchorLocation> anchors) => [
      for (final a in anchors)
        if (!proposed.contains(a.point)) a,
    ];
