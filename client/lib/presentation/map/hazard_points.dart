/// C11 / FR27 (issue #47) — where a hazard stands, for the two surfaces that
/// draw it by position: the Route tab map and the selected passage's
/// elevation profile. Both read [HazardRollup.fromTrip], the same traversal
/// the itinerary, cue sheet and sync alert read, so no surface can disagree
/// about what exists. Nothing here is reveal-aware: a hazard carries no
/// reveal field (FR115).
library;

import '../../domain/domain.dart';

/// Where [located] stands on the map, in the order a hazard is placed: its own
/// point; a distance along its passage's solved line; the anchor it is pinned
/// to; the node it is pinned to. Null when none of those resolve.
Coord? hazardMapCoord(Trip trip, LocatedHazard located) {
  final hazard = located.hazard;
  if (hazard.coord != null) return hazard.coord;
  final segment = located.segmentId == null
      ? null
      : trip.days
          .expand((d) => d.segments)
          .where((s) => s.id == located.segmentId)
          .firstOrNull;
  final line = segment?.geometry?.coordinates;
  if (hazard.distanceAlongM != null && line != null && line.length >= 2) {
    return pointAtDistanceOnPath(line, hazard.distanceAlongM!);
  }
  if (hazard.anchorId != null) {
    final anchor = trip.anchors.where((a) => a.id == hazard.anchorId).firstOrNull;
    if (anchor != null) return anchor.coord;
  }
  if (hazard.nodeId != null) {
    for (final d in trip.days) {
      for (final n in [...d.nodes, ...d.segments.expand((s) => s.nodes)]) {
        if (n.id == hazard.nodeId) return n.coord;
      }
    }
  }
  return null;
}

/// How close a hazard placed by coordinate must sit to [segment]'s line to be
/// marked on its elevation profile. Farther than this it is not "on" the
/// passage, and a tick at the nearest point would misplace it.
const double kHazardOnProfileToleranceM = 100;

/// Each hazard on [segment]'s elevation profile, as a fraction `0..1` of the
/// passage's length: its own distance-along when it has one, otherwise its
/// placed coordinate ([hazardMapCoord]) projected onto the line when that lies
/// within [kHazardOnProfileToleranceM]. Empty for a passage with no line.
List<double> hazardProfileFractions(Trip trip, Segment segment) {
  final line = segment.geometry?.coordinates;
  if (line == null || line.length < 2) return const [];
  final length = pathLengthM(line);
  if (length <= 0) return const [];
  final out = <double>[];
  for (final located in HazardRollup.fromTrip(trip).hazards) {
    double? along;
    if (located.segmentId == segment.id && located.hazard.distanceAlongM != null) {
      along = located.hazard.distanceAlongM;
    } else if (hazardMapCoord(trip, located) case final coord?) {
      final snap = snapToPath(line, coord);
      if (snap != null && snap.offsetM <= kHazardOnProfileToleranceM) along = snap.alongM;
    }
    if (along != null) out.add((along / length).clamp(0.0, 1.0));
  }
  return out;
}
