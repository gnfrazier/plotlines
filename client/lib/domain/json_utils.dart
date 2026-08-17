/// Shared JSON plumbing for the trip payload domain layer (ARCH §9.1).
///
/// Authority for every shape read/written here is
/// `docs/schemas/trip_payload.schema.json` (ARCH decision D28: where the schema and
/// `plotlines_core.trips.payload` disagree, the schema wins). This file carries only
/// the two cross-cutting rules every other file in `domain/` leans on:
///
///  1. **Reads are exhaustive.** [JsonFields] pops each key as it is consumed and
///     [JsonFields.done] throws on anything left over, so a `fromJson` that forgets a
///     field fails loudly instead of silently dropping it on the next write.
///  2. **Every fractional number is read through `num`, never `as double`.** A JSON
///     `4` is valid where `4.0` was meant (Python's `round(x)` returns an `int`), and
///     `as double` on it throws at the wrong place.
library;

/// `[lon, lat]` (RFC 7946), optionally `[lon, lat, elevation_m]`.
typedef Coord = List<double>;

/// A JSON object being consumed. Pops keys as they are read; [done] fails on any key
/// nobody claimed, which is what makes the schema's `additionalProperties: false`
/// true at this reader too.
class JsonFields {
  JsonFields(Map<String, dynamic> source, this.what)
      : _map = Map<String, dynamic>.from(source);

  final Map<String, dynamic> _map;
  final String what;

  dynamic take(String key) {
    final present = _map.containsKey(key);
    final value = _map.remove(key);
    if (present && value == null) {
      throw FormatException(
          '$what.$key is null; the schema forbids null (absent means unset)');
    }
    return value;
  }

  double? takeNum(String key) {
    final value = take(key);
    return value == null ? null : (value as num).toDouble();
  }

  int? takeInt(String key) {
    final value = take(key);
    if (value == null) return null;
    if (value is int) return value;
    final asNum = value as num;
    if (asNum != asNum.roundToDouble()) {
      throw FormatException('$what.$key is $value where an integer was expected');
    }
    return asNum.toInt();
  }

  String? takeString(String key) => take(key) as String?;

  bool? takeBool(String key) => take(key) as bool?;

  List<String> takeStrings(String key) {
    final value = take(key);
    return value == null ? const [] : (value as List).map((v) => v as String).toList();
  }

  List<T> takeList<T>(String key, T Function(Map<String, dynamic>) build) {
    final value = take(key);
    return value == null
        ? <T>[]
        : (value as List)
            .map((v) => build(Map<String, dynamic>.from(v as Map)))
            .toList();
  }

  T? takeObject<T>(String key, T Function(Map<String, dynamic>) build) {
    final value = take(key);
    return value == null ? null : build(Map<String, dynamic>.from(value as Map));
  }

  Coord? takeCoord(String key) {
    final value = take(key);
    return value == null
        ? null
        : (value as List).map((v) => (v as num).toDouble()).toList();
  }

  List<Coord> takeCoords(String key) {
    final value = take(key);
    return value == null
        ? const []
        : (value as List)
            .map((c) => (c as List).map((v) => (v as num).toDouble()).toList())
            .toList();
  }

  /// `additionalProperties: { "$ref": "#/$defs/author_weight" }`-shaped maps
  /// (`weight_profile.surface`).
  Map<String, double> takeWeights(String key) {
    final value = take(key);
    if (value == null) return const {};
    return (value as Map)
        .map((k, v) => MapEntry(k as String, (v as num).toDouble()));
  }

  void done() {
    if (_map.isNotEmpty) {
      throw FormatException(
          'unread field(s) on $what: ${_map.keys.toList()..sort()} — the domain '
          'layer would have dropped them on the next write');
    }
  }
}

/// Drops nulls and empty collections, matching the payload's "absent means unset"
/// rule (rule 1). Kept behaviourally identical to `plotlines_core.trips.payload.prune`
/// so the two producers agree on what gets omitted.
Map<String, dynamic> pruneJson(Map<String, dynamic> map) {
  final out = <String, dynamic>{};
  map.forEach((key, value) {
    if (value == null) return;
    if (value is List && value.isEmpty) return;
    if (value is Map && value.isEmpty) return;
    out[key] = value;
  });
  return out;
}

/// Rejects NaN/Infinity (rule 3) at the same boundary Python's `f()` does, rather
/// than letting them travel as far as `jsonEncode` before failing.
double finite(num value, String what) {
  final d = value.toDouble();
  if (!d.isFinite) {
    throw FormatException('non-finite number in $what: $d');
  }
  return d;
}

/// Validates a `coord` array: 2 or 3 finite numbers, `[lon, lat(, elevation_m)]`.
Coord checkCoord(Coord coord, String what) {
  if (coord.length < 2 || coord.length > 3) {
    throw FormatException('$what has ${coord.length} elements; coord needs 2 or 3');
  }
  for (var i = 0; i < coord.length; i++) {
    finite(coord[i], '$what[$i]');
  }
  return coord;
}

/// `day_limits`: keys are travel modes, key order is meaningless.
Map<String, DayLimit> dayLimitsFromJson(dynamic raw) => (raw as Map).map(
      (mode, limit) => MapEntry(
        mode as String,
        DayLimit.fromJson(Map<String, dynamic>.from(limit as Map)),
      ),
    );

Map<String, dynamic> dayLimitsToJson(Map<String, DayLimit> limits) =>
    limits.map((mode, limit) => MapEntry(mode, limit.toJson()));

/// FR19 / C3 — per-mode min/max distance for a day.
class DayLimit {
  DayLimit({this.minM, this.maxM});

  final double? minM;
  final double? maxM;

  factory DayLimit.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'day_limit');
    final limit = DayLimit(minM: f.takeNum('min_m'), maxM: f.takeNum('max_m'));
    f.done();
    return limit;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'min_m': minM == null ? null : finite(minM!, 'day_limit.min_m'),
        'max_m': maxM == null ? null : finite(maxM!, 'day_limit.max_m'),
      });
}
