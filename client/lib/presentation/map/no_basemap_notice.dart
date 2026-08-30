// The honest-empty basemap state, shared by every map widget (FR92-96;
// issue #154). Before this, each of `trip_area_map.dart`,
// `tap_to_pick_map.dart` and `candidate_map.dart` carried its own byte-
// identical copy hardcoding "No basemap tiles here (Boulder, CO only)" —
// stale even at the moment it shipped (`HomeRegion` had already moved to
// Buncombe County) and gated on whether the tile *directory* existed on
// disk, never on whether the *current viewport* had coverage. Panning to
// Buncombe with the directory present still showed a graticule with no
// notice at all, because "directory exists" was the only thing checked.
//
// Tiles are now served by the sidecar (`GET /tiles/{z}/{x}/{y}`, FR92) from
// two possible sources: the committed home-region archive, and — once
// ensured — the trip's own on-demand region cache. Both areas are already
// known client-side (`HomeRegion`'s constants; `TripBbox` the Author drew),
// so [tilesLikelyCoverViewport] answers "should this pan have tiles" with no
// network call and no reference to any one fixture region.
library;

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/home_region.dart';
import '../../domain/trip_bbox.dart';

bool _intersects(LatLngBounds viewport, double minLat, double minLon, double maxLat, double maxLon) {
  return !(viewport.west > maxLon ||
      viewport.east < minLon ||
      viewport.south > maxLat ||
      viewport.north < minLat);
}

/// A *plausibility* check against known coverage bounds, not a guarantee
/// any one tile in view exists (bbox-cropped, per-zoom archives can still
/// miss inside these bounds — the sidecar's own 404 is what's authoritative
/// for one tile). This is the distinction the honest-empty notice needs:
/// "nowhere near anything we serve" versus "should be covered."
bool tilesLikelyCoverViewport(LatLngBounds viewport, {TripBbox? tripBbox}) {
  if (_intersects(viewport, HomeRegion.minLat, HomeRegion.minLon, HomeRegion.maxLat, HomeRegion.maxLon)) {
    return true;
  }
  if (tripBbox != null &&
      _intersects(viewport, tripBbox.minLat, tripBbox.minLon, tripBbox.maxLat, tripBbox.maxLon)) {
    return true;
  }
  return false;
}

/// A plain lat/lon grid so panning/zooming reads as *a map* while tiles are
/// still loading, or on the (now rare, viewport-gated) no-coverage path.
class MapGraticule extends StatelessWidget {
  const MapGraticule({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _GraticulePainter(color), size: Size.infinite);
  }
}

class _GraticulePainter extends CustomPainter {
  _GraticulePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    const step = 40.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GraticulePainter old) => false;
}

/// The one honest-empty-basemap notice every map widget shows now (issue
/// #154 de-duplicates the three former copies). Never names a region —
/// there is no longer exactly one fixture to name.
class NoBasemapNotice extends StatelessWidget {
  const NoBasemapNotice({
    super.key,
    required this.loading,
    this.outOfCoverage = false,
    this.styleFailed = false,
  });

  /// The tile theme/provider are still being resolved for the first time.
  final bool loading;

  /// The current viewport is plausibly outside every known coverage area
  /// (see [tilesLikelyCoverViewport]) — a legitimate "nothing to show here"
  /// distinct from [loading].
  final bool outOfCoverage;

  /// The basemap *style* itself failed to load (issue #184) — a defect,
  /// not a coverage answer. Worded so it does not read as "this area has
  /// no tiles"; the cause and the paths tried are in the logs.
  final bool styleFailed;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final text = loading
        ? 'Loading basemap…'
        : styleFailed
            ? 'Basemap unavailable — the map style failed to load (see logs)'
            : outOfCoverage
                ? 'No basemap tiles here — outside the shipped home region and '
                  'this trip\'s own area'
                : 'No basemap tiles here';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: PlotSpacing.s3, vertical: PlotSpacing.s2),
      decoration: BoxDecoration(
        color: c.surfaceCard.withValues(alpha: 0.92),
        borderRadius: const BorderRadius.all(PlotRadii.md),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.layers_outlined, size: 14, color: c.textMuted),
          const SizedBox(width: PlotSpacing.s2),
          Text(text, style: PlotTypography.data(c.textMuted)),
        ],
      ),
    );
  }
}
