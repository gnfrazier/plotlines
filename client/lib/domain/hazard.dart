/// `$defs/hazard`.
library;

import 'json_utils.dart';

/// FR27, FR115 / C11 — a hazard or technical-crux warning, attachable to a segment
/// (a route or a transit leg), a day, a node, a promoted anchor, or a point along a
/// route. Severity is an enum-valued string, not a number: "mandatory re-route" is a
/// different kind of thing from "caution", and an ordinal invites arithmetic on it.
/// A hazard carries no reveal field and is never subject to reveal policy (FR115):
/// it is always visible, and no Author setting can hide one.
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
    this.anchorId,
  }) : assert(nodeId == null || anchorId == null,
            'hazard $id: node_id and anchor_id are mutually exclusive');

  final String id;

  /// One of `caution` | `high` | `mandatory_reroute`.
  final String severity;
  final String? title;
  final String? safetyNote;
  final List<String> requiredGear;
  final Coord? coord;
  final double? distanceAlongM;

  /// Set when the hazard is anchored to a node rather than a point.
  final String? nodeId;

  /// FR27 / C11 — set when the hazard is pinned to a promoted anchor rather
  /// than a node or a point. Mutually exclusive with [nodeId].
  final String? anchorId;

  factory Hazard.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'hazard');
    final rawCoord = f.takeCoord('coord');
    final h = Hazard(
      id: f.takeString('id')!,
      severity: f.takeString('severity')!,
      title: f.takeString('title'),
      safetyNote: f.takeString('safety_note'),
      requiredGear: f.takeStrings('required_gear'),
      coord: rawCoord == null ? null : checkCoord(rawCoord, 'hazard.coord'),
      distanceAlongM: f.takeNum('distance_along_m'),
      nodeId: f.takeString('node_id'),
      anchorId: f.takeString('anchor_id'),
    );
    f.done();
    return h;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'id': id,
        'severity': severity,
        'title': title,
        'safety_note': safetyNote,
        'required_gear': requiredGear.isEmpty ? null : requiredGear,
        'coord': coord == null ? null : checkCoord(coord!, 'hazard.coord'),
        'distance_along_m':
            distanceAlongM == null ? null : finite(distanceAlongM!, 'hazard.distance_along_m'),
        'node_id': nodeId,
        'anchor_id': anchorId,
      });
}
