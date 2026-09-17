// Issue #277 (Phase 3.5) — the full-text licence notice every export writer
// in this directory owes, derived once so gpx/tcx/geojson/fit/itinerary
// never each invent their own formatting.
//
// Reuses `attributionForTrip` (`reveal_view.dart`) rather than reading
// `trip.provenance?.attribution` directly: that function already merges the
// four always-owed static credits (elevation/basemap/graph/geocode,
// `aboutStaticAttribution`) with whatever the trip's own `Provenance`
// carries, so a pre-#270 trip with no provenance at all still exports the
// credits it has always owed rather than an empty notice.
library;

import '../../domain/trip.dart';
import '../reveal_view.dart';

/// One line per credit (with its terms URL appended where one exists), then
/// — when the trip's own `Provenance` names one (issue #277's mirror-build-id
/// pin, or Phase 1's `overpass:<date>`) — the OSM snapshot line. Never
/// fabricated: a trip with no `osmSource` on record simply carries no
/// snapshot line, which is the honest, defined fallback for a trip authored
/// before #270 (issue #277 acceptance item 4).
String exportAttributionNotice(Trip trip) {
  final lines = [
    for (final line in attributionForTrip(trip))
      line.termsUrl.isEmpty ? line.attribution : '${line.attribution} (${line.termsUrl})',
  ];
  final osmSource = trip.provenance?.osmSource;
  if (osmSource != null && osmSource.isNotEmpty) {
    lines.add('OSM data snapshot: $osmSource');
  }
  return lines.join('\n');
}
