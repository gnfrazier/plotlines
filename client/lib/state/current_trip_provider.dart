import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../domain/domain.dart';
import 'providers.dart';
import 'trip_authoring_meta_provider.dart';
import 'trip_bbox_provider.dart';
import 'trip_library_provider.dart';

const _uuid = Uuid();

String _nowIso() => DateTime.now().toUtc().toIso8601String();

/// The trip currently open in the planner (ARCH §9.1's State layer over the
/// Domain `Trip`). One notifier per open trip; screens 00-04 all read/write
/// through this so there is exactly one place that mutates the payload.
class CurrentTripNotifier extends StateNotifier<Trip> {
  CurrentTripNotifier(this._ref) : super(_blank());

  final Ref _ref;

  static Trip _blank() {
    final now = _nowIso();
    return Trip(id: _uuid.v4(), title: 'Untitled plotline', createdAt: now, updatedAt: now);
  }

  /// K8 — one action, no per-control interaction, reverts everything and
  /// clears any generated route.
  void reset() => state = _blank();

  void open(Trip trip) => state = trip;

  void renameTrip(String title) =>
      state = state.copyWith(title: title, updatedAt: _nowIso());

  void setDefaultWeights(WeightProfile weights) =>
      state = state.copyWith(defaultWeights: weights, updatedAt: _nowIso());

  void setDuration(TripDuration duration) =>
      state = state.copyWith(duration: duration, updatedAt: _nowIso());

  /// New Route's "Blank canvas" start method (wireframe screen 00) — an
  /// empty day the Author builds manually via Logistics/Route/Content
  /// rather than a sidecar-generated segment. Also Logistics's "Add rest
  /// day" (`kind: 'rest'`): that used to call [setDayKind] with a
  /// just-generated id, which only ever looks up *existing* days
  /// (`_dayOrNew` below throws via `firstWhere` when nothing matches) —
  /// this is the one place that actually creates a day. Returns the new
  /// day's id so the caller can select it.
  String addBlankDay({String kind = 'route'}) {
    final day = Day(id: _uuid.v4(), index: state.days.length + 1, kind: kind);
    _replaceDay(day);
    return day.id;
  }

  Day _dayOrNew(String? dayId) {
    if (dayId != null) {
      return state.days.firstWhere((d) => d.id == dayId);
    }
    return Day(id: _uuid.v4(), index: state.days.length + 1);
  }

  void _replaceDay(Day day) {
    final exists = state.days.any((d) => d.id == day.id);
    final days = exists
        ? [for (final d in state.days) if (d.id == day.id) day else d]
        : [...state.days, day];
    state = state.copyWith(days: days, updatedAt: _nowIso());
  }

  void removeDay(String dayId) => state = state.copyWith(
        days: state.days.where((d) => d.id != dayId).toList(),
        updatedAt: _nowIso(),
      );

  /// C2 — mark a day Start / End / Rest. A rest day carries no segments.
  void setDayKind(String dayId, String kind) {
    final day = _dayOrNew(dayId);
    _replaceDay(day.copyWith(kind: kind, segments: kind == 'rest' ? [] : null));
  }

  void toggleDayRole(String dayId, String role) {
    final day = _dayOrNew(dayId);
    final roles = {...day.roles};
    roles.contains(role) ? roles.remove(role) : roles.add(role);
    _replaceDay(day.copyWith(roles: roles));
  }

  /// A1-A9 / B1 — solve a new segment via the sidecar and append it to a day
  /// (a new day if [dayId] is omitted).
  Future<void> generateSegment({
    String? dayId,
    required Coord start,
    Coord? end,
    List<Coord> via = const [],
    String mode = 'cycling',
    String shape = 'point_to_point',
    String theme = 'balanced',
    Map<String, double>? weights,
    double? targetM,
  }) async {
    final client = _ref.read(routingClientProvider);
    final segment = await client.generateSegment(
      start: start,
      end: end,
      via: via,
      mode: mode,
      shape: shape,
      theme: theme,
      weights: weights,
      targetM: targetM,
    );
    final day = _dayOrNew(dayId);
    _replaceDay(day.copyWith(segments: [...day.segments, segment]));
  }

  void removeSegment(String dayId, String segmentId) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    _replaceDay(day.copyWith(
      segments: day.segments.where((s) => s.id != segmentId).toList(),
    ));
  }

  void reorderSegments(String dayId, int oldIndex, int newIndex) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final segments = [...day.segments];
    final moved = segments.removeAt(oldIndex);
    segments.insert(newIndex > oldIndex ? newIndex - 1 : newIndex, moved);
    _replaceDay(day.copyWith(segments: segments));
  }

  /// SPIKE-20 (ARCH D30): an authored-input edit invalidates the derived
  /// geometry/metrics/elevation instantly. Every screen showing a solved
  /// number must check `segment.solve?.stale` and this is the one place that
  /// sets it, so no edit path can forget.
  void markSegmentStale(String dayId, String segmentId) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final segments = [
      for (final s in day.segments)
        if (s.id == segmentId && s.solve != null)
          s.copyWith(solve: s.solve!.markStale())
        else
          s,
    ];
    _replaceDay(day.copyWith(segments: segments));
  }

  void addHazardToSegment(String dayId, String segmentId, Hazard hazard) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final segments = [
      for (final s in day.segments)
        if (s.id == segmentId) s.copyWith(hazards: [...s.hazards, hazard]) else s,
    ];
    _replaceDay(day.copyWith(segments: segments));
  }

  void addNodeToSegment(String dayId, String segmentId, Node node) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final segments = [
      for (final s in day.segments)
        if (s.id == segmentId) s.copyWith(nodes: [...s.nodes, node]) else s,
    ];
    _replaceDay(day.copyWith(segments: segments));
  }

  /// FR99 — an Author promoting a candidate directly off the curation map.
  /// Deliberately a day-scoped node (`Day.nodes`, the same field a rest
  /// day's POIs use) rather than a new anchor type: the trip payload has no
  /// Anchor/role model yet (that migration is ARCH B3, tracked separately),
  /// and `Node.poiType` already exists to carry "the Author-set type this
  /// node counts as" for exactly this case. Promotion is the only write
  /// path from a candidate into the trip — nothing else in curation ever
  /// touches `state` (ARCH P10).
  void promoteCandidate(String dayId, Node node) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    _replaceDay(day.copyWith(nodes: [...day.nodes, node]));
  }

  /// N1's bbox shrink prompt (`trip_bbox_shrink_prompt.dart`'s
  /// `onRemoveAnchors`) — an Author explicitly choosing to drop the anchors
  /// a shrink would leave outside the trip's extent. An authored, visible
  /// act, never a side effect of resizing (that file's own doc comment);
  /// this is what actually carries it out, across every day's and
  /// segment's nodes.
  void removeNodesById(Set<String> ids) {
    if (ids.isEmpty) return;
    state = state.copyWith(
      updatedAt: _nowIso(),
      days: [
        for (final day in state.days)
          day.copyWith(
            nodes: [for (final n in day.nodes) if (!ids.contains(n.id)) n],
            segments: [
              for (final s in day.segments)
                s.copyWith(nodes: [for (final n in s.nodes) if (!ids.contains(n.id)) n]),
            ],
          ),
      ],
    );
  }

  void replaceNodeInSegment(String dayId, String segmentId, Node node) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final segments = [
      for (final s in day.segments)
        if (s.id == segmentId)
          s.copyWith(nodes: [
            for (final n in s.nodes) if (n.id == node.id) node else n,
          ])
        else
          s,
    ];
    _replaceDay(day.copyWith(segments: segments));
  }

  /// A1-A5 — Author edits a segment's weight profile or bands. Marks the
  /// segment stale (ARCH D30): the geometry on screen no longer matches
  /// what was asked for until [regenerateSegment] re-solves it.
  void updateSegmentWeights(String dayId, String segmentId, WeightProfile weights) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final segments = [
      for (final s in day.segments)
        if (s.id == segmentId) s.copyWith(weights: weights) else s,
    ];
    _replaceDay(day.copyWith(segments: segments));
    markSegmentStale(dayId, segmentId);
  }

  void updateSegmentBands(String dayId, String segmentId, List<Band> bands) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final segments = [
      for (final s in day.segments)
        if (s.id == segmentId) s.copyWith(bands: bands) else s,
    ];
    _replaceDay(day.copyWith(segments: segments));
    markSegmentStale(dayId, segmentId);
  }

  /// Route tab's shape/target-distance rail (wireframe screen 01) — edits
  /// the authored inputs a re-solve should honor. Marks stale like weights
  /// and bands (ARCH D30): the geometry on screen no longer matches what's
  /// asked for until [regenerateSegment] re-solves it.
  void updateSegmentShape(String dayId, String segmentId, String shape) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final segments = [
      for (final s in day.segments)
        if (s.id == segmentId) s.copyWith(shape: shape) else s,
    ];
    _replaceDay(day.copyWith(segments: segments));
    markSegmentStale(dayId, segmentId);
  }

  void updateSegmentTargetDistance(String dayId, String segmentId, double? valueM) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final segments = [
      for (final s in day.segments)
        if (s.id == segmentId)
          s.copyWith(targetDistance: valueM == null ? null : TargetDistance(valueM: valueM))
        else
          s,
    ];
    _replaceDay(day.copyWith(segments: segments));
    markSegmentStale(dayId, segmentId);
  }

  /// C3 — Logistics tab's per-day distance limits, overriding the trip
  /// default (`Trip.dayLimits`). Feeds `/days/compose`'s existing breach
  /// detection; doesn't itself re-solve anything.
  void updateDayLimits(String dayId, Map<String, DayLimit> limits) {
    final day = _dayOrNew(dayId);
    _replaceDay(day.copyWith(limits: limits));
  }

  /// Re-solves a segment against its current start/end/via/mode/weights and
  /// replaces it in place — same id, same curated content (nodes, hazards),
  /// new geometry/metrics. `generateSegment`'s sidecar call always returns a
  /// fresh id (it has no notion of "this is an edit"), so this is the one
  /// place that reconciles the two: everything an Author curated on the old
  /// segment survives the re-solve.
  Future<void> regenerateSegment(String dayId, String segmentId) async {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final old = day.segments.firstWhere((s) => s.id == segmentId);
    final needsEnd = old.shape != 'loop';
    if (old.start == null || (needsEnd && old.end == null)) {
      throw StateError('segment $segmentId has no start/end to re-solve from');
    }
    final client = _ref.read(routingClientProvider);
    final weights = old.weights;
    // Author-facing 0.0-5.0 -> solver-internal 0.0-1.0 (bipolar -1..1 for
    // peaks), per scoring/profile.py's documented conversion (risk A18,
    // MVP doc §1.4.5 — "it lands with the first weight slider": this is
    // that slider).
    //
    // `surface` is a real, lossy reduction, not a units conversion: the
    // Author sets three independent 0-5 dials (paved/gravel/singletrack,
    // each avoid<->seek), but the solver has one scalar `surface` dial that
    // can only ever *penalise* low-quality surface (edge_cost's
    // `profile.surface * (1.0 - quality)` term is never negative) — it has
    // no way to actively seek gravel, only to stop avoiding it. Given that
    // ceiling, the honest mapping is the Author's net preference for
    // pavement over rough surface, clamped to what the solver can act on:
    // 0 when indifferent or unpaved-seeking (correctly relaxes the
    // aversion to zero, the best available response), scaling toward 1 as
    // paved preference exceeds gravel/singletrack. Absent classes read as
    // indifferent (2.5), matching the schema's own rule for `surface`.
    double? surfaceDial;
    final surface = weights?.surface;
    if (surface != null && surface.isNotEmpty) {
      final paved = surface['paved'] ?? 2.5;
      final gravel = surface['gravel'] ?? 2.5;
      final singletrack = surface['singletrack'] ?? 2.5;
      final unpaved = (gravel + singletrack) / 2.0;
      surfaceDial = ((paved - unpaved) / 5.0).clamp(0.0, 1.0);
    }
    final weightsPayload = weights == null
        ? null
        : {
            if (weights.climbing != null) 'peaks': (weights.climbing! - 2.5) / 2.5,
            if (weights.traffic != null) 'quiet': weights.traffic! / 5.0,
            if (surfaceDial != null) 'surface': surfaceDial,
          };
    final resolved = await client.generateSegment(
      start: old.start!,
      end: old.shape == 'loop' ? null : old.end!,
      via: old.via,
      mode: old.mode,
      shape: old.shape,
      // `theme` only matters to the server when `weights` is empty —
      // service/app.py's `_resolve_profile` falls back to `THEMES[theme]`
      // in exactly that case, and `WeightsRail`'s default profile name
      // ('custom') isn't a registered theme, so sending it there 422s.
      // When `weightsPayload` is non-empty the server just stores `theme`
      // as the resolved profile's label, so any name is safe.
      theme: (weightsPayload != null && weightsPayload.isNotEmpty)
          ? (weights?.name ?? 'balanced')
          : 'balanced',
      targetM: old.targetDistance?.valueM,
      weights: weightsPayload,
    );
    final merged = resolved.copyWith(
      nodes: old.nodes,
      hazards: old.hazards,
      alternates: old.alternates,
      portages: old.portages,
      weights: old.weights,
      bands: old.bands,
      title: old.title,
    );
    // `Segment.copyWith` never overrides `id` (see segment.dart) — rebuild
    // with the old id directly so every reference to this segment
    // (transitions, node ownership by dayId/segmentId pairs) still resolves.
    final replaced = Segment(
      id: old.id,
      mode: merged.mode,
      shape: merged.shape,
      title: merged.title,
      start: merged.start,
      end: merged.end,
      via: merged.via,
      targetDistance: merged.targetDistance,
      bands: merged.bands,
      violations: merged.violations,
      weights: merged.weights,
      geometry: merged.geometry,
      metrics: merged.metrics,
      elevation: merged.elevation,
      nodes: merged.nodes,
      alternates: merged.alternates,
      hazards: merged.hazards,
      portages: merged.portages,
      solve: merged.solve,
    );
    final segments = [for (final s in day.segments) if (s.id == segmentId) replaced else s];
    _replaceDay(day.copyWith(segments: segments));
  }

  /// D1 — best-effort local roll-up for immediate dashboard feedback.
  /// Authoritative composition is `plotlines_core.trips.compose.compose_day`
  /// (ARCH §6.1); that endpoint is not exposed by the sidecar yet (open
  /// question), so this recomputes the same sums client-side rather than
  /// leaving the dashboard blank. It does not replicate compose_day's
  /// transition-gap warnings or C3 limit-breach detection.
  RouteMetrics rollUpTrip() {
    double distance = 0, climb = 0, descent = 0;
    for (final day in state.days) {
      for (final s in day.segments) {
        distance += s.metrics?.distanceM ?? 0;
        climb += s.metrics?.climbM ?? s.elevation?.ascentM ?? 0;
        descent += s.metrics?.descentM ?? s.elevation?.descentM ?? 0;
      }
    }
    return RouteMetrics(distanceM: distance, climbM: climb, descentM: descent);
  }
}

final currentTripProvider =
    StateNotifierProvider<CurrentTripNotifier, Trip>((ref) => CurrentTripNotifier(ref));

/// G2a save/reopen, against [currentTripProvider].
class TripPersistence {
  TripPersistence(this._ref);
  final Ref _ref;

  Future<void> save() async {
    final trip = _ref.read(currentTripProvider);
    final db = _ref.read(appDatabaseProvider);
    await db.saveTrip(
      id: trip.id,
      title: trip.title,
      modes: trip.modes.toList(),
      payloadJson: _encode(trip),
      updatedAt: DateTime.now(),
    );
    _ref.invalidate(tripLibraryProvider);
  }

  Future<void> open(String id) async {
    final db = _ref.read(appDatabaseProvider);
    final row = await db.loadTrip(id);
    if (row == null) return;
    final trip = Trip.fromJson(_decode(row.payload));
    _ref.read(currentTripProvider.notifier).open(trip);
    // Party size / primary modes are session-only (trip_authoring_meta_provider.dart's
    // doc comment) — a reopened trip starts without whatever was set for the
    // trip open before it, rather than inheriting a stale value. The trip
    // bbox is the same accepted limitation (trip_bbox_provider.dart) — a
    // reopened trip needs the "Trip area" action (trip_shell_screen.dart) to
    // redraw it before anything bbox-scoped can run again.
    _ref.read(tripAuthoringMetaProvider.notifier).reset();
    _ref.read(tripBboxProvider.notifier).reset();
  }

  Future<void> delete(String id) async {
    await _ref.read(appDatabaseProvider).deleteTrip(id);
    _ref.invalidate(tripLibraryProvider);
  }
}

final tripPersistenceProvider = Provider((ref) => TripPersistence(ref));

Map<String, dynamic> _decode(String json) =>
    Map<String, dynamic>.from(jsonDecode(json) as Map);
String _encode(Trip trip) => jsonEncode(trip.toJson());
