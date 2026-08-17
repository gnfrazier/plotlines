/// `$defs/node_kind`, `$defs/media_ref`, `$defs/narration`, `$defs/scheduled_window`,
/// `$defs/node`.
library;

import 'json_utils.dart';

/// FR21 / C5, FR12 / B3, FR37 / E1. `regroup` is a kind rather than a flag on a
/// waypoint because a regroup point is what a Character looks for, and a boolean
/// hides it from every list that groups by kind.
enum NodeKind {
  waypoint,
  regroup,
  restStop,
  poi,
  transition,
  start,
  finish,
  via,
  portageStart,
  portageEnd,
  event;

  static NodeKind fromWire(String value) => switch (value) {
        'waypoint' => NodeKind.waypoint,
        'regroup' => NodeKind.regroup,
        'rest_stop' => NodeKind.restStop,
        'poi' => NodeKind.poi,
        'transition' => NodeKind.transition,
        'start' => NodeKind.start,
        'finish' => NodeKind.finish,
        'via' => NodeKind.via,
        'portage_start' => NodeKind.portageStart,
        'portage_end' => NodeKind.portageEnd,
        'event' => NodeKind.event,
        _ => throw FormatException('unknown node_kind "$value"'),
      };

  String get wireValue => switch (this) {
        NodeKind.waypoint => 'waypoint',
        NodeKind.regroup => 'regroup',
        NodeKind.restStop => 'rest_stop',
        NodeKind.poi => 'poi',
        NodeKind.transition => 'transition',
        NodeKind.start => 'start',
        NodeKind.finish => 'finish',
        NodeKind.via => 'via',
        NodeKind.portageStart => 'portage_start',
        NodeKind.portageEnd => 'portage_end',
        NodeKind.event => 'event',
      };
}

/// FR37 / E1 and FR40 / E4. A relative path into the trip's media root, never an
/// absolute device path and never a binary blob.
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
    final f = JsonFields(json, 'media_ref');
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

  Map<String, dynamic> toJson() => pruneJson({
        'id': id,
        'kind': kind,
        'path': path,
        'caption': caption,
        'bytes': bytes,
        'duration_s': durationS == null ? null : finite(durationS!, 'media_ref.duration_s'),
      });
}

/// FR40/FR41 / E4 — the AUTHORING half only. Playback is field execution (H2/FR49),
/// out of desktop MVP scope.
class Narration {
  Narration({required this.triggerDistanceM, this.mediaId, this.text});

  final double triggerDistanceM;
  final String? mediaId;
  final String? text;

  factory Narration.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'narration');
    final n = Narration(
      triggerDistanceM: f.takeNum('trigger_distance_m')!,
      mediaId: f.takeString('media_id'),
      text: f.takeString('text'),
    );
    f.done();
    return n;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'trigger_distance_m': finite(triggerDistanceM, 'narration.trigger_distance_m'),
        'media_id': mediaId,
        'text': text,
      });
}

/// FR28 / C12 — a fixed time window the day's pace has to meet. UTC plus IANA zone,
/// because a ferry leaves on local time and an offset alone loses that across DST.
class ScheduledWindow {
  ScheduledWindow({required this.opensAt, this.closesAt, this.timezone, this.detail});

  final String opensAt;
  final String? closesAt;
  final String? timezone;
  final String? detail;

  factory ScheduledWindow.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'scheduled_window');
    final w = ScheduledWindow(
      opensAt: f.takeString('opens_at')!,
      closesAt: f.takeString('closes_at'),
      timezone: f.takeString('timezone'),
      detail: f.takeString('detail'),
    );
    f.done();
    return w;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'opens_at': opensAt,
        'closes_at': closesAt,
        'timezone': timezone,
        'detail': detail,
      });
}

/// A curated node: the unit Epic E hangs on. [coord] and [distanceAlongM] are both
/// stored — cue sheets order by distance, maps draw the coordinate, and deriving one
/// from the other on every read is how they drift.
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
  final NodeKind kind;
  final Coord coord;
  final double? distanceAlongM;
  final String? title;
  final String? note;
  final List<MediaRef> media;

  /// C5 — water, toilets, food, shelter.
  final List<String> amenities;
  final String? poiType;
  final String? arcStage;
  final Narration? narration;

  /// FR12 / B3 — a transition node's parking / gear-stash / put-in instructions.
  final String? instructions;

  /// FR28 / C12 — a time-bound event pinned to this node.
  final ScheduledWindow? scheduled;

  factory Node.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'node');
    final n = Node(
      id: f.takeString('id')!,
      kind: NodeKind.fromWire(f.takeString('kind')!),
      coord: checkCoord(f.takeCoord('coord')!, 'node.coord'),
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

  Map<String, dynamic> toJson() => pruneJson({
        'id': id,
        'kind': kind.wireValue,
        'coord': checkCoord(coord, 'node.coord'),
        'distance_along_m':
            distanceAlongM == null ? null : finite(distanceAlongM!, 'node.distance_along_m'),
        'title': title,
        'note': note,
        'media': media.isEmpty ? null : media.map((m) => m.toJson()).toList(),
        'amenities': amenities.isEmpty ? null : amenities,
        'poi_type': poiType,
        'arc_stage': arcStage,
        'narration': narration?.toJson(),
        'instructions': instructions,
        'scheduled': scheduled?.toJson(),
      });
}
