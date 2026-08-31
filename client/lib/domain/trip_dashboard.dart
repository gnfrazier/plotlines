/// The live planning dashboard — the client half of Story D1 (FR31) with the
/// FR16 time model it leans on, issue #213.
///
/// `plotlines_core.trips.dashboard.build_dashboard` is the authority: the three
/// roll-up scopes (active passage / day total / trip total, each by mode) plus
/// the FR16 moving-time / elapsed-time / ETA model, computed once. `/trips/split`
/// now returns it as `dashboard` ([TripDashboard.fromJson]) so a sidecar and a
/// hosted server hand the client identical numbers.
///
/// The client also assembles trips locally (`current_trip_provider`) between
/// saves without round-tripping `/trips/split`, so [TripDashboard.fromTrip]
/// mirrors the distance/elevation roll-up and the system-default (or
/// caller-supplied) pace over the domain payload — the same "something to show
/// while the Author is still dragging things around" role [rollUpTrip] fills for
/// the plain sums. It is a mirror, not a second source of truth:
///
///  * it recomputes distance / climb / descent per mode and overall, and fills
///    in `movingTimeS` from [modeBaseSpeedKmh] (or a `speeds` override), exactly
///    as `dashboard._timed_rollup` does;
///  * it does **not** reproduce the length-weighted blend of the fractional
///    terms, C3's limit-breach detection, station/hold durations, or ETA — those
///    need the server path (holds and start times are not carried on the trip
///    payload today). `holdS` / `eta` from a local mirror are always null.
///
/// A drift between the arithmetic here and `dashboard.py` is a bug in this file.
library;

import 'route_metrics.dart';
import 'segment.dart';
import 'trip.dart';

/// FR16 / SPIKE-05 system-default base speeds (km/h), copied from
/// `plotlines_core.multimodal.modes.TRAVERSAL_MODES`. A mode absent here (the
/// `transit` note leg) carries an authored schedule, not a computed pace, and
/// must never be handed a fabricated one — `movingTimeSeconds` returns null.
const Map<String, double> modeBaseSpeedKmh = {
  'cycling': 15.0,
  'hiking': 5.0,
  'paddling': 4.0,
  'cross_country_skiing': 8.0,
  'packrafting': 4.5,
  'riverboarding': 4.0,
  'mountain_biking': 12.0,
  'driving': 60.0,
};

/// `dashboard.PACE_SYSTEM_DEFAULT` / `PACE_CUSTOM` — FR16's three pace choices
/// collapse, for the dashboard, to "the Author gave me numbers" vs "I used the
/// system default".
const String paceSystemDefault = 'system_default';
const String paceCustom = 'custom';

const double _secondsPerHour = 3600.0;

/// Seconds to cover [distanceM] at [mode]'s pace — `dashboard.moving_time_s`.
/// A [speeds] entry (km/h) wins; otherwise [mode]'s system default. Null when
/// neither exists, or the pace is non-positive.
double? movingTimeSeconds(double distanceM, String mode, [Map<String, double>? speeds]) {
  final kmh = speeds?[mode] ?? modeBaseSpeedKmh[mode];
  if (kmh == null || kmh <= 0) return null;
  return distanceM / (kmh * 1000.0 / _secondsPerHour);
}

/// The active passage's own readout — `dashboard.PassageLine`.
class DashboardPassageLine {
  DashboardPassageLine({
    required this.segmentId,
    required this.mode,
    this.title,
    this.dayIndex,
    required this.metrics,
  });

  final String segmentId;
  final String mode;
  final String? title;
  final int? dayIndex;
  final RouteMetrics metrics;

  factory DashboardPassageLine.fromJson(Map<String, dynamic> json) => DashboardPassageLine(
        segmentId: json['segment_id'] as String,
        mode: json['mode'] as String,
        title: json['title'] as String?,
        dayIndex: (json['day_index'] as num?)?.toInt(),
        metrics: RouteMetrics.fromJson(Map<String, dynamic>.from(json['metrics'] as Map)),
      );
}

/// One day's totals and by-mode split — `dashboard.DayLine`. [holdS] and [eta]
/// are only ever set from the server path.
class DashboardDayLine {
  DashboardDayLine({
    required this.dayId,
    required this.index,
    required this.kind,
    required this.metrics,
    this.holdS,
    this.eta,
  });

  final String dayId;
  final int index;
  final String kind;
  final RollUp metrics;
  final double? holdS;

  /// A UTC `…Z` stamp — day start plus elapsed time. Null unless a start time
  /// was supplied to `build_dashboard` server-side.
  final String? eta;

  factory DashboardDayLine.fromJson(Map<String, dynamic> json) => DashboardDayLine(
        dayId: json['day_id'] as String,
        index: (json['index'] as num).toInt(),
        kind: json['kind'] as String,
        metrics: RollUp.fromJson(Map<String, dynamic>.from(json['metrics'] as Map)),
        holdS: (json['hold_s'] as num?)?.toDouble(),
        eta: json['eta'] as String?,
      );
}

/// FR31 — the whole panel as one plain-data document a UI binds to.
class TripDashboard {
  TripDashboard({
    required this.tripId,
    required this.tripTitle,
    required this.paceSource,
    this.activePassage,
    this.days = const [],
    required this.tripTotal,
    this.tripHoldS,
    this.tripEta,
    this.generatedAt,
  });

  final String tripId;
  final String tripTitle;

  /// [paceSystemDefault] or [paceCustom].
  final String paceSource;
  final DashboardPassageLine? activePassage;
  final List<DashboardDayLine> days;
  final RollUp tripTotal;
  final double? tripHoldS;

  /// A UTC `…Z` stamp. Null unless a trip start time was supplied server-side.
  final String? tripEta;
  final String? generatedAt;

  /// Whether the FR16 time model is populated — true once any scope carries a
  /// moving time (a trip made only of `transit` note legs never will).
  bool get hasTimeModel =>
      tripTotal.total?.movingTimeS != null ||
      days.any((d) => d.metrics.total?.movingTimeS != null) ||
      activePassage?.metrics.movingTimeS != null;

  factory TripDashboard.fromJson(Map<String, dynamic> json) {
    final rawActive = json['active_passage'];
    return TripDashboard(
      tripId: json['trip_id'] as String,
      tripTitle: json['trip_title'] as String,
      paceSource: json['pace_source'] as String? ?? paceSystemDefault,
      activePassage: rawActive == null
          ? null
          : DashboardPassageLine.fromJson(Map<String, dynamic>.from(rawActive as Map)),
      days: ((json['days'] as List?) ?? const [])
          .map((d) => DashboardDayLine.fromJson(Map<String, dynamic>.from(d as Map)))
          .toList(),
      tripTotal: RollUp.fromJson(Map<String, dynamic>.from(json['trip_total'] as Map)),
      tripHoldS: (json['trip_hold_s'] as num?)?.toDouble(),
      tripEta: json['trip_eta'] as String?,
      generatedAt: json['generated_at'] as String?,
    );
  }

  /// The distance/elevation roll-up and the (system-default or [speeds]-scaled)
  /// pace over a locally-assembled [trip], for immediate feedback between saves.
  /// See the library doc for what this deliberately does not reproduce.
  /// [activeSegmentId], when it names a segment in [trip], fills [activePassage].
  factory TripDashboard.fromTrip(
    Trip trip, {
    String? activeSegmentId,
    Map<String, double>? speeds,
  }) {
    final paceSource = (speeds != null && speeds.isNotEmpty) ? paceCustom : paceSystemDefault;

    final days = <DashboardDayLine>[];
    for (final day in trip.days) {
      days.add(DashboardDayLine(
        dayId: day.id,
        index: day.index,
        kind: day.kind,
        metrics: _timedRollUp(day.segments, speeds, paceSource),
      ));
    }

    final allSegments = [for (final day in trip.days) ...day.segments];
    final tripTotal = _timedRollUp(allSegments, speeds, paceSource);

    DashboardPassageLine? active;
    if (activeSegmentId != null) {
      for (final day in trip.days) {
        for (final s in day.segments) {
          if (s.id != activeSegmentId) continue;
          final distanceM = s.metrics?.distanceM ?? 0.0;
          final secs = movingTimeSeconds(distanceM, s.mode, speeds);
          active = DashboardPassageLine(
            segmentId: s.id,
            mode: s.mode,
            title: s.title,
            dayIndex: day.index,
            metrics: RouteMetrics(
              distanceM: s.metrics?.distanceM,
              climbM: s.metrics?.climbM,
              descentM: s.metrics?.descentM,
              movingTimeS: secs == null ? null : _round1(secs),
              elapsedTimeS: secs == null ? null : _round1(secs),
              paceSource: secs == null ? null : paceSource,
            ),
          );
        }
      }
    }

    return TripDashboard(
      tripId: trip.id,
      tripTitle: trip.title,
      paceSource: paceSource,
      activePassage: active,
      days: days,
      tripTotal: tripTotal,
    );
  }
}

/// `dashboard.roll_up` + `_timed_rollup` for the fields a local mirror carries:
/// distance / climb / descent summed per mode and overall, `movingTimeS` filled
/// in per mode, and the scope total's `movingTimeS` / `elapsedTimeS` left null
/// if any contributing mode has no pace (matching `_timed_rollup`).
RollUp _timedRollUp(List<Segment> segments, Map<String, double>? speeds, String paceSource) {
  final byModeDist = <String, ({double dist, double climb, double descent})>{};
  var totalDist = 0.0, totalClimb = 0.0, totalDescent = 0.0;
  var sawSegment = false;
  for (final s in segments) {
    final m = s.metrics;
    if (m == null) continue;
    sawSegment = true;
    final d = m.distanceM ?? 0.0, c = m.climbM ?? 0.0, de = m.descentM ?? 0.0;
    totalDist += d;
    totalClimb += c;
    totalDescent += de;
    final prev = byModeDist[s.mode];
    byModeDist[s.mode] = prev == null
        ? (dist: d, climb: c, descent: de)
        : (dist: prev.dist + d, climb: prev.climb + c, descent: prev.descent + de);
  }
  if (!sawSegment) return RollUp();

  final byMode = <String, RouteMetrics>{};
  var totalMoving = 0.0;
  var aModeHasNoPace = false;
  byModeDist.forEach((mode, agg) {
    final secs = movingTimeSeconds(agg.dist, mode, speeds);
    if (secs == null) {
      aModeHasNoPace = true;
      byMode[mode] =
          RouteMetrics(distanceM: agg.dist, climbM: agg.climb, descentM: agg.descent);
    } else {
      totalMoving += secs;
      byMode[mode] = RouteMetrics(
        distanceM: agg.dist,
        climbM: agg.climb,
        descentM: agg.descent,
        movingTimeS: _round1(secs),
        paceSource: paceSource,
      );
    }
  });

  final total = RouteMetrics(
    distanceM: totalDist,
    climbM: totalClimb,
    descentM: totalDescent,
    movingTimeS: aModeHasNoPace ? null : _round1(totalMoving),
    elapsedTimeS: aModeHasNoPace ? null : _round1(totalMoving),
    paceSource: aModeHasNoPace ? null : paceSource,
  );
  return RollUp(total: total, byMode: byMode);
}

double _round1(double v) => (v * 10).roundToDouble() / 10;
