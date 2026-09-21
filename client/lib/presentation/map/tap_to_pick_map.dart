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
import '../../state/settings_provider.dart';
import 'anchor_area_layer.dart';
import 'arc_stage_marker.dart';
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
///
/// [arcStage] (FR38 / O6, issue #392) is the point's own `Node.arcStage`
/// wire string, when it carries a story beat — a corner [ArcStageBadge] on
/// top of the role's own [NodeMarker], never a replacement for it.
typedef MapMarkerPoint = ({LatLonPoint coord, NodeMarkerType role, String? arcStage});

/// #322 — a thin connector from an authored node to its nearest point on the
/// route, drawn when the node sits off the line so its relationship to the
/// day is visible rather than left to be guessed from proximity.
typedef MapLeaderLine = ({LatLonPoint from, LatLonPoint to});

/// #324 — a mark the caller draws itself, at a coordinate. Used for the fork
/// and rejoin of an alternate being drawn, which are not nodes on the day and
/// so do not come from [MapMarkerPoint]'s node-role vocabulary.
typedef MapAnnotation = ({LatLonPoint coord, Widget marker});

/// #410 — a promoted anchor's own coordinate, drawn as an [AnchorMarker].
/// Built from `Trip.anchors` by `anchor_map_points.dart`; [label] is the
/// tooltip, [sourceId] the candidate it was promoted from (if any), so a
/// candidate map can retire that candidate's mark in favour of this one.
/// [rings] (#484, FR108) is an area anchor's boundary — exterior ring first,
/// holes after, each closed — drawn by `AnchorAreaLayer`; `null` for a point
/// anchor. Not a [MapMarkerPoint]: an anchor is trip canon with a role set,
/// not a node with a [NodeMarkerType], and the two vocabularies stay apart.
typedef MapAnchorPoint = ({
  LatLonPoint coord,
  String label,
  AnchorMarkerMark mark,
  String? sourceId,
  List<List<LatLonPoint>>? rings,
});

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

  /// Issue #465 — the `<name>@<scale bucket>` keys requested so far, for a
  /// widget test to confirm which style name actually reached [theme]
  /// (`Theme.id` doesn't distinguish our styles: none of the committed JSON
  /// sets `"id"`, so `ThemeReader` falls back to `'default'` for all three).
  /// Never cleared — a widget test asserts a key is *present*, not that the
  /// cache is otherwise empty, since other tests in the same run share it.
  @visibleForTesting
  static Set<String> get requestedKeysForTesting => _themes.keys.toSet();

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
    this.draftLine = const [],
    this.alternateLines = const [],
    this.replacedStretch = const [],
    this.annotations = const [],
    this.anchors = const [],
    this.center,
    this.focusCoord,
    this.initialZoom = 13,
    this.outline,
    this.polylineArcStage,
  });

  final List<MapMarkerPoint> points;
  final void Function(LatLonPoint)? onTap;
  final List<LatLonPoint> polyline;

  /// FR38 / O6, issue #392 — [polyline]'s own arc stage, when the passage it
  /// draws carries one (`Segment.arcStage`): the "stretches of route" half of
  /// the AC's "arc roles attach to anchors and passages both", drawn as an
  /// [ArcStageBadge] at the line's midpoint. `TapToPickMap` draws one
  /// passage's solved line at a time (the caller's currently selected
  /// segment), so one stage is enough — this is not a per-vertex styling API,
  /// which the widget's flat [LatLonPoint] list has no hook for.
  final String? polylineArcStage;

  /// #322 — off-route node → nearest-point-on-line connectors, drawn muted and
  /// dashed beneath the markers.
  final List<MapLeaderLine> leaderLines;

  /// #324 — an alternate path being drawn, or one being inspected. Dashed and
  /// thinner than [polyline]: it is a second path on the passage, and an
  /// Author-drawn one, so it must never read with a solved line's authority.
  final List<LatLonPoint> draftLine;

  /// #344 — the passage's *saved* alternates, drawn muted and dashed beneath
  /// [draftLine]. Before this an alternate vanished from the map the moment it
  /// was created, which made `Move on the map` unusable by construction: an
  /// Author cannot move a fork they cannot see. Muted rather than warning-
  /// coloured so the one being drawn or moved still reads as the one in hand.
  final List<List<LatLonPoint>> alternateLines;

  /// #324 — the stretch of [polyline] an alternate stands in for, drawn as a
  /// wide translucent casing under the route. What is being replaced is half
  /// of what a divergence means, and it is not inferable from the new path
  /// alone.
  final List<LatLonPoint> replacedStretch;

  /// #324 — caller-drawn marks (an alternate's fork and rejoin), above the
  /// lines and below nothing.
  final List<MapAnnotation> annotations;

  /// #410 — the trip's promoted anchors, each drawn once at its own
  /// coordinate. Before this `Trip.anchors` reached cards, dropdowns and
  /// lookups but never a map: promotion (FR106/FR110's "editorial moment")
  /// changed nothing the Author could see on the surface they look at most.
  /// An area anchor is marked at its representative point and its boundary
  /// drawn by [AnchorAreaLayer] (#484).
  final List<MapAnchorPoint> anchors;

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
    final basemapStyle = ref.watch(settingsProvider).basemapStyle;
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
      future: MapTileAssets.theme(resolveBasemapStyleName(isDark, basemapStyle),
          labelScale: labelScale),
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
                // #484 — area anchors' boundaries, under every line: a route
                // through a district is drawn over the district, not under it.
                if (widget.anchors.any((a) => a.rings != null))
                  AnchorAreaLayer(anchors: widget.anchors),
                // #324 — the replaced stretch goes under the route so the
                // route still reads as the route; the casing widens it rather
                // than recolouring it.
                if (widget.replacedStretch.length >= 2)
                  PolylineLayer(polylines: [
                    Polyline(
                      points: [
                        for (final p in widget.replacedStretch) ll.LatLng(p[1], p[0]),
                      ],
                      color: c.warning.withValues(alpha: 0.35),
                      strokeWidth: 12,
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
                // FR38 / O6, issue #392 — the drawn passage's own arc stage,
                // the "stretches of route" half of the AC that never reached
                // the map before this: a badge at the line's midpoint, the
                // same mark a carrying node gets below.
                if (widget.polylineArcStage != null && widget.polyline.length >= 2)
                  MarkerLayer(markers: [
                    Marker(
                      point: () {
                        final mid = widget.polyline[(widget.polyline.length - 1) ~/ 2];
                        return ll.LatLng(mid[1], mid[0]);
                      }(),
                      width: 22,
                      height: 22,
                      child: ArcStageBadge(widget.polylineArcStage!, size: 20),
                    ),
                  ]),
                // #344 — every other alternate on this passage, so the day's
                // divergences are visible while one of them is being worked on.
                if (widget.alternateLines.isNotEmpty)
                  PolylineLayer(polylines: [
                    for (final line in widget.alternateLines)
                      if (line.length >= 2)
                        Polyline(
                          points: [for (final p in line) ll.LatLng(p[1], p[0])],
                          color: c.textMuted,
                          strokeWidth: 2.5,
                          pattern: StrokePattern.dashed(segments: const [8.0, 6.0]),
                        ),
                  ]),
                // #324 — the alternate's own path: dashed, thinner, so a line
                // the Author drew never carries a solved line's authority.
                if (widget.draftLine.length >= 2)
                  PolylineLayer(polylines: [
                    Polyline(
                      points: [for (final p in widget.draftLine) ll.LatLng(p[1], p[0])],
                      color: c.warning,
                      strokeWidth: 3,
                      pattern: StrokePattern.dashed(segments: const [10.0, 6.0]),
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
                // #410 — promoted anchors, under the node markers and the
                // in-hand annotations: canon on the map, but not what is
                // being edited on this surface.
                if (widget.anchors.isNotEmpty)
                  MarkerLayer(markers: [
                    for (final a in widget.anchors)
                      Marker(
                        point: ll.LatLng(a.coord[1], a.coord[0]),
                        width: 30,
                        height: 30,
                        child: Tooltip(
                          message: a.label,
                          child: AnchorMarker(mark: a.mark),
                        ),
                      ),
                  ]),
                MarkerLayer(markers: [
                  for (final p in widget.points)
                    if (_sameCoord(p.coord, widget.focusCoord))
                      Marker(
                        point: ll.LatLng(p.coord[1], p.coord[0]),
                        width: p.arcStage == null ? 44 : 50,
                        height: p.arcStage == null ? 44 : 50,
                        child: p.arcStage == null
                            ? _HighlightedMarker(role: p.role, halo: c.primary)
                            : _WithArcBadge(
                                arcStage: p.arcStage!,
                                child: _HighlightedMarker(role: p.role, halo: c.primary),
                              ),
                      )
                    else
                      Marker(
                        point: ll.LatLng(p.coord[1], p.coord[0]),
                        width: p.arcStage == null ? 28 : 34,
                        height: p.arcStage == null ? 28 : 34,
                        child: p.arcStage == null
                            ? NodeMarker(p.role)
                            : _WithArcBadge(
                                arcStage: p.arcStage!,
                                child: NodeMarker(p.role),
                              ),
                      ),
                  // #324 — fork and rejoin marks sit above the node markers:
                  // while a divergence is being drawn they are what the
                  // Author is working on.
                  for (final a in widget.annotations)
                    Marker(
                      point: ll.LatLng(a.coord[1], a.coord[0]),
                      width: 30,
                      height: 30,
                      child: a.marker,
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

/// FR38 / O6, issue #392 — [child] (a [NodeMarker] or [_HighlightedMarker])
/// centred in the box, with an [ArcStageBadge] tucked in the bottom-right
/// corner. A corner tag rather than a halo: arc is an attribute of the point,
/// and the point's own role marker has to keep reading as itself.
class _WithArcBadge extends StatelessWidget {
  const _WithArcBadge({required this.arcStage, required this.child});

  final String arcStage;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: Center(child: child)),
        Positioned(
          right: 0,
          bottom: 0,
          child: ArcStageBadge(arcStage, size: 14),
        ),
      ],
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
