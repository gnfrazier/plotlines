// Shared geometry helpers for the export writers — extracted from
// tcx_writer.dart's original private haversine so gpx/geojson can place a
// cue (which only carries `distanceAlongM`, not a coordinate — see
// domain/cue.dart) on the line too, not just TCX.
//
// `haversineM` itself moved to `domain/passage_sequence.dart` when B2/FR11
// needed the same measurement for a transition's adjacency gap: great-circle
// distance is a fact about two coordinates, not an export concern, and two
// copies of it is one copy too many to keep agreeing with
// `trips/compose.py`'s. Callers get it from the domain barrel, which every
// writer here already imports.
library;

import '../../domain/domain.dart';

/// The point [targetM] along [coords], linearly interpolated between the
/// two vertices it falls between. Clamps to the first/last vertex outside
/// the line's range rather than extrapolating.
///
/// The measurement itself is `domain/alternate_draft.dart`'s
/// [pointAtDistanceOnPath] (issue #324): a fork placed at MI 6.2 and a cue
/// placed at MI 6.2 have to land on the same metre of the same line, and two
/// copies of the walk is one copy too many to keep agreeing. This name stays
/// because every export writer already calls it.
Coord pointAtDistance(List<Coord> coords, double targetM) =>
    pointAtDistanceOnPath(coords, targetM);
