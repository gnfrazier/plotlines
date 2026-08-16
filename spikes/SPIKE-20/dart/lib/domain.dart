/// The Flutter client's domain layer for the trip payload (ARCH §9.1).
///
/// Pure Dart, no I/O, no drift import — the layering rule §9.1 draws. Every class
/// here is one `$defs` entry in `docs/schemas/trip_payload.schema.json`.
///
/// Two decisions in this file are the whole reason SPIKE-20 wrote a real Dart layer
/// instead of asserting that a `Map<String, dynamic>` survives a database round trip:
///
///  1. **Reads are exhaustive.** `_Fields` pops each key as it is consumed and throws
///     on anything left over. A hand-written `fromJson` that simply forgets a field
///     drops it silently on the next write; this makes the schema's
///     `additionalProperties: false` true at the reader as well as at the validator,
///     which is where the loss would actually happen.
///  2. **Every fractional number is read through `num`.** `as double` on a JSON `4`
///     throws — and a producer writing `4` where `4.0` was meant is not a
///     hypothetical: Python's `round(x)` returns an int and `round(x, 1)` a float.
library;

// ---------------------------------------------------------------- read helpers

/// A JSON object being consumed. Pops keys as they are read; `done()` fails on any
/// key nobody claimed.
class _Fields {
  _Fields(Map<String, dynamic> source, this.what)
      : _map = Map<String, dynamic>.from(source);

  final Map<String, dynamic> _map;
  final String what;

  dynamic take(String key) {
    final present = _map.containsKey(key);
    final value = _map.remove(key);
    if (present && value == null) {
      throw FormatException('$what.$key is null; the schema forbids null (absent '
          'means unset)');
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
    return value == null
        ? const []
        : (value as List).map((v) => v as String).toList();
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

  List<double>? takeCoord(String key) {
    final value = take(key);
    return value == null
        ? null
        : (value as List).map((v) => (v as num).toDouble()).toList();
  }

  List<List<double>> takeCoords(String key) {
    final value = take(key);
    return value == null
        ? const []
        : (value as List)
            .map((c) => (c as List).map((v) => (v as num).toDouble()).toList())
            .toList();
  }

  Map<String, double> takeWeights(String key) {
    final value = take(key);
    if (value == null) return const {};
    return (value as Map).map((k, v) => MapEntry(k as String, (v as num).toDouble()));
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
/// rule. Kept identical to `plotlines_core.trips.payload.prune`, on purpose: two
/// producers with different omission rules produce two dialects of one schema.
Map<String, dynamic> prune(Map<String, dynamic> map) {
  final out = <String, dynamic>{};
  map.forEach((key, value) {
    if (value == null) return;
    if (value is List && value.isEmpty) return;
    if (value is Map && value.isEmpty) return;
    out[key] = value;
  });
  return out;
}

// ------------------------------------------------------------- value objects

class WeightProfile {
  WeightProfile({
    required this.name,
    this.climbing,
    this.traffic,
    this.surface = const {},
    this.poiDensity,
    this.poiTypes = const [],
    this.terrainTechnicality,
    this.detourBudget,
  });

  final String name;
  final double? climbing;
  final double? traffic;
  final Map<String, double> surface;
  final double? poiDensity;
  final List<String> poiTypes;
  final double? terrainTechnicality;
  final double? detourBudget;

  factory WeightProfile.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'weight_profile');
    final name = f.takeString('name')!;
    final climbing = f.takeNum('climbing');
    final traffic = f.takeNum('traffic');
    final surface = f.takeWeights('surface');
    double? density;
    var types = <String>[];
    final poi = f.take('poi');
    if (poi != null) {
      final p = _Fields(Map<String, dynamic>.from(poi as Map), 'weight_profile.poi');
      density = p.takeNum('density');
      types = p.takeStrings('types');
      p.done();
    }
    final technicality = f.takeNum('terrain_technicality');
    final detour = f.takeNum('detour_budget');
    f.done();
    return WeightProfile(
      name: name,
      climbing: climbing,
      traffic: traffic,
      surface: surface,
      poiDensity: density,
      poiTypes: types,
      terrainTechnicality: technicality,
      detourBudget: detour,
    );
  }

  Map<String, dynamic> toJson() => prune({
        'name': name,
        'climbing': climbing,
        'traffic': traffic,
        'surface': surface.isEmpty ? null : surface,
        'poi': prune({
          'density': poiDensity,
          'types': poiTypes.isEmpty ? null : poiTypes,
        }),
        'terrain_technicality': terrainTechnicality,
        'detour_budget': detourBudget,
      });

  WeightProfile withSurface(String surfaceClass, double value) => WeightProfile(
        name: name,
        climbing: climbing,
        traffic: traffic,
        surface: {...surface, surfaceClass: value},
        poiDensity: poiDensity,
        poiTypes: poiTypes,
        terrainTechnicality: terrainTechnicality,
        detourBudget: detourBudget,
      );
}

class Band {
  Band({required this.attribute, this.min, this.max, this.source});

  final String attribute;
  final double? min;
  final double? max;
  final String? source;

  factory Band.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'band');
    final band = Band(
      attribute: f.takeString('attribute')!,
      min: f.takeNum('min'),
      max: f.takeNum('max'),
      source: f.takeString('source'),
    );
    f.done();
    return band;
  }

  Map<String, dynamic> toJson() =>
      prune({'attribute': attribute, 'min': min, 'max': max, 'source': source});
}

class Violation {
  Violation({required this.attribute, required this.realised, required this.shortfall});

  final String attribute;
  final double realised;
  final double shortfall;

  factory Violation.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'violation');
    final v = Violation(
      attribute: f.takeString('attribute')!,
      realised: f.takeNum('realised')!,
      shortfall: f.takeNum('shortfall')!,
    );
    f.done();
    return v;
  }

  Map<String, dynamic> toJson() =>
      {'attribute': attribute, 'realised': realised, 'shortfall': shortfall};
}

class TargetDistance {
  TargetDistance({required this.valueM, this.minM, this.maxM, this.advisory});

  final double valueM;
  final double? minM;
  final double? maxM;
  final bool? advisory;

  factory TargetDistance.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'target_distance');
    final t = TargetDistance(
      valueM: f.takeNum('value_m')!,
      minM: f.takeNum('min_m'),
      maxM: f.takeNum('max_m'),
      advisory: f.takeBool('advisory'),
    );
    f.done();
    return t;
  }

  Map<String, dynamic> toJson() => prune({
        'value_m': valueM,
        'min_m': minM,
        'max_m': maxM,
        'advisory': advisory,
      });
}

class RouteMetrics {
  RouteMetrics({
    required this.distanceM,
    required this.climbM,
    required this.descentM,
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

  final double distanceM;
  final double climbM;
  final double descentM;
  final double? traffic;
  final double? unpavedFrac;
  final double? scenicFrac;
  final double? maxGrade;
  final double? overlapFrac;
  final double? overlapNearFrac;
  final double? overlapFarFrac;
  final int? edgeCount;
  final double? movingTimeS;
  final double? elapsedTimeS;
  final String? paceSource;

  factory RouteMetrics.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'route_metrics');
    final m = RouteMetrics(
      distanceM: f.takeNum('distance_m') ?? 0.0,
      climbM: f.takeNum('climb_m') ?? 0.0,
      descentM: f.takeNum('descent_m') ?? 0.0,
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

  Map<String, dynamic> toJson() => prune({
        'distance_m': distanceM,
        'climb_m': climbM,
        'descent_m': descentM,
        'traffic': traffic,
        'unpaved_frac': unpavedFrac,
        'scenic_frac': scenicFrac,
        'max_grade': maxGrade,
        'overlap_frac': overlapFrac,
        'overlap_near_frac': overlapNearFrac,
        'overlap_far_frac': overlapFarFrac,
        'edge_count': edgeCount,
        'moving_time_s': movingTimeS,
        'elapsed_time_s': elapsedTimeS,
        'pace_source': paceSource,
      });
}

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
  final List<double> samples;
  final int? voidSamples;
  final String? source;

  factory Elevation.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'elevation');
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

  Map<String, dynamic> toJson() => prune({
        'ascent_m': ascentM,
        'descent_m': descentM,
        'min_m': minM,
        'max_m': maxM,
        'samples': samples.isEmpty ? null : samples,
        'void_samples': voidSamples,
        'source': source,
      });
}

class MediaRef {
  MediaRef({
    required this.id,
    required this.kind,
    required this.path,
    this.caption,
    this.bytes,
    this.durationS,
  });

  final String id;
  final String kind;
  final String path;
  final String? caption;
  final int? bytes;
  final double? durationS;

  factory MediaRef.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'media_ref');
    final m = MediaRef(
      id: f.takeString('id')!,
      kind: f.takeString('kind')!,
      path: f.takeString('path')!,
      caption: f.takeString('caption'),
      bytes: f.takeInt('bytes'),
      durationS: f.takeNum('duration_s'),
    );
    f.done();
    return m;
  }

  Map<String, dynamic> toJson() => prune({
        'id': id,
        'kind': kind,
        'path': path,
        'caption': caption,
        'bytes': bytes,
        'duration_s': durationS,
      });
}

class Narration {
  Narration({required this.triggerDistanceM, this.mediaId, this.text});

  final double triggerDistanceM;
  final String? mediaId;
  final String? text;

  factory Narration.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'narration');
    final n = Narration(
      triggerDistanceM: f.takeNum('trigger_distance_m')!,
      mediaId: f.takeString('media_id'),
      text: f.takeString('text'),
    );
    f.done();
    return n;
  }

  Map<String, dynamic> toJson() => prune({
        'trigger_distance_m': triggerDistanceM,
        'media_id': mediaId,
        'text': text,
      });
}

class ScheduledWindow {
  ScheduledWindow({required this.opensAt, this.closesAt, this.timezone, this.detail});

  final String opensAt;
  final String? closesAt;
  final String? timezone;
  final String? detail;

  factory ScheduledWindow.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'scheduled_window');
    final w = ScheduledWindow(
      opensAt: f.takeString('opens_at')!,
      closesAt: f.takeString('closes_at'),
      timezone: f.takeString('timezone'),
      detail: f.takeString('detail'),
    );
    f.done();
    return w;
  }

  Map<String, dynamic> toJson() => prune({
        'opens_at': opensAt,
        'closes_at': closesAt,
        'timezone': timezone,
        'detail': detail,
      });
}

class Node {
  Node({
    required this.id,
    required this.kind,
    required this.coord,
    this.distanceAlongM,
    this.title,
    this.note,
    this.media = const [],
    this.amenities = const [],
    this.poiType,
    this.arcStage,
    this.narration,
    this.instructions,
    this.scheduled,
  });

  final String id;
  final String kind;
  final List<double> coord;
  final double? distanceAlongM;
  final String? title;
  final String? note;
  final List<MediaRef> media;
  final List<String> amenities;
  final String? poiType;
  final String? arcStage;
  final Narration? narration;
  final String? instructions;
  final ScheduledWindow? scheduled;

  factory Node.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'node');
    final n = Node(
      id: f.takeString('id')!,
      kind: f.takeString('kind')!,
      coord: f.takeCoord('coord')!,
      distanceAlongM: f.takeNum('distance_along_m'),
      title: f.takeString('title'),
      note: f.takeString('note'),
      media: f.takeList('media', MediaRef.fromJson),
      amenities: f.takeStrings('amenities'),
      poiType: f.takeString('poi_type'),
      arcStage: f.takeString('arc_stage'),
      narration: f.takeObject('narration', Narration.fromJson),
      instructions: f.takeString('instructions'),
      scheduled: f.takeObject('scheduled', ScheduledWindow.fromJson),
    );
    f.done();
    return n;
  }

  Map<String, dynamic> toJson() => prune({
        'id': id,
        'kind': kind,
        'coord': coord,
        'distance_along_m': distanceAlongM,
        'title': title,
        'note': note,
        'media': media.map((m) => m.toJson()).toList(),
        'amenities': amenities,
        'poi_type': poiType,
        'arc_stage': arcStage,
        'narration': narration?.toJson(),
        'instructions': instructions,
        'scheduled': scheduled?.toJson(),
      });

  Node withNote(String value) => Node(
        id: id,
        kind: kind,
        coord: coord,
        distanceAlongM: distanceAlongM,
        title: title,
        note: value,
        media: media,
        amenities: amenities,
        poiType: poiType,
        arcStage: arcStage,
        narration: narration,
        instructions: instructions,
        scheduled: scheduled,
      );
}

class Hazard {
  Hazard({
    required this.id,
    required this.severity,
    this.title,
    this.safetyNote,
    this.requiredGear = const [],
    this.coord,
    this.distanceAlongM,
    this.nodeId,
  });

  final String id;
  final String severity;
  final String? title;
  final String? safetyNote;
  final List<String> requiredGear;
  final List<double>? coord;
  final double? distanceAlongM;
  final String? nodeId;

  factory Hazard.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'hazard');
    final h = Hazard(
      id: f.takeString('id')!,
      severity: f.takeString('severity')!,
      title: f.takeString('title'),
      safetyNote: f.takeString('safety_note'),
      requiredGear: f.takeStrings('required_gear'),
      coord: f.takeCoord('coord'),
      distanceAlongM: f.takeNum('distance_along_m'),
      nodeId: f.takeString('node_id'),
    );
    f.done();
    return h;
  }

  Map<String, dynamic> toJson() => prune({
        'id': id,
        'severity': severity,
        'title': title,
        'safety_note': safetyNote,
        'required_gear': requiredGear,
        'coord': coord,
        'distance_along_m': distanceAlongM,
        'node_id': nodeId,
      });
}

class LineStringGeometry {
  LineStringGeometry({required this.coordinates, required this.source});

  final List<List<double>> coordinates;
  final String source;

  factory LineStringGeometry.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'line_string');
    final type = f.takeString('type');
    if (type != 'LineString') {
      throw FormatException('geometry type $type is not a LineString');
    }
    final g = LineStringGeometry(
      coordinates: f.takeCoords('coordinates'),
      source: f.takeString('source')!,
    );
    f.done();
    return g;
  }

  Map<String, dynamic> toJson() =>
      {'type': 'LineString', 'coordinates': coordinates, 'source': source};
}

class Portage {
  Portage({
    required this.id,
    required this.geometry,
    this.exitBank,
    this.distanceM,
    this.surface,
    this.elevationChangeM,
    this.mandatory,
    this.note,
  });

  final String id;
  final LineStringGeometry geometry;
  final String? exitBank;
  final double? distanceM;
  final String? surface;
  final double? elevationChangeM;
  final bool? mandatory;
  final String? note;

  factory Portage.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'portage');
    final p = Portage(
      id: f.takeString('id')!,
      geometry: f.takeObject('geometry', LineStringGeometry.fromJson)!,
      exitBank: f.takeString('exit_bank'),
      distanceM: f.takeNum('distance_m'),
      surface: f.takeString('surface'),
      elevationChangeM: f.takeNum('elevation_change_m'),
      mandatory: f.takeBool('mandatory'),
      note: f.takeString('note'),
    );
    f.done();
    return p;
  }

  Map<String, dynamic> toJson() => prune({
        'id': id,
        'geometry': geometry.toJson(),
        'exit_bank': exitBank,
        'distance_m': distanceM,
        'surface': surface,
        'elevation_change_m': elevationChangeM,
        'mandatory': mandatory,
        'note': note,
      });
}

class Alternate {
  Alternate({
    required this.id,
    required this.kind,
    required this.geometry,
    this.label,
    this.metrics,
    this.elevation,
    this.divergesAtM,
    this.rejoinsAtM,
  });

  final String id;
  final String kind;
  final LineStringGeometry geometry;
  final String? label;
  final RouteMetrics? metrics;
  final Elevation? elevation;
  final double? divergesAtM;
  final double? rejoinsAtM;

  factory Alternate.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'alternate');
    final a = Alternate(
      id: f.takeString('id')!,
      kind: f.takeString('kind')!,
      label: f.takeString('label'),
      geometry: f.takeObject('geometry', LineStringGeometry.fromJson)!,
      metrics: f.takeObject('metrics', RouteMetrics.fromJson),
      elevation: f.takeObject('elevation', Elevation.fromJson),
      divergesAtM: f.takeNum('diverges_at_m'),
      rejoinsAtM: f.takeNum('rejoins_at_m'),
    );
    f.done();
    return a;
  }

  Map<String, dynamic> toJson() => prune({
        'id': id,
        'kind': kind,
        'label': label,
        'geometry': geometry.toJson(),
        'metrics': metrics?.toJson(),
        'elevation': elevation?.toJson(),
        'diverges_at_m': divergesAtM,
        'rejoins_at_m': rejoinsAtM,
      });
}

class SolveProvenance {
  SolveProvenance({
    this.engineVersion,
    this.graphRegion,
    this.solveMs,
    this.solverCalls,
    this.solvedAt,
    this.closed,
    this.hitVia,
    this.stale,
  });

  final String? engineVersion;
  final String? graphRegion;
  final double? solveMs;
  final int? solverCalls;
  final String? solvedAt;
  final bool? closed;
  final bool? hitVia;

  /// Set when an Author edits an input this geometry was solved from. The derived
  /// half of a segment — geometry, metrics, elevation — is stale from that moment
  /// until a re-solve, and nothing else in the payload records that.
  final bool? stale;

  factory SolveProvenance.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'solve_provenance');
    final s = SolveProvenance(
      engineVersion: f.takeString('engine_version'),
      graphRegion: f.takeString('graph_region'),
      solveMs: f.takeNum('solve_ms'),
      solverCalls: f.takeInt('solver_calls'),
      solvedAt: f.takeString('solved_at'),
      closed: f.takeBool('closed'),
      hitVia: f.takeBool('hit_via'),
      stale: f.takeBool('stale'),
    );
    f.done();
    return s;
  }

  SolveProvenance markStale() => SolveProvenance(
        engineVersion: engineVersion,
        graphRegion: graphRegion,
        solveMs: solveMs,
        solverCalls: solverCalls,
        solvedAt: solvedAt,
        closed: closed,
        hitVia: hitVia,
        stale: true,
      );

  Map<String, dynamic> toJson() => prune({
        'engine_version': engineVersion,
        'graph_region': graphRegion,
        'solve_ms': solveMs,
        'solver_calls': solverCalls,
        'solved_at': solvedAt,
        'closed': closed,
        'hit_via': hitVia,
        'stale': stale,
      });
}

class Cue {
  Cue({
    required this.id,
    required this.sequence,
    required this.distanceAlongM,
    required this.kind,
    this.instruction,
    this.modifier,
    this.bearingDeg,
    this.refId,
    this.segmentId,
    this.retrace,
  });

  final String id;
  final int sequence;
  final double distanceAlongM;
  final String kind;
  final String? instruction;
  final String? modifier;
  final double? bearingDeg;
  final String? refId;
  final String? segmentId;

  /// SPIKE-21 — the cue stands on road already ridden (a via-node spur's return leg).
  final bool? retrace;

  factory Cue.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'cue');
    final c = Cue(
      id: f.takeString('id')!,
      sequence: f.takeInt('sequence')!,
      distanceAlongM: f.takeNum('distance_along_m')!,
      kind: f.takeString('kind')!,
      instruction: f.takeString('instruction'),
      modifier: f.takeString('modifier'),
      bearingDeg: f.takeNum('bearing_deg'),
      refId: f.takeString('ref_id'),
      segmentId: f.takeString('segment_id'),
      retrace: f.takeBool('retrace'),
    );
    f.done();
    return c;
  }

  Map<String, dynamic> toJson() => prune({
        'id': id,
        'sequence': sequence,
        'distance_along_m': distanceAlongM,
        'kind': kind,
        'instruction': instruction,
        'modifier': modifier,
        'bearing_deg': bearingDeg,
        'ref_id': refId,
        'segment_id': segmentId,
        'retrace': retrace,
      });
}

class CueSheet {
  CueSheet({
    required this.generatedAt,
    required this.cues,
    this.generator,
    this.segmentIds = const [],
    this.geometryDigest,
  });

  final String generatedAt;
  final List<Cue> cues;
  final String? generator;
  final List<String> segmentIds;
  final String? geometryDigest;

  factory CueSheet.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'cue_sheet');
    final generatedAt = f.takeString('generated_at')!;
    final generator = f.takeString('generator');
    var segmentIds = <String>[];
    String? digest;
    final derived = f.take('derived_from');
    if (derived != null) {
      final d = _Fields(Map<String, dynamic>.from(derived as Map), 'derived_from');
      segmentIds = d.takeStrings('segment_ids');
      digest = d.takeString('geometry_digest');
      d.done();
    }
    final cues = f.takeList('cues', Cue.fromJson);
    f.done();
    return CueSheet(
      generatedAt: generatedAt,
      generator: generator,
      segmentIds: segmentIds,
      geometryDigest: digest,
      cues: cues,
    );
  }

  Map<String, dynamic> toJson() => prune({
        'generated_at': generatedAt,
        'generator': generator,
        'derived_from': prune({
          'segment_ids': segmentIds.isEmpty ? null : segmentIds,
          'geometry_digest': geometryDigest,
        }),
        'cues': cues.map((c) => c.toJson()).toList(),
      });
}

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
    final f = _Fields(json, 'limit_breach');
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

  Map<String, dynamic> toJson() => prune({
        'mode': mode,
        'bound': bound,
        'limit_m': limitM,
        'realised_m': realisedM,
        'day_id': dayId,
      });
}

class RollUp {
  RollUp({this.total, this.byMode = const {}, this.limitBreaches = const []});

  final RouteMetrics? total;
  final Map<String, RouteMetrics> byMode;
  final List<LimitBreach> limitBreaches;

  factory RollUp.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'roll_up');
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

  Map<String, dynamic> toJson() => prune({
        'total': total?.toJson(),
        'by_mode': byMode.map((k, v) => MapEntry(k, v.toJson())),
        'limit_breaches': limitBreaches.map((b) => b.toJson()).toList(),
      });
}

// --------------------------------------------------------------- aggregates

class Segment {
  Segment({
    required this.id,
    required this.mode,
    required this.shape,
    this.title,
    this.start,
    this.end,
    this.via = const [],
    this.targetDistance,
    this.bands = const [],
    this.violations = const [],
    this.weights,
    this.geometry,
    this.metrics,
    this.elevation,
    this.nodes = const [],
    this.alternates = const [],
    this.hazards = const [],
    this.portages = const [],
    this.solve,
  });

  final String id;
  final String mode;
  final String shape;
  final String? title;
  final List<double>? start;
  final List<double>? end;
  final List<List<double>> via;
  final TargetDistance? targetDistance;
  final List<Band> bands;
  final List<Violation> violations;
  final WeightProfile? weights;
  final LineStringGeometry? geometry;
  final RouteMetrics? metrics;
  final Elevation? elevation;
  final List<Node> nodes;
  final List<Alternate> alternates;
  final List<Hazard> hazards;
  final List<Portage> portages;
  final SolveProvenance? solve;

  factory Segment.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'segment');
    final s = Segment(
      id: f.takeString('id')!,
      title: f.takeString('title'),
      mode: f.takeString('mode')!,
      shape: f.takeString('shape')!,
      start: f.takeCoord('start'),
      end: f.takeCoord('end'),
      via: f.takeCoords('via'),
      targetDistance: f.takeObject('target_distance', TargetDistance.fromJson),
      bands: f.takeList('bands', Band.fromJson),
      violations: f.takeList('violations', Violation.fromJson),
      weights: f.takeObject('weights', WeightProfile.fromJson),
      geometry: f.takeObject('geometry', LineStringGeometry.fromJson),
      metrics: f.takeObject('metrics', RouteMetrics.fromJson),
      elevation: f.takeObject('elevation', Elevation.fromJson),
      nodes: f.takeList('nodes', Node.fromJson),
      alternates: f.takeList('alternates', Alternate.fromJson),
      hazards: f.takeList('hazards', Hazard.fromJson),
      portages: f.takeList('portages', Portage.fromJson),
      solve: f.takeObject('solve', SolveProvenance.fromJson),
    );
    f.done();
    return s;
  }

  Map<String, dynamic> toJson() => prune({
        'id': id,
        'title': title,
        'mode': mode,
        'shape': shape,
        'start': start,
        'end': end,
        'via': via,
        'target_distance': targetDistance?.toJson(),
        'bands': bands.map((b) => b.toJson()).toList(),
        'violations': violations.map((v) => v.toJson()).toList(),
        'weights': weights?.toJson(),
        'geometry': geometry?.toJson(),
        'metrics': metrics?.toJson(),
        'elevation': elevation?.toJson(),
        'nodes': nodes.map((n) => n.toJson()).toList(),
        'alternates': alternates.map((a) => a.toJson()).toList(),
        'hazards': hazards.map((h) => h.toJson()).toList(),
        'portages': portages.map((p) => p.toJson()).toList(),
        'solve': solve?.toJson(),
      });

  Segment copyWith({
    List<List<double>>? via,
    List<Node>? nodes,
    WeightProfile? weights,
    SolveProvenance? solve,
  }) =>
      Segment(
        id: id,
        title: title,
        mode: mode,
        shape: shape,
        start: start,
        end: end,
        via: via ?? this.via,
        targetDistance: targetDistance,
        bands: bands,
        violations: violations,
        weights: weights ?? this.weights,
        geometry: geometry,
        metrics: metrics,
        elevation: elevation,
        nodes: nodes ?? this.nodes,
        alternates: alternates,
        hazards: hazards,
        portages: portages,
        solve: solve ?? this.solve,
      );
}

class Transition {
  Transition({
    required this.id,
    required this.fromSegmentId,
    required this.toSegmentId,
    this.fromMode,
    this.toMode,
    this.node,
    this.gapM,
    this.gapWarning,
  });

  final String id;
  final String fromSegmentId;
  final String toSegmentId;
  final String? fromMode;
  final String? toMode;
  final Node? node;
  final double? gapM;
  final bool? gapWarning;

  factory Transition.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'transition');
    final t = Transition(
      id: f.takeString('id')!,
      fromSegmentId: f.takeString('from_segment_id')!,
      toSegmentId: f.takeString('to_segment_id')!,
      fromMode: f.takeString('from_mode'),
      toMode: f.takeString('to_mode'),
      node: f.takeObject('node', Node.fromJson),
      gapM: f.takeNum('gap_m'),
      gapWarning: f.takeBool('gap_warning'),
    );
    f.done();
    return t;
  }

  Map<String, dynamic> toJson() => prune({
        'id': id,
        'from_segment_id': fromSegmentId,
        'to_segment_id': toSegmentId,
        'from_mode': fromMode,
        'to_mode': toMode,
        'node': node?.toJson(),
        'gap_m': gapM,
        'gap_warning': gapWarning,
      });
}

class Day {
  Day({
    required this.id,
    required this.index,
    required this.kind,
    this.roles = const [],
    this.date,
    this.title,
    this.note,
    this.location,
    this.segments = const [],
    this.transitions = const [],
    this.nodes = const [],
    this.hazards = const [],
    this.limits = const {},
    this.weights,
    this.metrics,
    this.cueSheet,
  });

  final String id;
  final int index;
  final String kind;
  final List<String> roles;
  final String? date;
  final String? title;
  final String? note;
  final List<double>? location;
  final List<Segment> segments;
  final List<Transition> transitions;
  final List<Node> nodes;
  final List<Hazard> hazards;
  final Map<String, Map<String, double>> limits;
  final WeightProfile? weights;
  final RollUp? metrics;
  final CueSheet? cueSheet;

  factory Day.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'day');
    final rawLimits = f.take('limits');
    final d = Day(
      id: f.takeString('id')!,
      index: f.takeInt('index')!,
      kind: f.takeString('kind')!,
      roles: f.takeStrings('roles'),
      date: f.takeString('date'),
      title: f.takeString('title'),
      note: f.takeString('note'),
      location: f.takeCoord('location'),
      segments: f.takeList('segments', Segment.fromJson),
      transitions: f.takeList('transitions', Transition.fromJson),
      nodes: f.takeList('nodes', Node.fromJson),
      hazards: f.takeList('hazards', Hazard.fromJson),
      limits: rawLimits == null ? const {} : _limitsFromJson(rawLimits),
      weights: f.takeObject('weights', WeightProfile.fromJson),
      metrics: f.takeObject('metrics', RollUp.fromJson),
      cueSheet: f.takeObject('cue_sheet', CueSheet.fromJson),
    );
    f.done();
    return d;
  }

  Map<String, dynamic> toJson() => prune({
        'id': id,
        'index': index,
        'kind': kind,
        'roles': roles,
        'date': date,
        'title': title,
        'note': note,
        'location': location,
        'segments': segments.map((s) => s.toJson()).toList(),
        'transitions': transitions.map((t) => t.toJson()).toList(),
        'nodes': nodes.map((n) => n.toJson()).toList(),
        'hazards': hazards.map((h) => h.toJson()).toList(),
        'limits': limits,
        'weights': weights?.toJson(),
        'metrics': metrics?.toJson(),
        'cue_sheet': cueSheet?.toJson(),
      });

  Day withSegments(List<Segment> value) => Day(
        id: id,
        index: index,
        kind: kind,
        roles: roles,
        date: date,
        title: title,
        note: note,
        location: location,
        segments: value,
        transitions: transitions,
        nodes: nodes,
        hazards: hazards,
        limits: limits,
        weights: weights,
        metrics: metrics,
        cueSheet: cueSheet,
      );
}

Map<String, Map<String, double>> _limitsFromJson(dynamic raw) =>
    (raw as Map).map((mode, band) => MapEntry(
          mode as String,
          (band as Map).map((k, v) => MapEntry(k as String, (v as num).toDouble())),
        ));

class Attribution {
  Attribution({
    required this.source,
    required this.licence,
    required this.credit,
    this.url,
  });

  final String source;
  final String licence;
  final String credit;
  final String? url;

  factory Attribution.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'attribution');
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
      prune({'source': source, 'licence': licence, 'credit': credit, 'url': url});
}

class Provenance {
  Provenance({
    this.producedBy,
    this.appVersion,
    this.sidecarVersion,
    this.attribution = const [],
  });

  final String? producedBy;
  final String? appVersion;
  final String? sidecarVersion;
  final List<Attribution> attribution;

  factory Provenance.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'provenance');
    final p = Provenance(
      producedBy: f.takeString('produced_by'),
      appVersion: f.takeString('app_version'),
      sidecarVersion: f.takeString('sidecar_version'),
      attribution: f.takeList('attribution', Attribution.fromJson),
    );
    f.done();
    return p;
  }

  Map<String, dynamic> toJson() => prune({
        'produced_by': producedBy,
        'app_version': appVersion,
        'sidecar_version': sidecarVersion,
        'attribution': attribution.map((a) => a.toJson()).toList(),
      });
}

class Trip {
  Trip({
    required this.schemaVersion,
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
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
  final Map<String, dynamic>? duration;
  final WeightProfile? defaultWeights;
  final Map<String, Map<String, double>> dayLimits;
  final List<Day> days;
  final RollUp? metrics;
  final Provenance? provenance;

  factory Trip.fromJson(Map<String, dynamic> json) {
    final f = _Fields(json, 'trip');
    final schemaVersion = f.takeString('schema_version')!;
    final id = f.takeString('id')!;
    final title = f.takeString('title')!;
    final createdAt = f.takeString('created_at')!;
    final updatedAt = f.takeString('updated_at')!;
    final duration = f.take('duration');
    WeightProfile? defaults;
    var dayLimits = <String, Map<String, double>>{};
    final rawDefaults = f.take('defaults');
    if (rawDefaults != null) {
      final d = _Fields(Map<String, dynamic>.from(rawDefaults as Map), 'defaults');
      defaults = d.takeObject('weights', WeightProfile.fromJson);
      final limits = d.take('day_limits');
      if (limits != null) dayLimits = _limitsFromJson(limits);
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
      duration: duration == null ? null : Map<String, dynamic>.from(duration as Map),
      defaultWeights: defaults,
      dayLimits: dayLimits,
      days: days,
      metrics: metrics,
      provenance: provenance,
    );
  }

  Map<String, dynamic> toJson() => prune({
        'schema_version': schemaVersion,
        'id': id,
        'title': title,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'duration': duration,
        'defaults': prune({
          'weights': defaultWeights?.toJson(),
          'day_limits': dayLimits.isEmpty ? null : dayLimits,
        }),
        'days': days.map((d) => d.toJson()).toList(),
        'metrics': metrics?.toJson(),
        'provenance': provenance?.toJson(),
      });

  Trip withDays(List<Day> value) => Trip(
        schemaVersion: schemaVersion,
        id: id,
        title: title,
        createdAt: createdAt,
        updatedAt: updatedAt,
        duration: duration,
        defaultWeights: defaultWeights,
        dayLimits: dayLimits,
        days: value,
        metrics: metrics,
        provenance: provenance,
      );

  int get segmentCount =>
      days.fold(0, (sum, day) => sum + day.segments.length);

  /// Every drawn vertex the client holds — alternates included, since an alternate
  /// is rendered and stored exactly like the route it hangs off.
  int get vertexCount => days.fold(
      0,
      (sum, day) =>
          sum +
          day.segments.fold(
              0,
              (s, seg) =>
                  s +
                  (seg.geometry?.coordinates.length ?? 0) +
                  seg.alternates.fold(
                      0, (a, alt) => a + alt.geometry.coordinates.length)));
}
