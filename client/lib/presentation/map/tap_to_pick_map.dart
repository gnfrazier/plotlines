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
import 'map_label_scale.dart';
import 'no_basemap_notice.dart';
import 'vector_tile_provider.dart';

typedef LatLonPoint = List<double>; // [lon, lat]

/// A marker to draw, tagged with the role it plays. The caller states the
/// role; the map draws it. Before #320 the marker type was picked from a
/// point's index in a concatenated list, so a day-2 start was drawn as the
/// narrative `plot` marker and the very first point as a concentric-ring
/// target — role read from position instead of from role.
typedef MapMarkerPoint = ({LatLonPoint coord, NodeMarkerType role});

/// #322 — a thin connector from an authored node to its nearest point on the
/// route, drawn when the node sits off the line so its relationship to the
/// day is visible rather than left to be guessed from proximity.
typedef MapLeaderLine = ({LatLonPoint from, LatLonPoint to});

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
  ///
  /// Keyed by `<name>@<label-scale bucket>` (issue #321): the same style at
  /// a different map-label scale is a different parsed theme, so changing
  /// TEXT SIZE in Preferences re-parses rather than serving the old ramp,
  /// while an unchanged scale still hits the cache on every rebuild.
  static final Map<String, Future<BasemapThemeResult>> _themes = {};

  /// [labelScale] multiplies every `text-size` in the style before it is
  /// parsed (issue #321) — the resolved app text scale times the DPR
  /// baseline, from [resolveMapLabelScale]. Defaults to 1.0 (parse the
  /// shipped bytes unchanged).
  static Future<BasemapThemeResult> theme(String name, {double labelScale = 1.0}) {
    final key = '$name@${mapLabelScaleBucket(labelScale)}';
    final pending = _themes[key];
    if (pending != null) return pending;
    final future = loadBasemapTheme(candidateStylePaths(name), labelScale: labelScale);
    _themes[key] = future;
    future.then((result) {
      if (!result.ok) _themes.remove(key);
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
  double labelScale = 1.0,
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
    // Issue #321 — multiply every `text-size` before parsing so the map's
    // labels honour the app's TEXT SIZE preference and the desktop DPR
    // baseline. A `labelScale` of 1.0 returns the style unchanged.
    final scaled = scaleStyleTextSizes(json, labelScale);
    return BasemapThemeResult.ready(ThemeReader().read(scaled));
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
    this.leaderLines = const [],
    this.center,
    this.focusCoord,
    this.initialZoom = 13,
    this.outline,
  });

  final List<MapMarkerPoint> points;
  final void Function(LatLonPoint)? onTap;
  final List<LatLonPoint> polyline;

  /// #322 — off-route node → nearest-point-on-line connectors, drawn muted and
  /// dashed beneath the markers.
  final List<MapLeaderLine> leaderLines;

  final LatLonPoint? center;

  /// #322 — a coordinate to pan to and draw highlighted whenever it changes:
  /// the node that was just saved or selected. Distinct from [center], which
  /// only seeds the initial camera; a new [focusCoord] moves a map already on
  /// screen so the Author sees what they just made.
  final LatLonPoint? focusCoord;

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
  void didUpdateWidget(TapToPickMap old) {
    super.didUpdateWidget(old);
    // #322 — a fresh focus coordinate (a node just saved or selected) pans the
    // live map to it. Guarded on `_mapReady` because `camera` throws before
    // `FlutterMap` has laid out; the same guard `trip_area_map.dart` uses.
    final f = widget.focusCoord;
    if (f != null && !_sameCoord(f, old.focusCoord) && _mapReady) {
      _mapController.move(ll.LatLng(f[1], f[0]), _mapController.camera.zoom);
    }
  }

  static bool _sameCoord(LatLonPoint? a, LatLonPoint? b) =>
      a == null || b == null ? a == b : a[0] == b[0] && a[1] == b[1];

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    final isDark = material.Theme.of(context).brightness == Brightness.dark;
    final labelScale = resolveMapLabelScale(
      MediaQuery.textScalerOf(context).scale(1),
      MediaQuery.devicePixelRatioOf(context),
    );
    final startCenter = widget.center ??
        (widget.points.isNotEmpty ? widget.points.first.coord : HomeRegion.center);
    final sidecar = ref.watch(sidecarManagerProvider);
    final baseUrl = sidecar.baseUrl;
    final tilesArchiveId = sidecar.capabilities?.tilesArchiveId;

    return FutureBuilder(
      future: MapTileAssets.theme(isDark ? 'dark' : 'light', labelScale: labelScale),
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
                onMapReady: () {
                  setState(() => _mapReady = true);
                  // #322 — a node already selected when the map mounts is
                  // revealed as soon as there is a camera to move.
                  final f = widget.focusCoord;
                  if (f != null) {
                    _mapController.move(
                        ll.LatLng(f[1], f[0]), _mapController.camera.zoom);
                  }
                },
              ),
              children: [
                // Issue #230 C1 — the grid is the ground under the tiles,
                // not a fallback for their absence: past the edge of
                // coverage the map reads as a map, not as a failed render.
                MapGraticule(ground: c.surfaceSunk, line: c.textMuted, label: c.textSecondary),
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
                // #322 — leader lines from off-route nodes to the line. Muted
                // and dashed so they read as a reference, not as route.
                if (widget.leaderLines.isNotEmpty)
                  PolylineLayer(polylines: [
                    for (final l in widget.leaderLines)
                      Polyline(
                        points: [
                          ll.LatLng(l.from[1], l.from[0]),
                          ll.LatLng(l.to[1], l.to[0]),
                        ],
                        color: c.textMuted,
                        strokeWidth: 1.5,
                        pattern: StrokePattern.dashed(segments: const [6.0, 4.0]),
                      ),
                  ]),
                MarkerLayer(markers: [
                  for (final p in widget.points)
                    if (_sameCoord(p.coord, widget.focusCoord))
                      Marker(
                        point: ll.LatLng(p.coord[1], p.coord[0]),
                        width: 44,
                        height: 44,
                        child: _HighlightedMarker(role: p.role, halo: c.primary),
                      )
                    else
                      Marker(
                        point: ll.LatLng(p.coord[1], p.coord[0]),
                        width: 28,
                        height: 28,
                        child: NodeMarker(p.role),
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

/// #322 — the marker for the node the planner is focused on: the canonical
/// [NodeMarker] shape (so its kind still reads) sat on a soft [halo] ring, a
/// little larger. The halo carries the "this one" signal without changing the
/// mark itself.
class _HighlightedMarker extends StatelessWidget {
  const _HighlightedMarker({required this.role, required this.halo});

  final NodeMarkerType role;
  final Color halo;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: halo.withValues(alpha: 0.14),
          border: Border.all(color: halo, width: 2),
        ),
        child: Center(child: NodeMarker(role, size: 26)),
      ),
    );
  }
}
