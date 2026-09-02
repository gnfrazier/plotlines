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
import 'map_attribution.dart';
import 'no_basemap_notice.dart';
import 'vector_tile_provider.dart';

typedef LatLonPoint = List<double>; // [lon, lat]

/// Why a bundled basemap style failed to resolve. A bare `null` collapsed
/// these four into one indistinguishable outcome (issue #184, an M13
/// "never a silent failure" violation) — the caller could not tell a
/// legitimate "no style shipped for this build" from a defect, and none
/// of them was logged.
enum BasemapThemeError {
  /// No `style_<name>.json` existed at any resolved path.
  styleNotFound,

  /// A style file was found but could not be read (permissions, I/O).
  styleUnreadable,

  /// The file was read but is not valid JSON, or not a JSON object.
  styleMalformed,

  /// The JSON parsed but `ThemeReader` rejected it as a style.
  themeRejected,
}

/// The outcome of [MapTileAssets.theme]: either a parsed [theme], or a
/// [error] with the [cause] and the [pathsSearched] that produced it.
/// Every failure is also logged once via [debugPrint] at the point it
/// occurs, including the full path list (issue #184).
class BasemapThemeResult {
  const BasemapThemeResult.ready(Theme this.theme)
      : error = null,
        cause = null,
        pathsSearched = const [];

  const BasemapThemeResult.failed(
    BasemapThemeError this.error,
    this.cause,
    this.pathsSearched,
  ) : theme = null;

  /// The parsed style on success, null on any failure.
  final Theme? theme;

  /// Which failure mode, or null on success.
  final BasemapThemeError? error;

  /// The underlying exception for [BasemapThemeError.styleUnreadable],
  /// [BasemapThemeError.styleMalformed] and [BasemapThemeError.themeRejected];
  /// null for [BasemapThemeError.styleNotFound] and on success.
  final Object? cause;

  /// The paths that were checked. For [BasemapThemeError.styleNotFound]
  /// this is every candidate; otherwise the single file that was opened.
  final List<String> pathsSearched;

  bool get ok => theme != null;
}

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
///
/// [theme] returns a [BasemapThemeResult] — never a bare `null` — so a
/// caller can tell a legitimate "no style for this build" from a defect
/// and every failure is logged once (issue #184).
class MapTileAssets {
  /// Only *successful* loads stay cached for the life of the run. A
  /// failure is evicted once its future settles (issue #184) so a
  /// transient cause (a file briefly unreadable, a sidecar mid-write) is
  /// retried on the next build rather than pinned forever.
  static final Map<String, Future<BasemapThemeResult>> _themes = {};

  static Future<BasemapThemeResult> theme(String name) {
    final pending = _themes[name];
    if (pending != null) return pending;
    final future = loadBasemapTheme(candidateStylePaths(name));
    _themes[name] = future;
    future.then((result) {
      if (!result.ok) _themes.remove(name);
    });
    return future;
  }

  /// Every path `style_<name>.json` is looked for, in order: the bundled
  /// `data/flutter_assets/...` beside the executable, then `client/assets`
  /// and `assets` walking up to six levels from the CWD. Returned in full
  /// so a not-found failure can report exactly what it tried.
  @visibleForTesting
  static List<String> candidateStylePaths(String name) {
    final paths = <String>[];
    final exeDir = File(Platform.resolvedExecutable).parent;
    paths.add('${exeDir.path}/data/flutter_assets/assets/map_style/style_$name.json');
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      paths.add('${dir.path}/client/assets/map_style/style_$name.json');
      paths.add('${dir.path}/assets/map_style/style_$name.json');
      if (dir.parent.path == dir.path) break;
      dir = dir.parent;
    }
    return paths;
  }
}

/// Resolves the first existing path in [candidatePaths], reads it, parses
/// it and hands it to `ThemeReader`, returning a typed [BasemapThemeResult]
/// that keeps the four failure modes distinct and logs each one once
/// (issue #184). [exists] and [read] are injectable for tests.
@visibleForTesting
Future<BasemapThemeResult> loadBasemapTheme(
  List<String> candidatePaths, {
  bool Function(String path)? exists,
  Future<String> Function(String path)? read,
}) async {
  final existsFn = exists ?? (p) => File(p).existsSync();
  final readFn = read ?? (p) => File(p).readAsString();

  final found = candidatePaths.firstWhere(existsFn, orElse: () => '');
  if (found.isEmpty) {
    debugPrint(
      'basemap: no style file found; searched:\n  ${candidatePaths.join('\n  ')}',
    );
    return BasemapThemeResult.failed(
      BasemapThemeError.styleNotFound,
      null,
      List.unmodifiable(candidatePaths),
    );
  }

  final String raw;
  try {
    raw = await readFn(found);
  } catch (e) {
    debugPrint('basemap: style file $found could not be read: $e');
    return BasemapThemeResult.failed(
      BasemapThemeError.styleUnreadable,
      e,
      List.unmodifiable([found]),
    );
  }

  final Map<String, dynamic> json;
  try {
    json = jsonDecode(raw) as Map<String, dynamic>;
  } catch (e) {
    debugPrint('basemap: style file $found is not a valid JSON object: $e');
    return BasemapThemeResult.failed(
      BasemapThemeError.styleMalformed,
      e,
      List.unmodifiable([found]),
    );
  }

  try {
    return BasemapThemeResult.ready(ThemeReader().read(json));
  } catch (e) {
    debugPrint('basemap: style file $found was rejected by ThemeReader: $e');
    return BasemapThemeResult.failed(
      BasemapThemeError.themeRejected,
      e,
      List.unmodifiable([found]),
    );
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
    final sidecar = ref.watch(sidecarManagerProvider);
    final baseUrl = sidecar.baseUrl;
    final tilesArchiveId = sidecar.capabilities?.tilesArchiveId;

    return FutureBuilder(
      future: MapTileAssets.theme(isDark ? 'dark' : 'light'),
      builder: (context, snapshot) {
        final themeResult = snapshot.data;
        final vectorTheme = themeResult?.theme;
        final provider = SidecarVectorTileProvider(baseUrl);
        final tilesAvailable = vectorTheme != null;
        // issue #184: a settled result that is not `ok` is a
        // basemap-style defect, distinct from a legitimate
        // out-of-coverage viewport.
        final styleFailed = themeResult != null && !themeResult.ok;
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
                // Issue #230 C1 — the grid is the ground under the tiles,
                // not a fallback for their absence: past the edge of
                // coverage the map reads as a map, not as a failed render.
                MapGraticule(color: c.border),
                if (tilesAvailable)
                  VectorTileLayer(
                    theme: vectorTheme,
                    tileProviders: TileProviders({'protomaps': provider}),
                    maximumZoom: basemapMaximumZoom.toDouble(),
                    cacheFolder: basemapCacheFolderCallback(tilesArchiveId),
                  ),
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
                bottom: PlotSpacing.s3 + 26,
                child: NoBasemapNotice(
                  loading: snapshot.connectionState != ConnectionState.done,
                  outOfCoverage: tilesAvailable && outOfCoverage,
                  styleFailed: styleFailed,
                ),
              ),
            // K10/FR95 (issue #230 C1) — ODbL credit on the map itself, not
            // only in Preferences.
            const Positioned(
              left: PlotSpacing.s3,
              bottom: PlotSpacing.s3,
              child: MapAttribution(),
            ),
          ],
        );
      },
    );
  }
}
