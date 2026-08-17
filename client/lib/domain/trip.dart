/// `$defs/duration`, `$defs/attribution`, `$defs/provenance`, and the
/// top-level trip payload object itself.
library;

import 'day.dart';
import 'json_utils.dart';
import 'route_metrics.dart';
import 'weight_profile.dart';

const String tripSchemaVersion = '1.1.0';

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
    this.metrics,
    this.provenance,
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
    return out;
  }

  /// Every mode present anywhere in the trip — the denormalized list G2a's
  /// list surface projects rather than decoding a payload per row (ARCH §10.3).
  Set<String> get modes => {
        for (final d in days)
          for (final s in d.segments) s.mode,
      };

  Trip copyWith({
    String? title,
    String? updatedAt,
    TripDuration? duration,
    WeightProfile? defaultWeights,
    Map<String, DayLimit>? dayLimits,
    List<Day>? days,
    RollUp? metrics,
    Provenance? provenance,
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
        metrics: metrics ?? this.metrics,
        provenance: provenance ?? this.provenance,
      );
}
