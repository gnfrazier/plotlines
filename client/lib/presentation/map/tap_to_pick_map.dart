// The map canvas every screen composes with. Real pan/zoom/tap via
// flutter_map (ARCH D22), with a real vector basemap served by the sidecar
// (ARCH D23/D24, FR92; see vector_tile_provider.dart). The honest-empty
// state (`no_basemap_notice.dart`) is viewport-based, not tied to any one
// fixture region.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter/material.dart' as material show Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:plotlines_ui/plotlines_ui.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../../domain/home_region.dart';
import '../../state/providers.dart';
import 'no_basemap_notice.dart';
import 'vector_tile_provider.dart';

typedef LatLonPoint = List<double>; // [lon, lat]

/// Parses the style JSON once per theme name and reuses it — pure/static
/// for a given name, and re-parsing a few hundred KB of style rules on
/// every map widget rebuild would be wasted work (SPIKE-14 timed theme
/// parse separately for exactly this reason).
///
/// Public (not `_`-private) so every map widget in this directory shares
/// the same once-per-run cache rather than duplicating this loading logic.
/// The tile *provider* is no longer cached here (issue #154): it's a thin
/// sidecar-backed HTTP client now, cheap to construct fresh against the
/// current `SidecarManager.baseUrl` each build — caching it would survive
/// past a sidecar restart's port change.
class MapTileAssets {
  static final Map<String, Future<Theme?>> _themes = {};

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
}

class TapToPickMap extends ConsumerStatefulWidget {
  const TapToPickMap({
    super.key,
    this.points = const [],
    this.onTap,
    this.polyline = const [],
    this.center,
    this.initialZoom = 13,
    this.outline,
  });

  final List<LatLonPoint> points;
  final void Function(LatLonPoint)? onTap;
  final List<LatLonPoint> polyline;
  final LatLonPoint? center;
  final double initialZoom;

  /// A static bbox outline to draw on the map (A10's shipped home region;
  /// also reusable by N1's trip bbox once that lands). Border only, no fill
  /// — this is a backdrop, not an editable shape.
  final List<LatLonPoint>? outline;

  @override
  ConsumerState<TapToPickMap> createState() => _TapToPickMapState();
}

class _TapToPickMapState extends ConsumerState<TapToPickMap> {
  final _mapController = MapController();
  bool _mapReady = false;

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final isDark = material.Theme.of(context).brightness == Brightness.dark;
    final startCenter =
        widget.center ?? (widget.points.isNotEmpty ? widget.points.first : HomeRegion.center);
    final baseUrl = ref.watch(sidecarManagerProvider).baseUrl;

    return FutureBuilder(
      future: MapTileAssets.theme(isDark ? 'dark' : 'light'),
      builder: (context, snapshot) {
        final vectorTheme = snapshot.data;
        final provider = SidecarVectorTileProvider(baseUrl);
        final tilesAvailable = vectorTheme != null;
        // The live camera bounds (issue #154: viewport-based, not tied to
        // any one fixture region) — `_mapReady` guards the first build,
        // before `FlutterMap` has laid out and `camera` is queryable.
        final outOfCoverage =
            _mapReady && !tilesLikelyCoverViewport(_mapController.camera.visibleBounds);

        return Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: ll.LatLng(startCenter[1], startCenter[0]),
                initialZoom: widget.initialZoom,
                onTap: widget.onTap == null
                    ? null
                    : (tapPosition, point) => widget.onTap!([point.longitude, point.latitude]),
                onMapEvent: (_) => setState(() {}),
                onMapReady: () => setState(() => _mapReady = true),
              ),
              children: [
                if (tilesAvailable)
                  VectorTileLayer(
                    theme: vectorTheme,
                    tileProviders: TileProviders({'protomaps': provider}),
                    maximumZoom: 15,
                  )
                else
                  MapGraticule(color: c.border),
                if (widget.outline != null && widget.outline!.length >= 3)
                  PolygonLayer(polygons: [
                    Polygon(
                      points: [for (final p in widget.outline!) ll.LatLng(p[1], p[0])],
                      color: c.primary.withValues(alpha: 0.05),
                      borderColor: c.primary,
                      borderStrokeWidth: 2,
                    ),
                  ]),
                if (widget.polyline.length >= 2)
                  PolylineLayer(polylines: [
                    Polyline(
                      points: [for (final p in widget.polyline) ll.LatLng(p[1], p[0])],
                      color: c.primary,
                      strokeWidth: 4,
                    ),
                  ]),
                MarkerLayer(markers: [
                  for (var i = 0; i < widget.points.length; i++)
                    Marker(
                      point: ll.LatLng(widget.points[i][1], widget.points[i][0]),
                      width: 28,
                      height: 28,
                      child: NodeMarker(
                        i == 0
                            ? NodeMarkerType.waypoint
                            : (i == widget.points.length - 1
                                ? NodeMarkerType.regroup
                                : NodeMarkerType.plot),
                      ),
                    ),
                ]),
              ],
            ),
            if (!tilesAvailable || outOfCoverage)
              Positioned(
                left: PlotSpacing.s3,
                bottom: PlotSpacing.s3,
                child: NoBasemapNotice(
                  loading: snapshot.connectionState != ConnectionState.done,
                  outOfCoverage: tilesAvailable && outOfCoverage,
                ),
              ),
          ],
        );
      },
    );
  }
}
