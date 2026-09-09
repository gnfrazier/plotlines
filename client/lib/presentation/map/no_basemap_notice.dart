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

import 'dart:math' as math;

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/home_region.dart';
import '../../domain/trip_bbox.dart';

/// The share of the viewport that must fall inside known coverage before the
/// map is treated as "should have tiles here." Below this, most of the frame
/// is bare ground and the honest-empty notice is shown (issue #318).
///
/// Chosen so a viewport that is *mostly* outside coverage — the extent-step
/// capture in #318, an Asheville-sized box of tiles floating in an otherwise
/// empty pane — reports out-of-coverage, while a small pan past the edge of a
/// framed extent does not flip the notice on.
const double kMinViewportCoverage = 0.5;

/// The fraction of [viewport]'s area that lies inside the union of the
/// shipped home region and (when given) this trip's own bbox.
///
/// Planar in degrees: viewports at authoring zoom are small enough that the
/// ratio of a lat/lon-rectangle's area to the viewport's is a fair proxy for
/// the on-screen covered fraction. This is a plausibility check, not a
/// per-tile guarantee — a bbox-cropped, per-zoom archive can still miss
/// inside these bounds, and the sidecar's own 404 stays authoritative for
/// any one tile.
double coveredViewportFraction(LatLngBounds viewport, {TripBbox? tripBbox}) {
  final vw = viewport.east - viewport.west;
  final vh = viewport.north - viewport.south;
  if (vw <= 0 || vh <= 0) return 0;
  final viewportArea = vw * vh;

  // Each coverage area, clipped to the viewport — at most two: the home
  // region and the trip bbox.
  final clipped = <List<double>>[]; // each: [west, south, east, north]
  void addClip(double west, double south, double east, double north) {
    final cw = math.max(west, viewport.west);
    final cs = math.max(south, viewport.south);
    final ce = math.min(east, viewport.east);
    final cn = math.min(north, viewport.north);
    if (ce > cw && cn > cs) clipped.add([cw, cs, ce, cn]);
  }

  addClip(HomeRegion.minLon, HomeRegion.minLat, HomeRegion.maxLon, HomeRegion.maxLat);
  if (tripBbox != null) {
    addClip(tripBbox.minLon, tripBbox.minLat, tripBbox.maxLon, tripBbox.maxLat);
  }
  if (clipped.isEmpty) return 0;

  double areaOf(List<double> r) => (r[2] - r[0]) * (r[3] - r[1]);
  var covered = clipped.fold<double>(0, (sum, r) => sum + areaOf(r));

  // Inclusion–exclusion for the one possible overlap (home region ∩ trip
  // bbox), so a trip drawn inside the home region is not double-counted.
  if (clipped.length == 2) {
    final a = clipped[0], b = clipped[1];
    final iw = math.min(a[2], b[2]) - math.max(a[0], b[0]);
    final ih = math.min(a[3], b[3]) - math.max(a[1], b[1]);
    if (iw > 0 && ih > 0) covered -= iw * ih;
  }

  return (covered / viewportArea).clamp(0.0, 1.0);
}

/// Whether enough of [viewport] is inside known coverage to expect tiles.
///
/// The predicate answers *"what fraction of the viewport is covered"*, not
/// *"do these rectangles touch"* (issue #318): a viewport that is 90%
/// outside the archive but clips one corner of a coverage area used to
/// return `true`, so the honest-empty notice was suppressed on exactly the
/// screen that needed it.
bool tilesLikelyCoverViewport(LatLngBounds viewport, {TripBbox? tripBbox}) =>
    coveredViewportFraction(viewport, tripBbox: tripBbox) >= kMinViewportCoverage;

/// The designed "off the map" ground under every map widget's tile layer: a
/// recessed surface tone ([ground]) carrying a latitude/longitude graticule
/// that pans and zooms with the map, with degree labels along the top and
/// left edges.
///
/// Issue #230 C1 put a grid here so a bbox-sized island of tiles reads as
/// the edge of the extent rather than a failed render; issue #318 makes it
/// carry its weight — the prior version drew the `border` token at 50% alpha
/// (invisible on the out-of-coverage ground) as a fixed 40 px screen grid
/// that did not move with the map and told the Author nothing.
///
/// Outside a [FlutterMap] (some widget tests) there is no camera to project
/// against; it still paints the ground and a static reference grid so the
/// widget degrades without throwing.
class MapGraticule extends StatelessWidget {
  const MapGraticule({
    super.key,
    required this.ground,
    required this.line,
    required this.label,
  });

  /// The recessed surface the out-of-coverage area is painted with
  /// (`surfaceSunk`) — a chosen tone, not whatever sits behind the map.
  final Color ground;

  /// Graticule strokes. Must carry real contrast on [ground].
  final Color line;

  /// Degree labels along the top and left edges (mono).
  final Color label;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: _GraticulePainter(
        ground: ground,
        line: line,
        label: label,
        camera: MapCamera.maybeOf(context),
        labelStyle: PlotTypography.data(label).copyWith(fontSize: 10, letterSpacing: 0.5),
      ),
    );
  }
}

class _GraticulePainter extends CustomPainter {
  _GraticulePainter({
    required this.ground,
    required this.line,
    required this.label,
    required this.camera,
    required this.labelStyle,
  });

  final Color ground;
  final Color line;
  final Color label;
  final MapCamera? camera;
  final TextStyle labelStyle;

  /// Whole-degree-derived spacings, coarsest first — the graticule steps
  /// down to the finest one that still leaves roughly [_targetDivisions]
  /// lines across the visible span.
  static const _steps = <double>[
    30, 10, 5, 2, 1, 0.5, 0.25, 0.1, 0.05, 0.025, 0.01, 0.005, 0.002, 0.001,
  ];
  static const _targetDivisions = 6;

  static double _stepFor(double spanDeg) {
    final target = spanDeg / _targetDivisions;
    for (final s in _steps) {
      if (s <= target) return s;
    }
    return _steps.last;
  }

  static int _decimalsFor(double step) {
    if (step >= 1) return 0;
    if (step >= 0.1) return 1;
    if (step >= 0.01) return 2;
    return 3;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = ground);

    final stroke = Paint()
      ..color = line.withValues(alpha: 0.7)
      ..strokeWidth = 1;

    final cam = camera;
    if (cam == null) {
      // No map to project against — a plain reference grid so the ground
      // still reads as a surface rather than a void.
      const step = 48.0;
      for (double x = step; x < size.width; x += step) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), stroke);
      }
      for (double y = step; y < size.height; y += step) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), stroke);
      }
      return;
    }

    final bounds = cam.visibleBounds;

    // Meridians — constant longitude.
    final lonStep = _stepFor((bounds.east - bounds.west).abs());
    final lonDec = _decimalsFor(lonStep);
    for (var lon = (bounds.west / lonStep).ceilToDouble() * lonStep;
        lon <= bounds.east;
        lon += lonStep) {
      final top = cam.latLngToScreenOffset(ll.LatLng(bounds.north, lon));
      final bottom = cam.latLngToScreenOffset(ll.LatLng(bounds.south, lon));
      canvas.drawLine(top, bottom, stroke);
      _paintLabel(canvas, _formatLon(lon, lonDec), Offset(top.dx + 3, 3));
    }

    // Parallels — constant latitude.
    final latStep = _stepFor((bounds.north - bounds.south).abs());
    final latDec = _decimalsFor(latStep);
    for (var lat = (bounds.south / latStep).ceilToDouble() * latStep;
        lat <= bounds.north;
        lat += latStep) {
      final left = cam.latLngToScreenOffset(ll.LatLng(lat, bounds.west));
      final right = cam.latLngToScreenOffset(ll.LatLng(lat, bounds.east));
      canvas.drawLine(left, right, stroke);
      _paintLabel(canvas, _formatLat(lat, latDec), Offset(3, left.dy + 3));
    }
  }

  void _paintLabel(Canvas canvas, String text, Offset at) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  static String _formatLon(double lon, int dec) {
    final norm = ((lon + 180) % 360 + 360) % 360 - 180;
    return '${norm.abs().toStringAsFixed(dec)}°${norm < 0 ? 'W' : 'E'}';
  }

  static String _formatLat(double lat, int dec) =>
      '${lat.abs().toStringAsFixed(dec)}°${lat < 0 ? 'S' : 'N'}';

  // Rebuilt on every map event by its parent (see each map widget's
  // `onMapEvent`), so the projected grid always reflects the live camera.
  @override
  bool shouldRepaint(_GraticulePainter old) => true;
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
