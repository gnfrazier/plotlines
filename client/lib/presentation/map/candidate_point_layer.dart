// Issue #478 (FR99, ARCH Q15 / SPIKE-G) — the candidate *points* on
// `CandidateMap`, rendered the way SPIKE-G decided rather than one widget
// marker per candidate. The spike modelled that naive layer at 22.9 ms (`avl`,
// 715) / 33.5 ms (`sgv`, 1,208) p95 at the trip overview on a GPU desktop,
// over the 16.7 ms budget, and every live widget is re-laid-out on a
// selection. Three tiers, all decided per frame against the camera
// (`planCandidatePoints`, pure):
//
//  1. **Top-K by salience → widget markers.** The in-viewport candidates, most
//     notable first; the first [CandidatePointLayer.defaultMaxMarkers] (K≈300,
//     SPIKE-G's `regions.cut_k` on GPU) are `CandidateMarker`s — hit-testable,
//     tooltipped, promotable straight from the map (FR99). Salience stays
//     visible by construction: the widgets *are* the notable ones.
//  2. **The rest → a dot tail** on one `CustomPainter`, positioned and styled by
//     salience (size + opacity), drawn in a handful of batched `drawPoints`
//     calls and never individually hit-tested — a tap near a dot resolves by a
//     nearest-point scan instead. Zooming in promotes dots to markers as the
//     viewport's in-view count falls under K.
//  3. **Grid clustering as the backstop**, only below the trip-overview zoom
//     (the trip extent covers under half the viewport on both axes) or above
//     the ~2,800 in-viewport density ceiling. A cluster aggregates salience
//     into a count and makes a tap ambiguous (SPIKE-G §2), so it is never the
//     primary mode: a one-member cell still draws its full marker, and a tap
//     on a count glyph zooms to its members rather than guessing one.
//
// The numbers are SPIKE-G's calibrated model, not a measurement —
// `spikes/SPIKE-G/HARNESS.md` is the run that replaces the widget-marker
// frame cost K pivots on. Change them there first.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:plotlines_ui/plotlines_ui.dart';

import '../../domain/candidate.dart';

/// Candidates ordered most notable first, ties broken by id so a re-render
/// never reshuffles which of two equal candidates keeps its marker.
List<Candidate> candidatesBySalience(List<Candidate> candidates) => [...candidates]
  ..sort((x, y) {
    final s = y.salience.compareTo(x.salience);
    return s != 0 ? s : x.id.compareTo(y.id);
  });

/// One in-viewport candidate drawn as a dot, at its screen offset (the
/// layer's own non-rotated coordinate space, `MapCamera.getOffsetFromOrigin`).
class CandidateDot {
  const CandidateDot(this.candidate, this.offset);

  final Candidate candidate;
  final Offset offset;
}

/// Two or more candidates sharing one grid cell, drawn as a count glyph at
/// their mean position. [members] keeps the salience order it was planned in.
class CandidateCluster {
  const CandidateCluster({required this.members, required this.point});

  final List<Candidate> members;
  final ll.LatLng point;

  double get topSalience => members.first.salience;

  LatLngBounds get bounds =>
      LatLngBounds.fromPoints([for (final c in members) ll.LatLng(c.coord[1], c.coord[0])]);
}

/// What the layer draws for one camera. [markers] is in salience order (most
/// notable first); [inViewport] counts every candidate the viewport held,
/// whichever tier it landed in.
class CandidatePointPlan {
  const CandidatePointPlan({
    required this.markers,
    required this.dots,
    required this.clusters,
    required this.inViewport,
    required this.clustered,
  });

  final List<Candidate> markers;
  final List<CandidateDot> dots;
  final List<CandidateCluster> clusters;
  final int inViewport;

  /// `true` when the grid-cluster backstop engaged for this camera.
  final bool clustered;
}

/// Whether the camera is below the trip-overview zoom: the trip extent,
/// projected, covers less than half the viewport on both axes — i.e. the
/// camera is at least one zoom level further out than the fit that shows the
/// whole trip. `null` [extentPx] (no extent known) is never below it.
bool isBelowOverviewZoom(Rect? extentPx, Size viewport, {double fraction = 0.5}) {
  if (extentPx == null) return false;
  return extentPx.width < viewport.width * fraction &&
      extentPx.height < viewport.height * fraction;
}

/// Decide which tier each candidate lands in for the current camera.
///
/// [bySalience] must already be ordered by [candidatesBySalience] (the layer
/// sorts once per candidate list, not per frame). [project] maps lon/lat to
/// *world* pixels at the camera's zoom (`MapCamera.projectAtZoom`) and
/// [origin] is the camera's `pixelOrigin`, so `project(p) - origin` is the
/// screen offset — cells are keyed on world pixels so a pan does not
/// reshuffle cluster membership. A candidate is in the viewport when its
/// screen offset falls within [viewport] grown by [marginPx] (a marker whose
/// centre is just off-screen still shows half of itself).
CandidatePointPlan planCandidatePoints(
  List<Candidate> bySalience, {
  required Offset Function(ll.LatLng) project,
  required Offset origin,
  required Size viewport,
  bool belowOverview = false,
  int maxMarkers = CandidatePointLayer.defaultMaxMarkers,
  int densityCeiling = CandidatePointLayer.defaultDensityCeiling,
  double cellPx = CandidatePointLayer.defaultClusterCellPx,
  double marginPx = CandidatePointLayer.defaultMarginPx,
}) {
  final view = (Offset.zero & viewport).inflate(marginPx);
  final visible = <Candidate>[];
  final world = <Offset>[];
  for (final c in bySalience) {
    final w = project(ll.LatLng(c.coord[1], c.coord[0]));
    if (!view.contains(w - origin)) continue;
    visible.add(c);
    world.add(w);
  }

  if (belowOverview || visible.length > densityCeiling) {
    // Insertion-ordered map: cells appear in the order of their most
    // salient member, and each cell's members stay in salience order.
    final cells = <(int, int), List<int>>{};
    for (var i = 0; i < visible.length; i++) {
      final key = ((world[i].dx / cellPx).floor(), (world[i].dy / cellPx).floor());
      (cells[key] ??= []).add(i);
    }
    final markers = <Candidate>[];
    final clusters = <CandidateCluster>[];
    for (final members in cells.values) {
      if (members.length == 1) {
        markers.add(visible[members.single]);
        continue;
      }
      var lat = 0.0, lon = 0.0;
      for (final i in members) {
        lat += visible[i].coord[1];
        lon += visible[i].coord[0];
      }
      clusters.add(CandidateCluster(
        members: [for (final i in members) visible[i]],
        point: ll.LatLng(lat / members.length, lon / members.length),
      ));
    }
    return CandidatePointPlan(
        markers: markers, dots: const [], clusters: clusters,
        inViewport: visible.length, clustered: true);
  }

  final k = math.min(maxMarkers, visible.length);
  return CandidatePointPlan(
    markers: visible.sublist(0, k),
    dots: [for (var i = k; i < visible.length; i++) CandidateDot(visible[i], world[i] - origin)],
    clusters: const [],
    inViewport: visible.length,
    clustered: false,
  );
}

/// The dot nearest [position] within [radiusPx], or `null`. A linear scan:
/// the tail is at most the in-viewport count less K, and it runs once per
/// tap, not per frame.
CandidateDot? nearestDot(List<CandidateDot> dots, Offset position,
    {double radiusPx = CandidatePointLayer.defaultDotHitRadiusPx}) {
  CandidateDot? best;
  var bestD2 = radiusPx * radiusPx;
  for (final d in dots) {
    final d2 = (d.offset - position).distanceSquared;
    if (d2 <= bestD2) {
      best = d;
      bestD2 = d2;
    }
  }
  return best;
}

/// A dot's diameter, px: 3 px for the least notable, 7 px for the most —
/// always smaller than the smallest `CandidateMarker` (55% of 22 px), so a
/// dot never reads as a marker that failed to draw its mark.
double dotDiameter(double salience) => 3 + 4 * salience;

/// A dot carries `CandidateMarker`'s fill-opacity ramp (`0.25 + 0.55·s`).
double dotOpacity(double salience) => 0.25 + 0.55 * salience;

/// Salience is drawn in this many steps so the tail batches into a handful
/// of `drawPoints` calls instead of one `drawCircle` per candidate.
const dotSalienceSteps = 5;

/// A `FlutterMap` child: the candidate points for the current camera, in the
/// three tiers above.
class CandidatePointLayer extends StatefulWidget {
  const CandidatePointLayer({
    super.key,
    required this.candidates,
    this.onCandidateTap,
    this.overviewExtent,
    this.maxMarkers = defaultMaxMarkers,
    this.densityCeiling = defaultDensityCeiling,
  });

  /// SPIKE-G's derived K on a GPU desktop (`regions.cut_k("windows-gpu")`):
  /// warm-frame headroom less the 3 ms polygon/dot allowance, over the
  /// per-marker frame cost. Mirrored by `CandidateGeometryLayer`'s outline cap.
  static const defaultMaxMarkers = 300;

  /// SPIKE-G's GPU display-density ceiling: past ~2,800 candidates in one
  /// viewport the p95 interaction frame tips over 16.7 ms even salience-gated.
  /// The shipped ruleset's worst trip bbox is 1,208 (`sgv`), so this is the
  /// tripwire for a ruleset regression, not a routine mode.
  static const defaultDensityCeiling = 2800;

  /// SPIKE-G's cluster-grid cell (`strategies.cluster_grid`, 64 px).
  static const defaultClusterCellPx = 64.0;

  /// Half the 32 px marker slot.
  static const defaultMarginPx = 16.0;

  /// Half the 32 px marker slot again: a tap within a marker's reach of a dot
  /// selects it, the same reach a marker of its own would have had.
  static const defaultDotHitRadiusPx = 16.0;

  final List<Candidate> candidates;
  final void Function(Candidate)? onCandidateTap;

  /// The trip extent the overview zoom is judged against — the trip bbox.
  /// `null` (a map with no trip extent, e.g. the rest-day picker) never
  /// clusters for zoom, only above the density ceiling: a handful of
  /// candidates' own bounds say nothing about where the trip overview is,
  /// and judging by them clustered three readable pins at z13.
  final LatLngBounds? overviewExtent;
  final int maxMarkers;
  final int densityCeiling;

  @override
  State<CandidatePointLayer> createState() => _CandidatePointLayerState();
}

class _CandidatePointLayerState extends State<CandidatePointLayer> {
  List<Candidate>? _source;
  List<Candidate> _sorted = const [];

  /// Re-sort only when the list's contents changed: `CandidateMap` rebuilds
  /// on every map event and hands over a freshly filtered list each time.
  void _resort() {
    final next = widget.candidates;
    final prev = _source;
    if (prev != null &&
        (identical(prev, next) ||
            (prev.length == next.length &&
                Iterable.generate(next.length).every((i) => identical(prev[i], next[i]))))) {
      return;
    }
    _source = next;
    _sorted = candidatesBySalience(next);
  }

  Rect? _extentPx(MapCamera camera) {
    final extent = widget.overviewExtent;
    if (extent == null) return null;
    return Rect.fromPoints(
        camera.projectAtZoom(extent.northWest), camera.projectAtZoom(extent.southEast));
  }

  void _zoomTo(BuildContext context, CandidateCluster cluster) {
    MapController.of(context).fitCamera(CameraFit.bounds(
      bounds: cluster.bounds,
      padding: const EdgeInsets.all(48),
      maxZoom: 18,
    ));
  }

  @override
  Widget build(BuildContext context) {
    _resort();
    if (_sorted.isEmpty) return const SizedBox.shrink();
    final camera = MapCamera.of(context);
    final c = PlotColors.of(context);
    final plan = planCandidatePoints(
      _sorted,
      project: (p) => camera.projectAtZoom(p),
      origin: camera.pixelOrigin,
      viewport: camera.size,
      belowOverview: isBelowOverviewZoom(_extentPx(camera), camera.size),
      maxMarkers: widget.maxMarkers,
      densityCeiling: widget.densityCeiling,
    );
    final onTap = widget.onCandidateTap;

    return Stack(fit: StackFit.expand, children: [
      if (plan.dots.isNotEmpty)
        MobileLayerTransformer(
          child: _DotTail(dots: plan.dots, color: c.primary, paper: c.surfaceCard, onTap: onTap),
        ),
      if (plan.clusters.isNotEmpty)
        MarkerLayer(markers: [
          for (final cluster in plan.clusters.reversed)
            Marker(
              point: cluster.point,
              width: 36,
              height: 36,
              alignment: Alignment.center,
              child: Builder(
                builder: (context) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _zoomTo(context, cluster),
                  child: Tooltip(
                    message: '${cluster.members.length} candidates — zoom in to pick one',
                    child: CandidateClusterGlyph(
                        count: cluster.members.length, topSalience: cluster.topSalience),
                  ),
                ),
              ),
            ),
        ]),
      // Least notable first, so the most notable paints on top of an overlap.
      if (plan.markers.isNotEmpty)
        MarkerLayer(markers: [
          for (final candidate in plan.markers.reversed)
            Marker(
              point: ll.LatLng(candidate.coord[1], candidate.coord[0]),
              width: 32,
              height: 32,
              alignment: Alignment.center,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap == null ? null : () => onTap(candidate),
                child: Tooltip(
                  message: candidate.title ??
                      '${candidate.layer} (${(candidate.salience * 100).round()}% salience)',
                  child: CandidateMarker(
                    salience: candidate.salience,
                    roleAffinity: candidateMarkerAffinity(candidate.roleAffinity),
                  ),
                ),
              ),
            ),
        ]),
    ]);
  }
}

/// A candidate's role affinity in `plotlines_ui`'s marker vocabulary.
CandidateRoleAffinity candidateMarkerAffinity(RoleAffinity affinity) => switch (affinity) {
      RoleAffinity.narrative => CandidateRoleAffinity.narrative,
      RoleAffinity.provision => CandidateRoleAffinity.provision,
      RoleAffinity.station => CandidateRoleAffinity.station,
    };

/// The dot tail: one paint pass, and a hit only where a dot is near enough to
/// resolve — everywhere else the tap falls through to the layers and map
/// below, exactly as if the layer were not there.
class _DotTail extends StatelessWidget {
  const _DotTail({required this.dots, required this.color, required this.paper, this.onTap});

  final List<CandidateDot> dots;
  final Color color;
  final Color paper;
  final void Function(Candidate)? onTap;

  @override
  Widget build(BuildContext context) {
    final paint = CustomPaint(
      painter: CandidateDotPainter(dots: dots, color: color, paper: paper, hitTestable: onTap != null),
      size: Size.infinite,
    );
    if (onTap == null) return paint;
    return GestureDetector(
      onTapUp: (details) {
        final hit = nearestDot(dots, details.localPosition);
        if (hit != null) onTap!(hit.candidate);
      },
      child: paint,
    );
  }
}

/// Paints [dots] batched by salience step: a paper casing under each so a dot
/// stays legible on any basemap, then the salience-scaled fill.
class CandidateDotPainter extends CustomPainter {
  CandidateDotPainter({
    required this.dots,
    required this.color,
    required this.paper,
    this.hitTestable = true,
  });

  final List<CandidateDot> dots;
  final Color color;
  final Color paper;
  final bool hitTestable;

  @override
  void paint(Canvas canvas, Size size) {
    final buckets = List.generate(dotSalienceSteps, (_) => <Offset>[]);
    for (final d in dots) {
      final step = (d.candidate.salience.clamp(0.0, 1.0) * (dotSalienceSteps - 1)).round();
      buckets[step].add(d.offset);
    }
    for (var step = 0; step < dotSalienceSteps; step++) {
      final points = buckets[step];
      if (points.isEmpty) continue;
      final s = step / (dotSalienceSteps - 1);
      final diameter = dotDiameter(s);
      canvas.drawPoints(
        ui.PointMode.points,
        points,
        Paint()
          ..color = paper.withValues(alpha: 0.9)
          ..strokeCap = StrokeCap.round
          ..strokeWidth = diameter + 2,
      );
      canvas.drawPoints(
        ui.PointMode.points,
        points,
        Paint()
          ..color = color.withValues(alpha: dotOpacity(s))
          ..strokeCap = StrokeCap.round
          ..strokeWidth = diameter,
      );
    }
  }

  @override
  bool? hitTest(Offset position) => hitTestable && nearestDot(dots, position) != null;

  @override
  bool shouldRepaint(CandidateDotPainter old) =>
      !identical(old.dots, dots) || old.color != color || old.paper != paper;
}

/// A grid cluster's glyph: a doubled ring (read as "several", and distinct
/// from a single candidate's ring-with-a-mark) around the member count in
/// mono. The ring's weight follows the most notable member, so a cell holding
/// a castle still reads heavier than a cell of boundary stones.
class CandidateClusterGlyph extends StatelessWidget {
  const CandidateClusterGlyph({super.key, required this.count, required this.topSalience});

  final int count;
  final double topSalience;

  @override
  Widget build(BuildContext context) {
    final c = PlotColors.of(context);
    return CustomPaint(
      painter: _ClusterPainter(salience: topSalience, color: c.primary, paper: c.surfaceCard),
      child: Center(
        child: Text(
          '$count',
          style: PlotTypography.data(c.textPrimary).copyWith(fontSize: 11, height: 1),
        ),
      ),
    );
  }
}

class _ClusterPainter extends CustomPainter {
  _ClusterPainter({required this.salience, required this.color, required this.paper});

  final double salience;
  final Color color;
  final Color paper;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    canvas.drawCircle(center, r - 1, Paint()..color = paper);
    canvas.drawCircle(
      center,
      r - 1,
      Paint()
        ..color = color.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    canvas.drawCircle(
      center,
      r - 5,
      Paint()
        ..color = color.withValues(alpha: dotOpacity(salience))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4 + 1.6 * salience,
    );
  }

  @override
  bool shouldRepaint(_ClusterPainter old) =>
      old.salience != salience || old.color != color || old.paper != paper;
}
