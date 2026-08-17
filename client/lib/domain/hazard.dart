/// `$defs/hazard`.
library;

import 'json_utils.dart';

/// FR27 / C11 — attachable to a segment, a node, or a point along a route. Severity
/// is an enum-valued string, not a number: "mandatory re-route" is a different kind
/// of thing from "caution", and an ordinal invites arithmetic on it.
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

  /// One of `caution` | `high` | `mandatory_reroute`.
  final String severity;
  final String? title;
  final String? safetyNote;
  final List<String> requiredGear;
  final Coord? coord;
  final double? distanceAlongM;

  /// Set when the hazard is anchored to a node rather than a point.
  final String? nodeId;

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
      });
}
