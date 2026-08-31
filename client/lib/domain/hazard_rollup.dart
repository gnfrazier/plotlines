/// The trip-wide hazard roll-up and the sync-open alert set — the client half
/// of Story C11 (FR27, FR115), issue #210.
///
/// `plotlines_core.trips.hazards` (`collect_hazards` / `sync_alerts`) is the
/// authority: **one** traversal of every hazard a trip carries, so a map, an
/// elevation profile, an itinerary, a cue sheet and the sync alert can never
/// disagree about what exists. `/trips/split` now returns it as `hazard_rollup`
/// ([HazardRollup.fromJson]).
///
/// The client also assembles trips locally (`current_trip_provider`) without
/// round-tripping `/trips/split`, so [HazardRollup.fromTrip] mirrors that same
/// traversal over the domain payload. It is a mirror, not a second source of
/// truth: the ordering rules here (reading order for the full list; severity
/// worst-first, then day, then distance-along, then title, then id for the sync
/// alerts) are copied from `hazards.py` and a drift between the two is a bug in
/// this file.
///
/// Nothing here is reveal-aware, by construction: a [Hazard] carries no reveal
/// field, so there is no policy to consult and no Author setting can hide one or
/// shrink this list (FR115).
library;

import 'day.dart';
import 'hazard.dart';
import 'json_utils.dart';
import 'trip.dart';

/// Severity ladder, worst last — the rank `hazards.py` sorts on (negated so the
/// worst sorts first).
const List<String> hazardSeverities = ['caution', 'high', 'mandatory_reroute'];

/// The severities that raise a distinct Character alert on sync (FR27). A
/// `caution` hazard still appears everywhere a hazard appears; it just does not
/// interrupt.
const Set<String> alertingSeverities = {'high', 'mandatory_reroute'};

/// Where a hazard is pinned. `anchor` whenever [Hazard.anchorId] is set;
/// otherwise a hazard in a segment's list is `passage` and one in a day's list
/// is `day`.
const List<String> hazardScopes = ['day', 'passage', 'anchor'];

/// One hazard on the trip, plus enough context to render or route to it —
/// `plotlines_core.trips.hazards.LocatedHazard`.
class LocatedHazard {
  LocatedHazard({
    required this.hazard,
    required this.scope,
    required this.dayIndex,
    required this.dayId,
    this.segmentId,
    this.anchorId,
    this.anchorTitle,
  });

  final Hazard hazard;

  /// One of [hazardScopes].
  final String scope;

  /// 1-based day the hazard sits on.
  final int dayIndex;
  final String dayId;

  /// Set for a `passage`-scope hazard (and for an `anchor`-scope hazard carried
  /// in a segment's list).
  final String? segmentId;
  final String? anchorId;

  /// Resolved against `Trip.anchors` when that anchor is present.
  final String? anchorTitle;

  /// FR27 — this hazard raises a distinct Character alert on sync.
  bool get isAlerting => alertingSeverities.contains(hazard.severity);

  factory LocatedHazard.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'located_hazard');
    final lh = LocatedHazard(
      hazard: Hazard.fromJson(Map<String, dynamic>.from(f.take('hazard') as Map)),
      scope: f.takeString('scope')!,
      dayIndex: f.takeInt('day_index')!,
      dayId: f.takeString('day_id')!,
      segmentId: f.takeString('segment_id'),
      anchorId: f.takeString('anchor_id'),
      anchorTitle: f.takeString('anchor_title'),
    );
    f.done();
    return lh;
  }
}

/// A high-severity hazard, flattened into the shape the client raises as the
/// distinct Character alert on sync (FR27) —
/// `plotlines_core.trips.hazards.SyncAlert`. Ordered worst-first by its
/// producer; nothing in it is reveal-gated (FR115).
class SyncAlert {
  SyncAlert({
    required this.hazardId,
    required this.severity,
    required this.dayIndex,
    required this.scope,
    this.title,
    this.safetyNote,
    this.requiredGear = const [],
    this.segmentId,
    this.anchorId,
    this.anchorTitle,
    this.distanceAlongM,
    this.coord,
  });

  final String hazardId;
  final String severity;
  final int dayIndex;
  final String scope;
  final String? title;
  final String? safetyNote;
  final List<String> requiredGear;
  final String? segmentId;
  final String? anchorId;
  final String? anchorTitle;
  final double? distanceAlongM;
  final Coord? coord;

  factory SyncAlert.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'sync_alert');
    final rawCoord = f.takeCoord('coord');
    final a = SyncAlert(
      hazardId: f.takeString('hazard_id')!,
      severity: f.takeString('severity')!,
      dayIndex: f.takeInt('day_index')!,
      scope: f.takeString('scope')!,
      title: f.takeString('title'),
      safetyNote: f.takeString('safety_note'),
      requiredGear: f.takeStrings('required_gear'),
      segmentId: f.takeString('segment_id'),
      anchorId: f.takeString('anchor_id'),
      anchorTitle: f.takeString('anchor_title'),
      distanceAlongM: f.takeNum('distance_along_m'),
      coord: rawCoord == null ? null : checkCoord(rawCoord, 'sync_alert.coord'),
    );
    f.done();
    return a;
  }

  SyncAlert._fromLocated(LocatedHazard lh)
      : hazardId = lh.hazard.id,
        severity = lh.hazard.severity,
        dayIndex = lh.dayIndex,
        scope = lh.scope,
        title = lh.hazard.title,
        safetyNote = lh.hazard.safetyNote,
        requiredGear = List<String>.from(lh.hazard.requiredGear),
        segmentId = lh.segmentId,
        anchorId = lh.anchorId,
        anchorTitle = lh.anchorTitle,
        distanceAlongM = lh.hazard.distanceAlongM,
        coord = lh.hazard.coord;
}

/// The bundle `/trips/split` returns and a locally-assembled trip derives:
/// every hazard, the worst-first sync-alert subset, and the cheap precheck.
class HazardRollup {
  const HazardRollup({
    required this.hasSyncAlerts,
    required this.syncAlerts,
    required this.hazards,
  });

  const HazardRollup.empty()
      : hasSyncAlerts = false,
        syncAlerts = const [],
        hazards = const [];

  /// Whether any hazard on the trip interrupts on sync — the check a caller
  /// makes before it builds the interrupt surface at all.
  final bool hasSyncAlerts;

  /// The `alertingSeverities` subset, flattened and ordered worst-first.
  final List<SyncAlert> syncAlerts;

  /// Every hazard on the trip, in reading order.
  final List<LocatedHazard> hazards;

  factory HazardRollup.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'hazard_rollup');
    final r = HazardRollup(
      hasSyncAlerts: f.takeBool('has_sync_alerts') ?? false,
      syncAlerts: f.takeList('sync_alerts', SyncAlert.fromJson),
      hazards: f.takeList('hazards', LocatedHazard.fromJson),
    );
    f.done();
    return r;
  }

  /// The same traversal `plotlines_core.trips.hazards` runs server-side, over a
  /// trip the client assembled locally. Day-level hazards first, then each
  /// segment's, day by day; `anchor` scope wins whenever `Hazard.anchorId` is
  /// set, with the title resolved against [Trip.anchors].
  factory HazardRollup.fromTrip(Trip trip) {
    final anchorTitles = <String, String>{
      for (final a in trip.anchors)
        if (a.title != null) a.id: a.title!,
    };

    LocatedHazard locate(Hazard h, Day day, {String? segmentId}) {
      if (h.anchorId != null) {
        return LocatedHazard(
          hazard: h,
          scope: 'anchor',
          dayIndex: day.index,
          dayId: day.id,
          segmentId: segmentId,
          anchorId: h.anchorId,
          anchorTitle: anchorTitles[h.anchorId],
        );
      }
      return LocatedHazard(
        hazard: h,
        scope: segmentId != null ? 'passage' : 'day',
        dayIndex: day.index,
        dayId: day.id,
        segmentId: segmentId,
      );
    }

    final located = <LocatedHazard>[];
    for (final day in trip.days) {
      for (final h in day.hazards) {
        located.add(locate(h, day));
      }
      for (final segment in day.segments) {
        for (final h in segment.hazards) {
          located.add(locate(h, day, segmentId: segment.id));
        }
      }
    }

    final alerting = located.where((lh) => alertingSeverities.contains(lh.hazard.severity)).toList()
      ..sort(_worstFirst);

    return HazardRollup(
      hasSyncAlerts: alerting.isNotEmpty,
      syncAlerts: [for (final lh in alerting) SyncAlert._fromLocated(lh)],
      hazards: located,
    );
  }
}

/// `hazards.py._order_key`, field for field: worst severity first, then earliest
/// day, then placed-before-unplaced, then distance along, then title, then id —
/// deterministic, because a Character who syncs the same trip twice must see the
/// same alert list (no gamification, Brand Value 9).
int _worstFirst(LocatedHazard a, LocatedHazard b) {
  int rank(LocatedHazard lh) => hazardSeverities.indexOf(lh.hazard.severity);
  var c = rank(b).compareTo(rank(a));
  if (c != 0) return c;
  c = a.dayIndex.compareTo(b.dayIndex);
  if (c != 0) return c;
  final ad = a.hazard.distanceAlongM, bd = b.hazard.distanceAlongM;
  c = (ad == null ? 1 : 0).compareTo(bd == null ? 1 : 0);
  if (c != 0) return c;
  c = (ad ?? 0.0).compareTo(bd ?? 0.0);
  if (c != 0) return c;
  c = (a.hazard.title ?? '').toLowerCase().compareTo((b.hazard.title ?? '').toLowerCase());
  if (c != 0) return c;
  return a.hazard.id.compareTo(b.hazard.id);
}
