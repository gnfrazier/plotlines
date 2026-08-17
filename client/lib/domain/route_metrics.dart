/// `$defs/route_metrics`, `$defs/elevation`, `$defs/roll_up`.
///
/// **Schema/payload.py disagreement (flagged per D28 — schema wins):** the schema's
/// `route_metrics` and `elevation` $defs have no `required` array, so every field —
/// including `distance_m`/`climb_m`/`descent_m` and `ascent_m`/`descent_m` — is
/// schema-optional. `plotlines_core.trips.payload.RouteMetrics`/`Elevation` default
/// those specific fields to `0.0` and always emit them (no `None` check in
/// `to_dict`), which is compatible with the schema but stricter than it. This file
/// follows the schema: those fields are nullable here and omitted, not zero-filled,
/// when absent.
library;

import 'json_utils.dart';

/// What the route actually IS, as opposed to what was asked for.
class RouteMetrics {
  RouteMetrics({
    this.distanceM,
    this.climbM,
    this.descentM,
    this.traffic,
    this.unpavedFrac,
    this.scenicFrac,
    this.maxGrade,
    this.overlapFrac,
    this.overlapNearFrac,
    this.overlapFarFrac,
    this.edgeCount,
    this.movingTimeS,
    this.elapsedTimeS,
    this.paceSource,
  });

  final double? distanceM;
  final double? climbM;
  final double? descentM;
  final double? traffic;
  final double? unpavedFrac;
  final double? scenicFrac;
  final double? maxGrade;
  final double? overlapFrac;

  /// SPIKE-01's lollipop split: road ridden twice inside an Author-designated
  /// point's locality vs. ridden twice out in the corridor. One number cannot tell
  /// them apart, hence the near/far split alongside plain [overlapFrac].
  final double? overlapNearFrac;
  final double? overlapFarFrac;
  final int? edgeCount;
  final double? movingTimeS;
  final double? elapsedTimeS;
  final String? paceSource;

  factory RouteMetrics.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'route_metrics');
    final m = RouteMetrics(
      distanceM: f.takeNum('distance_m'),
      climbM: f.takeNum('climb_m'),
      descentM: f.takeNum('descent_m'),
      traffic: f.takeNum('traffic'),
      unpavedFrac: f.takeNum('unpaved_frac'),
      scenicFrac: f.takeNum('scenic_frac'),
      maxGrade: f.takeNum('max_grade'),
      overlapFrac: f.takeNum('overlap_frac'),
      overlapNearFrac: f.takeNum('overlap_near_frac'),
      overlapFarFrac: f.takeNum('overlap_far_frac'),
      edgeCount: f.takeInt('edge_count'),
      movingTimeS: f.takeNum('moving_time_s'),
      elapsedTimeS: f.takeNum('elapsed_time_s'),
      paceSource: f.takeString('pace_source'),
    );
    f.done();
    return m;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'distance_m': distanceM == null ? null : finite(distanceM!, 'route_metrics.distance_m'),
        'climb_m': climbM == null ? null : finite(climbM!, 'route_metrics.climb_m'),
        'descent_m': descentM == null ? null : finite(descentM!, 'route_metrics.descent_m'),
        'traffic': traffic == null ? null : finite(traffic!, 'route_metrics.traffic'),
        'unpaved_frac':
            unpavedFrac == null ? null : finite(unpavedFrac!, 'route_metrics.unpaved_frac'),
        'scenic_frac':
            scenicFrac == null ? null : finite(scenicFrac!, 'route_metrics.scenic_frac'),
        'max_grade': maxGrade == null ? null : finite(maxGrade!, 'route_metrics.max_grade'),
        'overlap_frac':
            overlapFrac == null ? null : finite(overlapFrac!, 'route_metrics.overlap_frac'),
        'overlap_near_frac': overlapNearFrac == null
            ? null
            : finite(overlapNearFrac!, 'route_metrics.overlap_near_frac'),
        'overlap_far_frac': overlapFarFrac == null
            ? null
            : finite(overlapFarFrac!, 'route_metrics.overlap_far_frac'),
        'edge_count': edgeCount,
        'moving_time_s':
            movingTimeS == null ? null : finite(movingTimeS!, 'route_metrics.moving_time_s'),
        'elapsed_time_s':
            elapsedTimeS == null ? null : finite(elapsedTimeS!, 'route_metrics.elapsed_time_s'),
        'pace_source': paceSource,
      });
}

/// FR89 — enrichment output. A void reads `0.0` and is never an error (FR88);
/// `voidSamples` is what tells a flat profile apart from missing raster.
class Elevation {
  Elevation({
    this.ascentM,
    this.descentM,
    this.minM,
    this.maxM,
    this.samples = const [],
    this.voidSamples,
    this.source,
  });

  final double? ascentM;
  final double? descentM;
  final double? minM;
  final double? maxM;

  /// Per-vertex elevation, index-aligned with the segment geometry's coordinates.
  final List<double> samples;
  final int? voidSamples;
  final String? source;

  factory Elevation.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'elevation');
    final rawSamples = f.take('samples');
    final e = Elevation(
      ascentM: f.takeNum('ascent_m'),
      descentM: f.takeNum('descent_m'),
      minM: f.takeNum('min_m'),
      maxM: f.takeNum('max_m'),
      samples: rawSamples == null
          ? const []
          : (rawSamples as List).map((v) => (v as num).toDouble()).toList(),
      voidSamples: f.takeInt('void_samples'),
      source: f.takeString('source'),
    );
    f.done();
    return e;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'ascent_m': ascentM == null ? null : finite(ascentM!, 'elevation.ascent_m'),
        'descent_m': descentM == null ? null : finite(descentM!, 'elevation.descent_m'),
        'min_m': minM == null ? null : finite(minM!, 'elevation.min_m'),
        'max_m': maxM == null ? null : finite(maxM!, 'elevation.max_m'),
        'samples': samples.isEmpty
            ? null
            : samples.map((v) => finite(v, 'elevation.samples')).toList(),
        'void_samples': voidSamples,
        'source': source,
      });
}

/// C3 — which per-mode day limit a day exceeded, and by how much.
class LimitBreach {
  LimitBreach({
    required this.mode,
    required this.bound,
    required this.limitM,
    required this.realisedM,
    this.dayId,
  });

  final String mode;
  final String bound;
  final double limitM;
  final double realisedM;
  final String? dayId;

  factory LimitBreach.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'limit_breach');
    final b = LimitBreach(
      mode: f.takeString('mode')!,
      bound: f.takeString('bound')!,
      limitM: f.takeNum('limit_m')!,
      realisedM: f.takeNum('realised_m')!,
      dayId: f.takeString('day_id'),
    );
    f.done();
    return b;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'mode': mode,
        'bound': bound,
        'limit_m': finite(limitM, 'limit_breach.limit_m'),
        'realised_m': finite(realisedM, 'limit_breach.realised_m'),
        'day_id': dayId,
      });
}

/// FR31 / D1 — totals by mode plus an overall. Present at day and trip level so a
/// dashboard reads them rather than recomputing on every edit.
class RollUp {
  RollUp({this.total, this.byMode = const {}, this.limitBreaches = const []});

  final RouteMetrics? total;
  final Map<String, RouteMetrics> byMode;
  final List<LimitBreach> limitBreaches;

  factory RollUp.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'roll_up');
    final total = f.takeObject('total', RouteMetrics.fromJson);
    final rawByMode = f.take('by_mode');
    final byMode = rawByMode == null
        ? <String, RouteMetrics>{}
        : (rawByMode as Map).map((k, v) => MapEntry(
            k as String, RouteMetrics.fromJson(Map<String, dynamic>.from(v as Map))));
    final breaches = f.takeList('limit_breaches', LimitBreach.fromJson);
    f.done();
    return RollUp(total: total, byMode: byMode, limitBreaches: breaches);
  }

  Map<String, dynamic> toJson() => pruneJson({
        'total': total?.toJson(),
        'by_mode': byMode.isEmpty ? null : byMode.map((k, v) => MapEntry(k, v.toJson())),
        'limit_breaches': limitBreaches.isEmpty
            ? null
            : limitBreaches.map((b) => b.toJson()).toList(),
      });
}
