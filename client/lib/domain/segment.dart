/// `$defs/line_string`, `$defs/portage`, `$defs/alternate`, `$defs/solve_provenance`,
/// `$defs/segment`.
library;

import 'band.dart';
import 'hazard.dart';
import 'json_utils.dart';
import 'node.dart';
import 'route_metrics.dart';
import 'weight_profile.dart';

/// RFC 7946 LineString. `source` records whether the engine solved it or the Author
/// drew it (FR15's portages, any paddling geometry) — a consumer that cannot tell the
/// two apart presents a hand-drawn line with a solved line's authority.
class LineString {
  LineString({required this.coordinates, this.source = 'solved'});

  final List<Coord> coordinates;

  /// One of `solved` | `authored` | `imported`.
  final String source;

  factory LineString.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'line_string');
    final type = f.takeString('type');
    if (type != 'LineString') {
      throw FormatException('geometry type "$type" is not a LineString');
    }
    final g = LineString(
      coordinates: f.takeCoords('coordinates'),
      source: f.takeString('source')!,
    );
    f.done();
    return g;
  }

  Map<String, dynamic> toJson() => {
        'type': 'LineString',
        'coordinates':
            coordinates.map((c) => checkCoord(c, 'line_string.coordinates')).toList(),
        'source': source,
      };
}

/// FR15 / B6 — Author-drawn, always (no open portage data; the app must never claim a
/// route it does not have). Its distance is kept OUT of the parent segment's water
/// distance.
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
  final LineString geometry;

  /// One of `river_left` | `river_right`.
  final String? exitBank;
  final double? distanceM;
  final String? surface;
  final double? elevationChangeM;

  /// Dams, falls — flags a prominent warning.
  final bool? mandatory;
  final String? note;

  factory Portage.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'portage');
    final p = Portage(
      id: f.takeString('id')!,
      geometry: f.takeObject('geometry', LineString.fromJson)!,
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

  Map<String, dynamic> toJson() => pruneJson({
        'id': id,
        'geometry': geometry.toJson(),
        'exit_bank': exitBank,
        'distance_m': distanceM == null ? null : finite(distanceM!, 'portage.distance_m'),
        'surface': surface,
        'elevation_change_m': elevationChangeM == null
            ? null
            : finite(elevationChangeM!, 'portage.elevation_change_m'),
        'mandatory': mandatory,
        'note': note,
      });
}

/// FR20 / C4 [AMENDED v2.0] — a tagged secondary path on a segment, visible to
/// Characters on map and cue sheet.
///
/// Two authoring intents ([intent]). An `accommodation` alternate adjusts effort
/// only — `bypass` (easiest) / `extension` (challenge) — and is the H6 effort
/// toggle a Character may take (`character_variant.dart`). A `branch` alternate is
/// a story-shaped choice that carries its own content on the path: its own
/// [anchorIds], [narration], [reveal] policy, and [note] prose ("the long way
/// past the abandoned mine"). A branch is chosen in the field (FR125 / P2), never
/// as an effort toggle, so `chooseAlternate` rejects one.
///
/// [kind] tags the shape either way — for a branch it reads as the direct way
/// (`bypass`) versus the long way round (`extension`).
class Alternate {
  Alternate({
    required this.id,
    required this.kind,
    required this.geometry,
    this.intent = 'accommodation',
    this.label,
    this.metrics,
    this.elevation,
    this.divergesAtM,
    this.rejoinsAtM,
    this.note,
    this.anchorIds = const [],
    this.narration,
    this.reveal,
  })  : assert(
          intent == 'accommodation' || intent == 'branch',
          'alternate intent must be accommodation or branch, got "$intent"',
        ),
        assert(
          intent == 'branch' ||
              (note == null && anchorIds.isEmpty && narration == null && reveal == null),
          'note / anchorIds / narration / reveal are branch-alternate content; '
          'an accommodation alternate carries none of them',
        );

  final String id;

  /// One of `accommodation` (effort toggle, the v1.0 ladder) | `branch` (a
  /// story choice with its own content). Absent on the wire means
  /// `accommodation`.
  final String intent;

  /// One of `bypass` | `extension`.
  final String kind;
  final LineString geometry;
  final String? label;
  final RouteMetrics? metrics;
  final Elevation? elevation;

  /// Distance along the parent segment where the alternate diverges from it.
  final double? divergesAtM;

  /// Distance along the parent segment where the alternate rejoins it.
  final double? rejoinsAtM;

  /// Branch alternates only — the Author's prose for what is different on this
  /// path. Null on an accommodation alternate, whose difference is effort.
  final String? note;

  /// Branch alternates only — trip-scoped anchors on this path, by id (a
  /// reference, never a copy — the same rule as a segment's via anchors).
  final List<String> anchorIds;

  /// Branch alternates only — narration attached to the branch itself.
  final Narration? narration;

  /// Branch alternates only — reveal policy for this branch's own narrative
  /// content. One of `always_visible` | `on_arrival`; null falls back to each
  /// referenced anchor's own roles.
  final String? reveal;

  /// True when this is a branch alternate — a story choice, not an effort toggle.
  bool get isBranch => intent == 'branch';

  factory Alternate.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'alternate');
    final a = Alternate(
      id: f.takeString('id')!,
      intent: f.takeString('intent') ?? 'accommodation',
      kind: f.takeString('kind')!,
      label: f.takeString('label'),
      geometry: f.takeObject('geometry', LineString.fromJson)!,
      metrics: f.takeObject('metrics', RouteMetrics.fromJson),
      elevation: f.takeObject('elevation', Elevation.fromJson),
      divergesAtM: f.takeNum('diverges_at_m'),
      rejoinsAtM: f.takeNum('rejoins_at_m'),
      note: f.takeString('note'),
      anchorIds: f.takeStrings('anchor_ids'),
      narration: f.takeObject('narration', Narration.fromJson),
      reveal: f.takeString('reveal'),
    );
    f.done();
    return a;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'id': id,
        'intent': intent,
        'kind': kind,
        'label': label,
        'geometry': geometry.toJson(),
        'metrics': metrics?.toJson(),
        'elevation': elevation?.toJson(),
        'diverges_at_m': divergesAtM == null ? null : finite(divergesAtM!, 'alternate.diverges_at_m'),
        'rejoins_at_m': rejoinsAtM == null ? null : finite(rejoinsAtM!, 'alternate.rejoins_at_m'),
        'note': note,
        'anchor_ids': anchorIds.isEmpty ? null : anchorIds,
        'narration': narration?.toJson(),
        'reveal': reveal,
      });

  /// True when this alternate is holding any of the four things only a branch
  /// may carry. What the branch→accommodation conversion prompt (FR20 [AMENDED
  /// v2.0] / C4, Flow 11 §06) itemises before it asks.
  bool get hasBranchContent =>
      note != null || anchorIds.isNotEmpty || narration != null || reveal != null;

  /// A copy with the given fields replaced. [intent] is deliberately not a
  /// parameter — moving between the two intents goes through [asBranch] /
  /// [asAccommodation], which keep the constructor's content invariant.
  /// `clearX` drops an optional field (a bare `null` argument leaves it
  /// unchanged); the four branch-content clears are only meaningful while
  /// [intent] is `branch`.
  Alternate copyWith({
    String? kind,
    LineString? geometry,
    String? label,
    bool clearLabel = false,
    RouteMetrics? metrics,
    bool clearMetrics = false,
    Elevation? elevation,
    bool clearElevation = false,
    double? divergesAtM,
    bool clearDivergesAtM = false,
    double? rejoinsAtM,
    bool clearRejoinsAtM = false,
    String? note,
    bool clearNote = false,
    List<String>? anchorIds,
    Narration? narration,
    bool clearNarration = false,
    String? reveal,
    bool clearReveal = false,
  }) =>
      Alternate(
        id: id,
        intent: intent,
        kind: kind ?? this.kind,
        geometry: geometry ?? this.geometry,
        label: clearLabel ? null : (label ?? this.label),
        metrics: clearMetrics ? null : (metrics ?? this.metrics),
        elevation: clearElevation ? null : (elevation ?? this.elevation),
        divergesAtM: clearDivergesAtM ? null : (divergesAtM ?? this.divergesAtM),
        rejoinsAtM: clearRejoinsAtM ? null : (rejoinsAtM ?? this.rejoinsAtM),
        note: clearNote ? null : (note ?? this.note),
        anchorIds: anchorIds ?? this.anchorIds,
        narration: clearNarration ? null : (narration ?? this.narration),
        reveal: clearReveal ? null : (reveal ?? this.reveal),
      );

  /// This alternate as a `branch` — a story choice that may carry its own
  /// content. Shape ([kind], [geometry], [label], [metrics]) is kept; the
  /// branch-content fields start empty, to be authored. A no-op if already a
  /// branch.
  Alternate asBranch() {
    if (isBranch) return this;
    return Alternate(
      id: id,
      intent: 'branch',
      kind: kind,
      geometry: geometry,
      label: label,
      metrics: metrics,
      elevation: elevation,
      divergesAtM: divergesAtM,
      rejoinsAtM: rejoinsAtM,
    );
  }

  /// This alternate as an `accommodation` — an effort option that carries
  /// nothing of its own. [note], [anchorIds], [narration] and [reveal] are
  /// dropped (the constructor forbids them on an accommodation alternate); the
  /// referenced anchors themselves are untouched — they were never copies
  /// (Flow 11 §06). A no-op if already an accommodation.
  Alternate asAccommodation() {
    if (!isBranch) return this;
    return Alternate(
      id: id,
      intent: 'accommodation',
      kind: kind,
      geometry: geometry,
      label: label,
      metrics: metrics,
      elevation: elevation,
      divergesAtM: divergesAtM,
      rejoinsAtM: rejoinsAtM,
    );
  }
}

/// How this geometry came to exist. Kept per segment, not per trip, because a
/// multimodal day mixes solved and Author-drawn legs.
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

  /// Loop shapes: did the circuit return to its start node?
  final bool? closed;

  /// FR8a — was every via-node actually on the path? Never inferred from the geometry.
  final bool? hitVia;

  /// The authored inputs have changed since this geometry was solved: `geometry`,
  /// `metrics` and `elevation` describe a route the Author is no longer asking for.
  /// The client sets it; only a solve clears it.
  final bool? stale;

  factory SolveProvenance.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'solve_provenance');
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

  Map<String, dynamic> toJson() => pruneJson({
        'engine_version': engineVersion,
        'graph_region': graphRegion,
        'solve_ms': solveMs == null ? null : finite(solveMs!, 'solve_provenance.solve_ms'),
        'solver_calls': solverCalls,
        'solved_at': solvedAt,
        'closed': closed,
        'hit_via': hitVia,
        'stale': stale,
      });

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
}

/// FR128 / A11 — a mode-legal but noteworthy edge the resolved route rolls
/// over: `bicycle=dismount`, `barrier=gate`, `ford=yes`, and the like. The
/// routing engine keeps the edge (hard exclusions are dropped server-side so
/// the route stays legal — `routing/access.py`) and tags it so the response
/// can name it rather than silently routing through it. [from] and [to] are
/// the graph node ids of the hop; [flags] are the raw OSM-shaped `key=value`
/// tag values, in the engine's path order. Filled by the sidecar on every
/// `/segments/generate` shape; the Author never edits one, so there is no
/// `copyWith`.
class SurfacedConstraint {
  SurfacedConstraint({
    required this.from,
    required this.to,
    this.flags = const [],
  });

  final int from;
  final int to;
  final List<String> flags;

  factory SurfacedConstraint.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'surfaced_constraint');
    final s = SurfacedConstraint(
      from: f.takeInt('from')!,
      to: f.takeInt('to')!,
      flags: f.takeStrings('flags'),
    );
    f.done();
    return s;
  }

  Map<String, dynamic> toJson() => {
        'from': from,
        'to': to,
        'flags': flags,
      };
}

/// FR10 / B1 — one routed (or Author-drawn) leg with a start, an end, and a primary
/// mode. `shape == point_to_point` requires [end] (schema `allOf`); loop and
/// out_and_back do not. This is the "passage" FR38/O6 names: [arcStage] is this
/// passage's own stage in the day's story, distinct from any arc stage on a
/// [Node] along it — the long grind between two anchors can itself be the rising
/// action, not just the places at either end.
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
    this.surfacedConstraints = const [],
    this.solve,
    this.arcStage,
    this.note,
    this.media = const [],
  });

  final String id;
  final String? title;

  /// One of `travel_mode.dart`'s [kTravelModes] — FR10's eight traversal
  /// modes plus FR29's authored-note `transit`.
  final String mode;

  /// One of `loop` | `out_and_back` | `point_to_point`.
  final String shape;
  final Coord? start;
  final Coord? end;

  /// FR8a / A9 — mandatory pass-through points, in order.
  final List<Coord> via;
  final TargetDistance? targetDistance;
  final List<Band> bands;
  final List<Violation> violations;

  /// FR36 / C15 / M2 — a segment-scoped override. Absent resolves to the trip default.
  final WeightProfile? weights;
  final LineString? geometry;
  final RouteMetrics? metrics;
  final Elevation? elevation;
  final List<Node> nodes;
  final List<Alternate> alternates;
  final List<Hazard> hazards;
  final List<Portage> portages;

  /// FR128 / A11 — the mode-legal but noteworthy edges this passage's solved
  /// geometry rolls over (dismount sections, gates, fords), as reported by the
  /// `/segments/generate` response.
  ///
  /// **Session-only, not persisted** — there is no `trip_payload.schema.json`
  /// home for it yet (`additionalProperties: false` on `$defs/segment`, and
  /// adding one is a schema version bump, ARCH D28), the same accepted
  /// limitation `trip_bbox_provider.dart` documents. It survives a re-solve
  /// (the fresh solve refills it) but not a trip save/reload, which drops it
  /// until the next solve — the same as `violations` before a solve. Empty for
  /// an Author-drawn leg or a leg solved before the engine surfaced them.
  final List<SurfacedConstraint> surfacedConstraints;
  final SolveProvenance? solve;

  /// FR38 / O6 — one of `exposition` | `rising` | `crux` | `climax` |
  /// `resolution`, or `null` for a segment that carries no arc beat of its own
  /// (the common case). Kept a raw string, like [Node.arcStage], rather than a
  /// typed enum: this is `trips.payload`'s loosely-typed layer, not `Role`'s.
  final String? arcStage;

  /// FR37 / E1 — rich notes/instructions attached to this passage itself,
  /// distinct from any role's own note (`Role.note`, `anchor.dart`).
  final String? note;

  /// FR37 / E1 — media attached to this passage.
  final List<MediaRef> media;

  factory Segment.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'segment');
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
      geometry: f.takeObject('geometry', LineString.fromJson),
      metrics: f.takeObject('metrics', RouteMetrics.fromJson),
      elevation: f.takeObject('elevation', Elevation.fromJson),
      nodes: f.takeList('nodes', Node.fromJson),
      alternates: f.takeList('alternates', Alternate.fromJson),
      hazards: f.takeList('hazards', Hazard.fromJson),
      portages: f.takeList('portages', Portage.fromJson),
      // `surfacedConstraints` is session-only (see its field doc) — never read
      // from or written to the persisted payload.
      solve: f.takeObject('solve', SolveProvenance.fromJson),
      arcStage: f.takeString('arc_stage'),
      note: f.takeString('note'),
      media: f.takeList('media', MediaRef.fromJson),
    );
    f.done();
    return s;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'id': id,
        'title': title,
        'mode': mode,
        'shape': shape,
        'start': start == null ? null : checkCoord(start!, 'segment.start'),
        'end': end == null ? null : checkCoord(end!, 'segment.end'),
        'via': via.isEmpty ? null : via.map((c) => checkCoord(c, 'segment.via')).toList(),
        'target_distance': targetDistance?.toJson(),
        'bands': bands.isEmpty ? null : bands.map((b) => b.toJson()).toList(),
        'violations': violations.isEmpty ? null : violations.map((v) => v.toJson()).toList(),
        'weights': weights?.toJson(),
        'geometry': geometry?.toJson(),
        'metrics': metrics?.toJson(),
        'elevation': elevation?.toJson(),
        'nodes': nodes.isEmpty ? null : nodes.map((n) => n.toJson()).toList(),
        'alternates': alternates.isEmpty ? null : alternates.map((a) => a.toJson()).toList(),
        'hazards': hazards.isEmpty ? null : hazards.map((h) => h.toJson()).toList(),
        'portages': portages.isEmpty ? null : portages.map((p) => p.toJson()).toList(),
        'solve': solve?.toJson(),
        'arc_stage': arcStage,
        'note': note,
        'media': media.isEmpty ? null : media.map((m) => m.toJson()).toList(),
      });

  Segment copyWith({
    String? title,
    String? mode,
    String? shape,
    Coord? start,
    Coord? end,
    List<Coord>? via,
    TargetDistance? targetDistance,
    List<Band>? bands,
    List<Violation>? violations,
    WeightProfile? weights,
    LineString? geometry,
    RouteMetrics? metrics,
    Elevation? elevation,
    List<Node>? nodes,
    List<Alternate>? alternates,
    List<Hazard>? hazards,
    List<Portage>? portages,
    List<SurfacedConstraint>? surfacedConstraints,
    SolveProvenance? solve,
    String? arcStage,
    bool clearArcStage = false,
    String? note,
    bool clearNote = false,
    List<MediaRef>? media,
  }) =>
      Segment(
        id: id,
        title: title ?? this.title,
        mode: mode ?? this.mode,
        shape: shape ?? this.shape,
        start: start ?? this.start,
        end: end ?? this.end,
        via: via ?? this.via,
        targetDistance: targetDistance ?? this.targetDistance,
        bands: bands ?? this.bands,
        violations: violations ?? this.violations,
        weights: weights ?? this.weights,
        geometry: geometry ?? this.geometry,
        metrics: metrics ?? this.metrics,
        elevation: elevation ?? this.elevation,
        nodes: nodes ?? this.nodes,
        alternates: alternates ?? this.alternates,
        hazards: hazards ?? this.hazards,
        portages: portages ?? this.portages,
        surfacedConstraints: surfacedConstraints ?? this.surfacedConstraints,
        solve: solve ?? this.solve,
        arcStage: clearArcStage ? null : (arcStage ?? this.arcStage),
        note: clearNote ? null : (note ?? this.note),
        media: media ?? this.media,
      );
}
