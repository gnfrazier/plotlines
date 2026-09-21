// #410 — the one place a promoted `Anchor` becomes a map mark. Sibling of
// `node_marker_role.dart` for the same reason: `Anchor`/`RoleKind` are
// domain types and `AnchorMarkerMark` is a brand-kit type, so the mapping
// lives in the client and every map surface (Route tab, Content tab, the
// Layers tab's candidate map) draws an anchor from here rather than each
// deciding its own shape.
library;

import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/anchor.dart';
import 'tap_to_pick_map.dart' show MapAnchorPoint;

/// The internal mark for [anchor]'s role set: one role keeps the shape its
/// candidate affinity had (circle / square / triangle), several roles draw
/// the star. Reads the role *kinds*, deduplicated — two narrative roles on
/// one anchor are still one kind of place.
AnchorMarkerMark anchorMarkFor(Anchor anchor) {
  final kinds = {for (final r in anchor.roles) r.kind};
  if (kinds.length > 1) return AnchorMarkerMark.multiRole;
  return switch (kinds.single) {
    RoleKind.narrative => AnchorMarkerMark.narrative,
    RoleKind.provision => AnchorMarkerMark.provision,
    RoleKind.station => AnchorMarkerMark.station,
  };
}

/// The tooltip: the anchor's title (or "Anchor" when it has none) and its
/// role kinds, in declaration order, so a mark reads as what it is on hover.
String anchorMapLabel(Anchor anchor) {
  final kinds = <String>[];
  for (final r in anchor.roles) {
    if (!kinds.contains(r.kind.wireValue)) kinds.add(r.kind.wireValue);
  }
  return '${anchor.title ?? 'Anchor'} — anchor · ${kinds.join(' + ')}';
}

/// Every anchor in [anchors] as one [MapAnchorPoint] at the anchor's own
/// [Anchor.coord] — the representative point FR106 requires every anchor to
/// carry, area or not. Role offsets (FR107) are not drawn here: they are the
/// role's trigger/export position, and O2's own surface draws them as the
/// hollow marker; the anchor is the place.
List<MapAnchorPoint> anchorMapPoints(List<Anchor> anchors) => [
      for (final a in anchors)
        (
          coord: [a.coord[0], a.coord[1]],
          label: anchorMapLabel(a),
          mark: anchorMarkFor(a),
          sourceId: a.provenance?.sourceId,
        ),
    ];
