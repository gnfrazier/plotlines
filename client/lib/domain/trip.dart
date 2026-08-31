/// `$defs/duration`, `$defs/attribution`, `$defs/provenance`, and the
/// top-level trip payload object itself.
library;

import 'anchor.dart';
import 'day.dart';
import 'json_utils.dart';
import 'route_metrics.dart';
import 'weight_profile.dart';

// Bumped to 1.2.0 by FR106/FR110 (Story O1), which added `anchor`/`role`
// and the trip-level `anchors` array — additive: an absent `anchors` list
// still parses. Bumped to 1.3.0 by FR107 (Story O2), which added
// `role.coord` — additive again: a role with no `coord` still parses, and
// behaves exactly as a single point (O2's AC). Bumped to 1.4.0 by FR37
// (Story E1), which added `segment.note`/`segment.media` and `day.media`
// (`day.note` already existed) — additive again: a segment or day with
// neither still parses. Bumped to 1.5.0 by FR38 (Story O6), which added
// `role.arc`/`segment.arc_stage`, and to 1.6.0 by FR27 (Story C11), which
// added `hazard.anchor_id` so a hazard/technical-crux marker can be pinned
// to a promoted anchor — additive each time: an absent field still parses.
const String tripSchemaVersion = '1.6.0';

/// FR17 / C1 — single-day, multi-day, or multi-week.
class TripDuration {
  TripDuration({this.startDate, this.endDate, this.dayCount});

  final String? startDate;
  final String? endDate;
  final int? dayCount;

  factory TripDuration.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'duration');
    final d = TripDuration(
      startDate: f.takeString('start_date'),
      endDate: f.takeString('end_date'),
      dayCount: f.takeInt('day_count'),
    );
    f.done();
    return d;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'start_date': startDate,
        'end_date': endDate,
        'day_count': dayCount,
      });
}

/// FR86 / FR95 / K10 — one licence obligation carried by data used in this
/// payload. The About surface reads these rather than hardcoding a list
/// that can silently fall out of date with the data actually used.
class Attribution {
  Attribution({required this.source, required this.licence, required this.credit, this.url});

  final String source;
  final String licence;
  final String credit;
  final String? url;

  factory Attribution.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'attribution');
    final a = Attribution(
      source: f.takeString('source')!,
      licence: f.takeString('licence')!,
      credit: f.takeString('credit')!,
      url: f.takeString('url'),
    );
    f.done();
    return a;
  }

  Map<String, dynamic> toJson() =>
      pruneJson({'source': source, 'licence': licence, 'credit': credit, 'url': url});
}

/// Who wrote this payload and against what. M12's version check compares
/// client and sidecar at runtime; this records what actually produced the
/// bytes, which is the only way a payload found on disk a year later can be
/// read with the right expectations.
class Provenance {
  Provenance({this.producedBy, this.appVersion, this.sidecarVersion, this.attribution = const []});

  final String? producedBy;
  final String? appVersion;
  final String? sidecarVersion;
  final List<Attribution> attribution;

  factory Provenance.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'provenance');
    final p = Provenance(
      producedBy: f.takeString('produced_by'),
      appVersion: f.takeString('app_version'),
      sidecarVersion: f.takeString('sidecar_version'),
      attribution: f.takeList('attribution', Attribution.fromJson),
    );
    f.done();
    return p;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'produced_by': producedBy,
        'app_version': appVersion,
        'sidecar_version': sidecarVersion,
        'attribution': attribution.isEmpty ? null : attribution.map((a) => a.toJson()).toList(),
      });
}

/// The canonical plotline (ARCH P8). What `trip.payload` holds, in full —
/// simultaneously `plotlines-core`'s return type, drift's local storage blob,
/// the (future) hosted JSONB column, and this Dart domain layer, with no
/// adapter at any boundary (ARCH D28, SPIKE-20).
///
/// **Schema/payload.py disagreement (flagged per D28 — schema wins):** the schema's
/// top-level `required` array includes `"days"`, but
/// `plotlines_core.trips.payload.Trip.to_dict` runs its whole output through
/// `prune()`, which unconditionally drops *any* empty list — including `days` on a
/// trip with none yet. A zero-day trip therefore round-trips through Python as a
/// payload missing its one required array field. [toJson] does not replicate that:
/// `days` is emitted unconditionally, even as `[]`. `cue_sheet.cues` has the same
/// required-but-prunable shape and the same fix in `cue.dart`.
class Trip {
  Trip({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.schemaVersion = tripSchemaVersion,
    this.duration,
    this.defaultWeights,
    this.dayLimits = const {},
    this.days = const [],
    this.anchors = const [],
    this.metrics,
    this.provenance,
    this.declaredModes = const {},
  });

  final String schemaVersion;
  final String id;
  final String title;
  final String createdAt;
  final String updatedAt;
  final TripDuration? duration;
  final WeightProfile? defaultWeights;

  /// FR36 / M2's `weights.at(position)` seam — the trip-level default a
  /// day's or segment's own `weights` overrides.
  final Map<String, DayLimit> dayLimits;
  final List<Day> days;

  /// FR106, FR110 / O1 — the promoted set, trip-scoped rather than day- or
  /// segment-scoped: an anchor can exist unattached to any day (N4a's
  /// "anchors view" — ordinary working state, not an error).
  final List<Anchor> anchors;

  /// FR31 / D1 — trip totals, derived from the days and stored so G2a's
  /// list surface can show them without re-deriving.
  final RollUp? metrics;
  final Provenance? provenance;

  factory Trip.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'trip');
    final schemaVersion = f.takeString('schema_version') ?? tripSchemaVersion;
    final id = f.takeString('id')!;
    final title = f.takeString('title')!;
    final createdAt = f.takeString('created_at')!;
    final updatedAt = f.takeString('updated_at')!;
    final duration = f.takeObject('duration', TripDuration.fromJson);
    WeightProfile? defaultWeights;
    var dayLimits = const <String, DayLimit>{};
    final defaults = f.take('defaults');
    if (defaults != null) {
      final d = JsonFields(Map<String, dynamic>.from(defaults as Map), 'trip.defaults');
      defaultWeights = d.takeObject('weights', WeightProfile.fromJson);
      final rawLimits = d.take('day_limits');
      if (rawLimits != null) dayLimits = dayLimitsFromJson(rawLimits);
      d.done();
    }
    final days = f.takeList('days', Day.fromJson);
    final anchors = f.takeList('anchors', Anchor.fromJson);
    final metrics = f.takeObject('metrics', RollUp.fromJson);
    final provenance = f.takeObject('provenance', Provenance.fromJson);
    f.done();
    return Trip(
      schemaVersion: schemaVersion,
      id: id,
      title: title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      duration: duration,
      defaultWeights: defaultWeights,
      dayLimits: dayLimits,
      days: days,
      anchors: anchors,
      metrics: metrics,
      provenance: provenance,
    );
  }

  Map<String, dynamic> toJson() {
    final defaults = pruneJson({
      'weights': defaultWeights?.toJson(),
      'day_limits': dayLimits.isEmpty ? null : dayLimitsToJson(dayLimits),
    });
    final out = pruneJson({
      'schema_version': schemaVersion,
      'id': id,
      'title': title,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'duration': duration?.toJson(),
      'defaults': defaults.isEmpty ? null : defaults,
      'metrics': metrics?.toJson(),
      'provenance': provenance?.toJson(),
    });
    // `days` is schema-required (top-level `required` array); keep it even when
    // empty rather than letting `pruneJson` drop it like every other list here —
    // see the class doc comment for the payload.py disagreement this guards against.
    out['days'] = days.map((d) => d.toJson()).toList();
    if (anchors.isNotEmpty) out['anchors'] = anchors.map((a) => a.toJson()).toList();
    return out;
  }

  /// Every mode present anywhere in the trip — the denormalized list G2a's
  /// list surface projects rather than decoding a payload per row (ARCH §10.3).
  Set<String> get modes => {
        for (final d in days)
          for (final s in d.segments) s.mode,
      };

  /// FR144/N0 — the Author's **declared** travel modes: stated at trip
  /// initiation (ahead of the location prompt), editable for the trip's
  /// life, and never shrunk automatically. Distinct from [modes] above,
  /// which is *derived* from whatever segments happen to exist and can be
  /// empty for a brand-new trip with no days yet — the two must not be
  /// conflated (an empty [modes] on a fresh trip does not mean nothing was
  /// declared). Declaring is not a constraint (FR144): creating a passage
  /// in a mode outside this set silently adds it here rather than being
  /// blocked (`CurrentTripNotifier._replaceDay`), it never removes one.
  ///
  /// **Not part of the wire payload.** `trip_payload.schema.json` has no
  /// such field and is `additionalProperties: false` at the top level, so
  /// this is deliberately absent from [toJson]/[fromJson] — the same
  /// reasoning `trip_authoring_meta_provider.dart` already documents for
  /// party size. Unlike that provider's fields, this **is** persisted: as
  /// its own column on the local `Trips` table (`app_database.dart`),
  /// alongside (not inside) the canonical payload blob, the same way that
  /// table's `modes` column already denormalizes [modes] outside the
  /// payload for G2a's list view.
  final Set<String> declaredModes;

  Trip copyWith({
    String? title,
    String? updatedAt,
    TripDuration? duration,
    WeightProfile? defaultWeights,
    Map<String, DayLimit>? dayLimits,
    List<Day>? days,
    List<Anchor>? anchors,
    RollUp? metrics,
    Provenance? provenance,
    Set<String>? declaredModes,
  }) =>
      Trip(
        schemaVersion: schemaVersion,
        id: id,
        title: title ?? this.title,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        duration: duration ?? this.duration,
        defaultWeights: defaultWeights ?? this.defaultWeights,
        dayLimits: dayLimits ?? this.dayLimits,
        days: days ?? this.days,
        anchors: anchors ?? this.anchors,
        metrics: metrics ?? this.metrics,
        provenance: provenance ?? this.provenance,
        declaredModes: declaredModes ?? this.declaredModes,
      );
}
