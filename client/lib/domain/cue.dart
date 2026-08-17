/// `$defs/cue`, `$defs/cue_sheet`.
library;

import 'json_utils.dart';

/// F1/FR46's derived cue (SPIKE-21 owns derivation; this is where its output
/// lands). `kind` is one of `turn` | `surface` | `node` | `hazard` | `event`
/// | `portage` | `transition` | `alternate` | `start` | `finish`.
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

  /// e.g. `left` / `right` / `slight_left` — SPIKE-21's vocabulary.
  final String? modifier;
  final double? bearingDeg;

  /// The node/hazard/portage/alternate this cue was derived from, if any.
  final String? refId;
  final String? segmentId;

  /// This cue stands on road the route has already used — the return leg of
  /// a via-node spur (SPIKE-01's lollipop). Absent means fresh road.
  final bool? retrace;

  factory Cue.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'cue');
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

  Map<String, dynamic> toJson() => pruneJson({
        'id': id,
        'sequence': sequence,
        'distance_along_m': finite(distanceAlongM, 'cue.distance_along_m'),
        'kind': kind,
        'instruction': instruction,
        'modifier': modifier,
        'bearing_deg': bearingDeg == null ? null : finite(bearingDeg!, 'cue.bearing_deg'),
        'ref_id': refId,
        'segment_id': segmentId,
        'retrace': retrace,
      });
}

/// F1 / FR46 — per-day, derived, regenerable. `derivedFrom*` records which
/// geometry it was built against so a stale sheet is detectable, not merely
/// wrong.
class CueSheet {
  CueSheet({
    required this.generatedAt,
    this.cues = const [],
    this.generator,
    this.derivedFromSegmentIds = const [],
    this.derivedFromGeometryDigest,
  });

  final String generatedAt;
  final String? generator;
  final List<String> derivedFromSegmentIds;
  final String? derivedFromGeometryDigest;
  final List<Cue> cues;

  factory CueSheet.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'cue_sheet');
    final generatedAt = f.takeString('generated_at')!;
    final generator = f.takeString('generator');
    final derived = f.take('derived_from');
    var segmentIds = const <String>[];
    String? digest;
    if (derived != null) {
      final d = JsonFields(Map<String, dynamic>.from(derived as Map), 'cue_sheet.derived_from');
      segmentIds = d.takeStrings('segment_ids');
      digest = d.takeString('geometry_digest');
      d.done();
    }
    final cues = f.takeList('cues', Cue.fromJson);
    f.done();
    return CueSheet(
      generatedAt: generatedAt,
      generator: generator,
      derivedFromSegmentIds: segmentIds,
      derivedFromGeometryDigest: digest,
      cues: cues,
    );
  }

  Map<String, dynamic> toJson() => pruneJson({
        'generated_at': generatedAt,
        'generator': generator,
        'derived_from': pruneJson({
          'segment_ids': derivedFromSegmentIds.isEmpty ? null : derivedFromSegmentIds,
          'geometry_digest': derivedFromGeometryDigest,
        }),
        'cues': cues.map((c) => c.toJson()).toList(),
      });
}
