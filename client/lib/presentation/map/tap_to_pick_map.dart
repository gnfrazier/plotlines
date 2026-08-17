// The map canvas every screen composes with. Real pan/zoom/tap via
// flutter_map (ARCH D22), with a real vector basemap (ARCH D23/D24,
// SPIKE-14) — see vector_tile_provider.dart for where the tile data comes
// from and its one real limit: only the Boulder, CO fixture bbox is
// extracted, matching the SPIKE-00 graph every dev run routes against.
// Panning outside it is a legitimate "no tiles here" state, not a bug, and
// is shown rather than hidden.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter/material.dart' as material show Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:plotlines_ui/plotlines_ui.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import 'vector_tile_provider.dart';

typedef LatLonPoint = List<double>; // [lon, lat]

/// Parses the style JSON and resolves the tile directory once per app run —
/// both are pure/static for a given theme name, and re-parsing a few
/// hundred KB of style rules on every map widget rebuild would be wasted
/// work (SPIKE-14 timed theme parse separately for exactly this reason).
class _MapAssets {
  static final Map<String, Future<Theme?>> _themes = {};
  static Future<DirectoryVectorTileProvider?>? _provider;

  static Future<Theme?> theme(String name) => _themes.putIfAbsent(name, () async {
        try {
          final json = jsonDecode(
            await File(_stylePath(name)).readAsString(),
          ) as Map<String, dynamic>;
          return ThemeReader().read(json);
        } catch (_) {
          return null;
        }
      });

  static String _stylePath(String name) {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final bundled = File('${exeDir.path}/data/flutter_assets/assets/map_style/style_$name.json');
    if (bundled.existsSync()) return bundled.path;
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      final candidate = File('${dir.path}/client/assets/map_style/style_$name.json');
      if (candidate.existsSync()) return candidate.path;
      final fromClient = File('${dir.path}/assets/map_style/style_$name.json');
      if (fromClient.existsSync()) return fromClient.path;
      if (dir.parent.path == dir.path) break;
      dir = dir.parent;
    }
    return 'assets/map_style/style_$name.json'; // will fail existence check above and fall through
  }

  static Future<DirectoryVectorTileProvider?> provider() => _provider ??= Future(() {
        final root = resolveTilesRoot();
        return root == null ? null : DirectoryVectorTileProvider(root);
      });
}

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
    final isDark = material.Theme.of(context).brightness == Brightness.dark;
    final startCenter = center ?? (points.isNotEmpty ? points.first : const [-105.2705, 40.0150]);

    return FutureBuilder(
      future: Future.wait([_MapAssets.theme(isDark ? 'dark' : 'light'), _MapAssets.provider()]),
      builder: (context, snapshot) {
        final results = snapshot.data;
        final vectorTheme = results?[0] as Theme?;
        final provider = results?[1] as DirectoryVectorTileProvider?;
        final tilesAvailable = vectorTheme != null && provider != null;

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
                if (tilesAvailable)
                  VectorTileLayer(
                    theme: vectorTheme,
                    tileProviders: TileProviders({'protomaps': provider}),
                    maximumZoom: 15,
                  )
                else
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
            if (!tilesAvailable)
              Positioned(
                left: PlotSpacing.s3,
                bottom: PlotSpacing.s3,
                child: _NoBasemapNotice(
                  loading: snapshot.connectionState != ConnectionState.done,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A plain lat/lon grid so panning/zooming reads as *a map* on the rare
/// path with no tile coverage (outside Boulder, or the dev tile tree isn't
/// on disk), while the load is still in flight, or as an honest fallback.
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
  const _NoBasemapNotice({required this.loading});
  final bool loading;

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
          Text(
            loading ? 'Loading basemap…' : 'No basemap tiles here (Boulder, CO only)',
            style: PlotTypography.data(c.textMuted),
          ),
        ],
      ),
    );
  }
}
