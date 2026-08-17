// The map canvas every screen composes with. Real pan/zoom/tap via
// flutter_map (ARCH D22's chosen package) — but **no tile layer**, and that
// is a deliberate, honest gap, not an oversight:
//
// SPIKE-14 decided the tile source (Protomaps Basemap, ODbL) and the tool
// (`pmtiles extract` against the published planet build, ARCH §1.4.5) but
// nobody has run that extract in this environment — it needs a live fetch
// against a multi-hundred-GB published build and a `/tiles/{z}/{x}/{y}`
// endpoint service/app.py doesn't register yet (own-service-only per
// PRD FR92-94; hotlinking a public tile server would violate that contract
// outright, so this deliberately does not fall back to one). Faking imagery
// here would hide a real blocker; see the MVP doc's open questions.
//
// What still works without tiles: panning, zooming, tap-to-pick-coordinates,
// and drawing whatever geometry/markers the caller passes in — everything a
// screen needs to be interactively testable before real tiles exist.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:plotlines_ui/plotlines_ui.dart';

typedef LatLonPoint = List<double>; // [lon, lat]

class TapToPickMap extends StatelessWidget {
  const TapToPickMap({
    super.key,
    this.points = const [],
    this.onTap,
    this.polyline = const [],
    this.center,
    this.initialZoom = 13,
  });

  final List<LatLonPoint> points;
  final void Function(LatLonPoint)? onTap;
  final List<LatLonPoint> polyline;
  final LatLonPoint? center;
  final double initialZoom;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final startCenter = center ?? (points.isNotEmpty ? points.first : const [-105.2705, 40.0150]);
    return Stack(
      children: [
        FlutterMap(
          options: MapOptions(
            initialCenter: ll.LatLng(startCenter[1], startCenter[0]),
            initialZoom: initialZoom,
            onTap: onTap == null
                ? null
                : (tapPosition, point) => onTap!([point.longitude, point.latitude]),
          ),
          children: [
            _Graticule(color: c.border),
            if (polyline.length >= 2)
              PolylineLayer(polylines: [
                Polyline(
                  points: [for (final p in polyline) ll.LatLng(p[1], p[0])],
                  color: c.primary,
                  strokeWidth: 4,
                ),
              ]),
            MarkerLayer(markers: [
              for (var i = 0; i < points.length; i++)
                Marker(
                  point: ll.LatLng(points[i][1], points[i][0]),
                  width: 28,
                  height: 28,
                  child: NodeMarker(
                    i == 0
                        ? NodeMarkerType.waypoint
                        : (i == points.length - 1 ? NodeMarkerType.regroup : NodeMarkerType.plot),
                  ),
                ),
            ]),
          ],
        ),
        Positioned(
          left: PlotSpacing.s3,
          bottom: PlotSpacing.s3,
          child: _NoBasemapNotice(),
        ),
      ],
    );
  }
}

/// A plain lat/lon grid so panning/zooming reads as *a map*, not an empty
/// canvas, while no real basemap is wired in.
class _Graticule extends StatelessWidget {
  const _Graticule({required this.color});
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

class _NoBasemapNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
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
          Text('No basemap tiles bundled yet', style: PlotTypography.data(c.textMuted)),
        ],
      ),
    );
  }
}
