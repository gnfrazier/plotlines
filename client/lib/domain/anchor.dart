/// `$defs/role_kind`, `$defs/reveal_policy`, `$defs/role`, `$defs/anchor_provenance`,
/// `$defs/anchor` — the anchor/role object model (ARCH §7.8, `[NEW v2.0]`). PRD
/// FR106, FR110, Story O1.
///
/// An Author **promotes** a candidate ([Candidate], `candidate.dart`), a cluster
/// proposal, or a hand-placed location into an [Anchor] — one object per place,
/// carrying a **role set** ([RoleKind.narrative] / [RoleKind.provision] /
/// [RoleKind.station]) rather than a single type. The national-monument case is why
/// the set exists: one anchor holds a narrative role (the statue) and a provision
/// role (restrooms, water), one arrival, one pin — a type field cannot express both.
///
/// Deliberately absent from [Role], reserved for later stories per ARCH §7.8's own
/// note that the four properties shown there are "the whole point," not the full
/// set: station activity (FR109 / O4) and arc stage (FR38 / O6). Each adds its own
/// field to this file, the schema, and the core Python mirror together when it is
/// built.
///
/// [Role.coord] (FR107 / O2) is a role's optional point offset from its anchor, so
/// the overlook 400 m up the spur can trigger at the overlook rather than the
/// parking lot at the anchor's own coord. [Anchor.area] / [Role.area] (FR108,
/// FR126 / O3) are this file's polygon geometry: a historic district, an
/// arboretum, or a main-street block is first-class rather than approximated as a
/// point with a radius. [Anchor.area] also serves as a cluster boundary (in place
/// of point-plus-radius) via [Anchor.containsPoint], and entry into it is the
/// trigger event FR126 specifies — the debounce for that event lives in
/// `area_trigger.dart`, since it is the field runtime's concern, not this
/// (not-yet-built) tier's.
library;

import 'node.dart' show MediaRef;
import 'json_utils.dart';

/// FR106 / O1. A role SET, not a type field: an anchor may carry more than one of
/// these at once.
enum RoleKind {
  narrative,
  provision,
  station;

  static RoleKind fromWire(String value) => switch (value) {
        'narrative' => RoleKind.narrative,
        'provision' => RoleKind.provision,
        'station' => RoleKind.station,
        _ => throw FormatException('unknown role_kind "$value"'),
      };

  String get wireValue => switch (this) {
        RoleKind.narrative => 'narrative',
        RoleKind.provision => 'provision',
        RoleKind.station => 'station',
      };
}

/// FR114 / O5. Lives on the role, never the anchor (ARCH §7.8) — that is what lets
/// the restroom stay always-visible while the statue waits for arrival on the same
/// anchor.
enum RevealPolicy {
  alwaysVisible,
  onArrival;

  static RevealPolicy fromWire(String value) => switch (value) {
        'always_visible' => RevealPolicy.alwaysVisible,
        'on_arrival' => RevealPolicy.onArrival,
        _ => throw FormatException('unknown reveal_policy "$value"'),
      };

  String get wireValue => switch (this) {
        RevealPolicy.alwaysVisible => 'always_visible',
        RevealPolicy.onArrival => 'on_arrival',
      };
}

/// FR108 / O3 — where a polygon area came from: drawn by the Author, or adopted
/// from a source feature's own area geometry at promotion. Never `solved` — no
/// engine produces an anchor's area the way one produces a route (contrast
/// [node.dart]'s `LineString.source`, which does include it).
enum AreaSource {
  authored,
  imported;

  static AreaSource fromWire(String value) => switch (value) {
        'authored' => AreaSource.authored,
        'imported' => AreaSource.imported,
        _ => throw FormatException('unknown polygon source "$value"'),
      };

  String get wireValue => switch (this) {
        AreaSource.authored => 'authored',
        AreaSource.imported => 'imported',
      };
}

/// FR108, FR126 / O3 — RFC 7946 Polygon. [rings] is one or more closed rings
/// (first exterior, any further ones holes); [checkRing] normalises winding on
/// every read and write so an Author's drawing order never changes the stored
/// form (ARCH §11.6, D37).
class Area {
  Area({required this.rings, this.source = AreaSource.authored}) {
    if (rings.isEmpty) {
      throw ArgumentError('polygon.coordinates needs at least one ring');
    }
  }

  final List<Ring> rings;
  final AreaSource source;

  factory Area.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'polygon');
    final type = f.takeString('type');
    if (type != 'Polygon') {
      throw FormatException('geometry type "$type" is not a Polygon');
    }
    final a = Area(
      rings: checkPolygonRings(f.takeRings('coordinates'), 'polygon.coordinates'),
      source: AreaSource.fromWire(f.takeString('source')!),
    );
    f.done();
    return a;
  }

  Map<String, dynamic> toJson() => {
        'type': 'Polygon',
        'coordinates': checkPolygonRings(rings, 'polygon.coordinates'),
        'source': source.wireValue,
      };

  /// Ray-casting point-in-polygon: inside the exterior ring and outside every
  /// hole. The mechanism FR108's "area can serve as a cluster boundary instead
  /// of point-plus-radius" and FR126's "entry into the polygon is a trigger
  /// event" both resolve down to.
  bool containsPoint(Coord point) {
    final normalized = checkPolygonRings(rings, 'polygon.coordinates');
    final exterior = normalized.first;
    final holes = normalized.skip(1);
    if (!_ringContainsPoint(exterior, point)) return false;
    return !holes.any((hole) => _ringContainsPoint(hole, point));
  }
}

bool _ringContainsPoint(Ring ring, Coord point) {
  final x = point[0], y = point[1];
  var inside = false;
  final n = ring.length - 1; // last position repeats the first
  for (var i = 0; i < n; i++) {
    final x1 = ring[i][0], y1 = ring[i][1];
    final x2 = ring[i + 1][0], y2 = ring[i + 1][1];
    if ((y1 > y) != (y2 > y)) {
      final xAtY = x1 + (y - y1) * (x2 - x1) / (y2 - y1);
      if (x < xAtY) inside = !inside;
    }
  }
  return inside;
}

/// FR106, FR107, FR110 / O1, O2 — one entry in an anchor's role set. [reveal] and
/// content ([title]/[note]/[media]) may be left unset at promotion and decided
/// later (O1's AC: "set here or later"); nothing here defaults [reveal] on the
/// Author's behalf — that judgment (provision defaults always-visible, hazard/crux
/// is never gated) is O5's (FR114, FR115), not O1's.
///
/// [coord] (FR107 / O2) is the role's own optional point offset from its anchor.
/// `null` is the common case an anchor with no offsets must cost nothing for (O2's
/// AC) — trigger and rendering code reads [Anchor.roleGeometry], never this field
/// directly, so that fallback lives in exactly one place.
///
/// [area] (FR108 / O3) is the same fallback shape as [coord], one level up: a
/// role's own polygon offset from its anchor's area — [Anchor.roleArea] is the
/// one place that fallback lives, mirroring [Anchor.roleGeometry].
class Role {
  Role({
    required this.kind,
    required this.id,
    this.coord,
    this.area,
    this.reveal,
    this.title,
    this.note,
    this.media = const [],
  });

  final String id;
  final RoleKind kind;
  final Coord? coord;
  final Area? area;
  final RevealPolicy? reveal;
  final String? title;
  final String? note;
  final List<MediaRef> media;

  Role copyWith({
    RoleKind? kind,
    Coord? coord,
    bool clearCoord = false,
    Area? area,
    bool clearArea = false,
    RevealPolicy? reveal,
    bool clearReveal = false,
    String? title,
    String? note,
    List<MediaRef>? media,
  }) =>
      Role(
        id: id,
        kind: kind ?? this.kind,
        coord: clearCoord ? null : (coord ?? this.coord),
        area: clearArea ? null : (area ?? this.area),
        reveal: clearReveal ? null : (reveal ?? this.reveal),
        title: title ?? this.title,
        note: note ?? this.note,
        media: media ?? this.media,
      );

  factory Role.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'role');
    final id = f.takeString('id')!;
    final kind = RoleKind.fromWire(f.takeString('kind')!);
    final coord = f.takeCoord('coord');
    final area = f.takeObject('area', Area.fromJson);
    final rawReveal = f.takeString('reveal');
    final r = Role(
      id: id,
      kind: kind,
      coord: coord == null ? null : checkCoord(coord, 'role.coord'),
      area: area,
      reveal: rawReveal == null ? null : RevealPolicy.fromWire(rawReveal),
      title: f.takeString('title'),
      note: f.takeString('note'),
      media: f.takeList('media', MediaRef.fromJson),
    );
    f.done();
    return r;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'id': id,
        'kind': kind.wireValue,
        'coord': coord == null ? null : checkCoord(coord!, 'role.coord'),
        'area': area?.toJson(),
        'reveal': reveal?.wireValue,
        'title': title,
        'note': note,
        'media': media.isEmpty ? null : media.map((m) => m.toJson()).toList(),
      });
}

/// FR106 / O1 — where a promoted anchor came from. Copied at promotion, never a
/// live reference (ARCH §4.2, P10): an anchor must survive a candidate-cache wipe.
/// [sourceId] is carried only so promotion can recognise "this candidate is
/// already an anchor" in the current session — it is never dereferenced.
enum AnchorSourceKind {
  candidate,
  cluster,
  handPlaced;

  static AnchorSourceKind fromWire(String value) => switch (value) {
        'candidate' => AnchorSourceKind.candidate,
        'cluster' => AnchorSourceKind.cluster,
        'hand_placed' => AnchorSourceKind.handPlaced,
        _ => throw FormatException('unknown anchor_provenance.kind "$value"'),
      };

  String get wireValue => switch (this) {
        AnchorSourceKind.candidate => 'candidate',
        AnchorSourceKind.cluster => 'cluster',
        AnchorSourceKind.handPlaced => 'hand_placed',
      };
}

class AnchorProvenance {
  const AnchorProvenance({required this.kind, this.sourceId, this.layer, this.tags = const {}});

  final AnchorSourceKind kind;
  final String? sourceId;
  final String? layer;
  final Map<String, String> tags;

  factory AnchorProvenance.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'anchor_provenance');
    final p = AnchorProvenance(
      kind: AnchorSourceKind.fromWire(f.takeString('kind')!),
      sourceId: f.takeString('source_id'),
      layer: f.takeString('layer'),
      tags: (f.take('tags') as Map?)?.map((k, v) => MapEntry(k as String, v as String)) ??
          const {},
    );
    f.done();
    return p;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'kind': kind.wireValue,
        'source_id': sourceId,
        'layer': layer,
        'tags': tags,
      });
}

/// FR106, FR110, FR108 / O1, O3 — a promoted place: one object per place,
/// carrying a role set (ARCH decision D-A). [coord] is always required — a
/// representative point every consumer that has not adopted [area] can still
/// render, sort, or measure from. [area] (FR108 / O3) is additionally set
/// when the place is a district, block, or reserve rather than a pin.
class Anchor {
  Anchor({
    required this.id,
    required this.coord,
    required this.roles,
    this.title,
    this.area,
    this.provenance,
  }) {
    if (roles.isEmpty) {
      throw ArgumentError('anchor $id: FR106 requires at least one role');
    }
  }

  final String id;
  final Coord coord;
  final String? title;
  final Area? area;
  final List<Role> roles;
  final AnchorProvenance? provenance;

  bool hasRole(RoleKind kind) => roles.any((r) => r.kind == kind);

  /// FR107 / O2 — the coord a trigger, marker, or export feature for [role]
  /// must use: the role's own offset if it carries one, otherwise this
  /// anchor's coord. This is the one place that fallback lives (ARCH §6.2:
  /// "the index is built over roles, not anchors" — a one-word change with
  /// a real consequence if it's read from the wrong spot).
  Coord roleGeometry(Role role) => role.coord ?? coord;

  /// FR108 / O3 — the polygon a trigger, marker, or export feature for [role]
  /// must use, when one exists: the role's own area offset if it carries
  /// one, otherwise this anchor's own [area], otherwise `null` (the
  /// role/anchor is a point, not an area). Mirrors [roleGeometry].
  Area? roleArea(Role role) => role.area ?? area;

  /// FR108's "an area can serve as a cluster boundary instead of
  /// point-plus-radius": true when this anchor has an [area] and it contains
  /// [point]. An anchor with no area (the common, point-anchor case) never
  /// contains anything — it has no boundary to test against.
  bool containsPoint(Coord point) => area?.containsPoint(point) ?? false;

  Anchor copyWith({
    Coord? coord,
    String? title,
    Area? area,
    bool clearArea = false,
    List<Role>? roles,
    AnchorProvenance? provenance,
  }) =>
      Anchor(
        id: id,
        coord: coord ?? this.coord,
        title: title ?? this.title,
        area: clearArea ? null : (area ?? this.area),
        roles: roles ?? this.roles,
        provenance: provenance ?? this.provenance,
      );

  factory Anchor.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'anchor');
    final a = Anchor(
      id: f.takeString('id')!,
      coord: checkCoord(f.takeCoord('coord')!, 'anchor.coord'),
      title: f.takeString('title'),
      area: f.takeObject('area', Area.fromJson),
      roles: f.takeList('roles', Role.fromJson),
      provenance: f.takeObject('provenance', AnchorProvenance.fromJson),
    );
    f.done();
    return a;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'id': id,
        'coord': checkCoord(coord, 'anchor.coord'),
        'area': area?.toJson(),
        'title': title,
        'roles': roles.map((r) => r.toJson()).toList(),
        'provenance': provenance?.toJson(),
      });
}
