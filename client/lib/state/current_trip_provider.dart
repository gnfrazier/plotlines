import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../domain/domain.dart';
import '../domain/promote.dart' as domain_promote show promoteAnchor;
import 'planner_ui_state.dart'
    show PlanningMode, bandViolations, bandedTargetDistance, composeAwareTargetM, hasTargetDistanceControl;
import 'providers.dart';
import 'trip_authoring_meta_provider.dart';
import 'trip_bbox_provider.dart';
import 'trip_library_provider.dart';

const _uuid = Uuid();

String _nowIso() => DateTime.now().toUtc().toIso8601String();

bool _sameCoord(Coord a, Coord b) => a[0] == b[0] && a[1] == b[1];

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

  /// FR144/N0 — the Author's stated set, from the mode-declaration prompt
  /// (trip creation) or a later edit (New Route's "PRIMARY MODES", the
  /// layer picker). "At least one is required" is enforced here too, not
  /// only at the picker UI: an empty set is never a legal declared state,
  /// so a call that would produce one is ignored rather than accepted.
  void setDeclaredModes(Set<String> modes) {
    if (modes.isEmpty) return;
    state = state.copyWith(declaredModes: modes, updatedAt: _nowIso());
  }

  void toggleDeclaredMode(String mode) {
    final modes = {...state.declaredModes};
    if (modes.contains(mode)) {
      if (modes.length == 1) return; // AC: at least one is always required.
      modes.remove(mode);
    } else {
      modes.add(mode);
    }
    state = state.copyWith(declaredModes: modes, updatedAt: _nowIso());
  }

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
    // FR144/N0 — "not a constraint": every day/segment mutation in this
    // notifier funnels through here, so this is the one place that needs to
    // catch a passage created in an undeclared mode and fold it in, silently
    // and unconditionally (no warning, no block, no confirmation). Declared
    // modes only ever grow this way — a mode already present, declared or
    // realized, changes nothing.
    final impliedModes = {for (final d in days) for (final s in d.segments) s.mode};
    final declaredModes = impliedModes.difference(state.declaredModes).isEmpty
        ? state.declaredModes
        : {...state.declaredModes, ...impliedModes};
    state = state.copyWith(days: days, declaredModes: declaredModes, updatedAt: _nowIso());
  }

  void removeDay(String dayId) => state = state.copyWith(
        days: state.days.where((d) => d.id != dayId).toList(),
        updatedAt: _nowIso(),
      );

  /// FR139/Q1 — "days may be inserted mid-trip, not only appended, with
  /// subsequent days renumbering and their content moving with them."
  /// [position] is the 1-based index the new day should land at; every
  /// existing day at or after it shifts up by one. Content "moves with"
  /// its day automatically here — it lives embedded on the `Day` object
  /// itself, so renumbering never has to touch it. Returns the new day's
  /// id so the caller can select it.
  String insertDayAt(int position, {String kind = 'route'}) {
    final sorted = [...state.days]..sort((a, b) => a.index.compareTo(b.index));
    final clamped = position.clamp(1, sorted.length + 1);
    final newDay = Day(id: _uuid.v4(), index: clamped, kind: kind);
    final days = <Day>[];
    var inserted = false;
    for (final d in sorted) {
      if (!inserted && d.index >= clamped) {
        days.add(newDay);
        inserted = true;
      }
      days.add(d.index >= clamped ? d.copyWith(index: d.index + 1) : d);
    }
    if (!inserted) days.add(newDay);
    state = state.copyWith(days: days, updatedAt: _nowIso());
    return newDay.id;
  }

  /// Removes [dayIds] outright — including their authored content — and
  /// renumbers what remains so `Day.index` stays a contiguous 1-based
  /// sequence. The one place both [removeDaysExplicitly] and
  /// [mergeDaysIntoAdjacent] land on, and what [reduceDayCount] uses for its
  /// no-prompt empty-day carve-out.
  void _removeDaysAndRenumber(Set<String> dayIds) {
    if (dayIds.isEmpty) return;
    final remaining = state.days.where((d) => !dayIds.contains(d.id)).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final renumbered = [
      for (var i = 0; i < remaining.length; i++) remaining[i].copyWith(index: i + 1),
    ];
    state = state.copyWith(days: renumbered, updatedAt: _nowIso());
  }

  /// FR139/Q1 — drops every trailing day beyond [targetCount] that holds no
  /// authored content, with no prompt (the AC's carve-out: "empty days are
  /// removed without a prompt"). Returns whichever of those days still hold
  /// content, for the caller to show FR139's scope prompt for and resolve
  /// via [mergeDaysIntoAdjacent] or [removeDaysExplicitly] — this call never
  /// removes those on its own.
  List<Day> reduceDayCount(int targetCount) {
    final beyond = daysBeyondCount(state.days, targetCount);
    final empty = {
      for (final d in beyond)
        if (summarizeDayContent(d).isEmpty) d.id,
    };
    if (empty.isNotEmpty) _removeDaysAndRenumber(empty);
    return [
      for (final d in beyond)
        if (!empty.contains(d.id)) d,
    ];
  }

  /// FR139/Q1's "remove explicitly" choice for a day-count reduction (or any
  /// direct multi-day removal): deletes [dayIds] and their authored content,
  /// then renumbers what remains.
  void removeDaysExplicitly(Set<String> dayIds) => _removeDaysAndRenumber(dayIds);

  /// FR139/Q1's "merge into adjacent day" choice: each of [dayIds]'s
  /// segments, nodes, hazards and transitions move onto the previous day in
  /// trip order (the next day, for day 1), then the now-empty day is
  /// dropped and the trip renumbered. Processes the trip's tail backward so
  /// merging day N into day N-1 is resolved before an earlier merge could
  /// shift day N-1's own position.
  void mergeDaysIntoAdjacent(Set<String> dayIds) {
    if (dayIds.isEmpty) return;
    final days = [...state.days]..sort((a, b) => a.index.compareTo(b.index));
    final orderedIds = [
      for (final d in days.reversed)
        if (dayIds.contains(d.id)) d.id,
    ];
    for (final id in orderedIds) {
      final pos = days.indexWhere((d) => d.id == id);
      if (pos == -1) continue;
      final day = days[pos];
      final targetPos = pos > 0 ? pos - 1 : (days.length > 1 ? 1 : -1);
      if (targetPos == -1) {
        days.removeAt(pos);
        continue;
      }
      final target = days[targetPos];
      days[targetPos] = target.copyWith(
        segments: [...target.segments, ...day.segments],
        nodes: [...target.nodes, ...day.nodes],
        hazards: [...target.hazards, ...day.hazards],
        transitions: [...target.transitions, ...day.transitions],
      );
      days.removeAt(pos);
    }
    final renumbered = [for (var i = 0; i < days.length; i++) days[i].copyWith(index: i + 1)];
    state = state.copyWith(days: renumbered, updatedAt: _nowIso());
  }

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
    String shape = 'loop',
    String theme = 'balanced',
    Map<String, double>? weights,
    double? targetM,
  }) async {
    final client = _ref.read(routingClientProvider);
    // FR120/D41, issue #154 — routing always runs against the Author's own
    // trip bbox, never a process-wide default. `New Route`'s Generate
    // control is disabled until a bbox exists (see `new_route_screen.dart`),
    // so reaching here with none is a real precondition failure, not a race
    // to paper over.
    final bbox = _ref.read(tripBboxProvider);
    if (bbox == null) {
      throw StateError(
          'no trip bbox — draw the trip area (FR120) before generating a route');
    }
    final region = await client.ensureRegion(bbox.bboxWsen);
    final resolved = await client.generateSegment(
      region: region,
      start: start,
      end: end,
      via: via,
      mode: mode,
      shape: shape,
      theme: theme,
      weights: weights,
      targetM: targetM,
    );
    // FR8/A8's AC: "banded by default in explore mode" — this is the New
    // Route flow's own first solve, before the Author has ever touched
    // `WeightsRail`'s target-distance field, so the same default banding
    // has to apply here too, not only on later edits
    // (`updateSegmentTargetDistance`). The server's response only ever
    // carries a bare `target_m` (`_segmentFromSolveResponse`), never a band.
    final targetDistance = resolved.targetDistance;
    final segment = (targetDistance != null && hasTargetDistanceControl(resolved.shape))
        ? resolved.copyWith(targetDistance: bandedTargetDistance(targetDistance.valueM))
        : resolved;
    final day = _dayOrNew(dayId);
    _replaceDay(day.copyWith(segments: [...day.segments, segment]));
  }

  /// FR139/Q2 — removes a passage from a day. Its nodes are never deleted
  /// with it: FR139's "anchors survive unattached" — an anchor is a place,
  /// not a property of a route — so they move onto the day's own
  /// day-scoped node list (`Day.nodes`, the same list a rest day's POIs
  /// already live on), findable and re-attachable through the curation
  /// workspace's anchors view (N4a) rather than disappearing. Callers
  /// should check `summarizeSegmentContent(segment).hasAuthoredContent`
  /// (`domain/edit_scope.dart`) and confirm with the Author first when it's
  /// true — this call itself always carries the removal out once asked, the
  /// same division `reviseTripBbox` draws between deciding and doing.
  void removeSegment(String dayId, String segmentId) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final removed = day.segments.firstWhere((s) => s.id == segmentId);
    _replaceDay(day.copyWith(
      segments: day.segments.where((s) => s.id != segmentId).toList(),
      nodes: [...day.nodes, ...removed.nodes],
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

  /// FR99 — an Author promoting a candidate directly off the curation map's
  /// `layers_tab.dart`. Deliberately still a day-scoped node (`Day.nodes`,
  /// the same field a rest day's POIs use), not [promoteAnchor]: the
  /// Anchor/role model now exists (FR106/FR110, Story O1), but wiring
  /// `layers_tab.dart`'s candidate map onto it is that story's UI half and
  /// out of this call site's scope (ARCH B3's node→anchor migration is
  /// tracked separately from O1's new-model addition). `Node.poiType`
  /// carries "the Author-set type this node counts as" for exactly this
  /// case in the meantime.
  void promoteCandidate(String dayId, Node node) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    _replaceDay(day.copyWith(nodes: [...day.nodes, node]));
  }

  /// FR106, FR110 / O1 — the promotion interaction: a candidate, a cluster
  /// proposal, or a hand-placed [coord] becomes one [Anchor] carrying
  /// [roles], trip-scoped (`Trip.anchors`) rather than day- or
  /// segment-scoped. Throws [DuplicatePromotionException] rather than
  /// creating a second anchor when [provenance] names a source already
  /// promoted (FR106's "one anchor per place") — the caller should route the
  /// Author to editing that anchor instead of catching this.
  Anchor promoteAnchor({
    required Coord coord,
    required List<Role> roles,
    String? title,
    Area? area,
    AnchorProvenance? provenance,
  }) {
    final anchor = domain_promote.promoteAnchor(
      existingAnchors: state.anchors,
      id: _uuid.v4(),
      coord: coord,
      roles: roles,
      title: title,
      area: area,
      provenance: provenance,
    );
    state = state.copyWith(anchors: [...state.anchors, anchor], updatedAt: _nowIso());
    return anchor;
  }

  /// FR139's carve-out applies here without a prompt: an anchor that holds
  /// no authored content and is not yet attached to anything is ordinary
  /// working-state tidying, not the destructive case that rule guards.
  void removeAnchor(String anchorId) => state = state.copyWith(
        anchors: state.anchors.where((a) => a.id != anchorId).toList(),
        updatedAt: _nowIso(),
      );

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

  /// FR139/Q2 — a passage's mode is editable after routing like shape,
  /// weights and bands; this marks the segment stale (Q3/FR140) rather than
  /// re-solving, same as [updateSegmentShape]. Mode-legal routability
  /// (A11) is re-checked when [regenerateSegment] next solves it, not here.
  void updateSegmentMode(String dayId, String segmentId, String mode) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final segments = [
      for (final s in day.segments)
        if (s.id == segmentId) s.copyWith(mode: mode) else s,
    ];
    _replaceDay(day.copyWith(segments: segments));
    markSegmentStale(dayId, segmentId);
  }

  /// FR139/Q2 — a passage's endpoints are editable after routing too, same
  /// stale treatment as [updateSegmentShape]/[updateSegmentMode]. Omitting
  /// [end] leaves it as it was (a loop has none to begin with); there is no
  /// way to clear an endpoint back to unset here, matching every other
  /// caller of `Segment.copyWith`.
  void updateSegmentEndpoints(String dayId, String segmentId, {Coord? start, Coord? end}) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final segments = [
      for (final s in day.segments)
        if (s.id == segmentId) s.copyWith(start: start, end: end) else s,
    ];
    _replaceDay(day.copyWith(segments: segments));
    markSegmentStale(dayId, segmentId);
  }

  /// FR38 / O6 — a passage's own arc stage: the stretch of route between two
  /// anchors can itself be the rising action, not just the places at either
  /// end. Unlike [updateSegmentShape]/[updateSegmentWeights]/[updateSegmentBands],
  /// this never marks the segment stale — arc is narrative structure, not a
  /// solver input, and doesn't change what a re-solve would produce.
  void updateSegmentArcStage(String dayId, String segmentId, String? arcStage) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final segments = [
      for (final s in day.segments)
        if (s.id == segmentId)
          s.copyWith(arcStage: arcStage, clearArcStage: arcStage == null)
        else
          s,
    ];
    _replaceDay(day.copyWith(segments: segments));
  }

  /// FR117/A0 — compose mode's spine editor (`WeightsRail`'s `_SpineEditor`):
  /// replaces a segment's via-anchor order wholesale, since reordering the
  /// spine is exactly as common an edit as adding or removing a place from
  /// it. Explore's own via-node UI (`new_route_screen.dart`) can use this
  /// too; there is only ever one `via` field to edit (ARCH §7.7 — "not a
  /// second solver").
  void updateSegmentVia(String dayId, String segmentId, List<Coord> via) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final segments = [
      for (final s in day.segments)
        if (s.id == segmentId) s.copyWith(via: via) else s,
    ];
    _replaceDay(day.copyWith(segments: segments));
    markSegmentStale(dayId, segmentId);
  }

  /// FR118/A0a — "move one to another day," one of the deviation panel's
  /// affordances (`WeightsRail`'s `_ComposeDeviationPanel`): drops [coord]
  /// from this segment's spine and appends it to the first segment of
  /// [toDayId]'s day. The panel only offers days that already have a
  /// segment to receive it — an empty day has nowhere for the anchor to go,
  /// and creating one here would mean inventing a mode/shape/start with no
  /// Author input behind them.
  void moveViaToDay(String dayId, String segmentId, Coord coord, String toDayId) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final segment = day.segments.firstWhere((s) => s.id == segmentId);
    updateSegmentVia(
      dayId,
      segmentId,
      [for (final v in segment.via) if (!_sameCoord(v, coord)) v],
    );

    final toDay = state.days.firstWhere((d) => d.id == toDayId);
    final toSegment = toDay.segments.first;
    updateSegmentVia(toDayId, toSegment.id, [...toSegment.via, coord]);
  }

  /// FR118/A0a — "split the day," another deviation-panel affordance: moves
  /// the tail of this segment's spine — everything from [splitIndex] on —
  /// onto a new day of its own (`addBlankDay`, the same blank canvas New
  /// Route's hand-built path already produces). The new segment keeps the
  /// old one's mode and shape but starts fresh otherwise — compose builds
  /// a day out of the Author's own choices, not a solve, so there is no
  /// geometry or metrics to carry over until the Author re-solves it.
  /// Returns the new day's id so the caller can select it.
  ///
  /// [splitIndex] must fall strictly between 0 and `segment.via.length` —
  /// both a real head and a real tail — which the panel enforces by only
  /// offering the action when the spine has at least two places.
  String splitDayAt(String dayId, String segmentId, int splitIndex) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final segment = day.segments.firstWhere((s) => s.id == segmentId);
    if (splitIndex <= 0 || splitIndex >= segment.via.length) {
      throw ArgumentError.value(splitIndex, 'splitIndex', 'must leave both a head and a tail');
    }
    final tail = segment.via.sublist(splitIndex);
    updateSegmentVia(dayId, segmentId, segment.via.sublist(0, splitIndex));

    final newDayId = addBlankDay();
    final newSegment = Segment(
      id: _uuid.v4(),
      mode: segment.mode,
      shape: segment.shape,
      start: tail.first,
      end: segment.shape == 'point_to_point' ? segment.end : null,
      via: tail.sublist(1),
    );
    final newDay = state.days.firstWhere((d) => d.id == newDayId);
    _replaceDay(newDay.copyWith(segments: [newSegment]));
    return newDayId;
  }

  /// FR8/A8's AC: "banded by default in explore mode." Loop and out-and-back
  /// get a fresh default band (`bandedTargetDistance`) every time the Author
  /// sets a value; point-to-point (no target-distance control at all per the
  /// AC) is left unbanded defensively, in case anything ever reaches this
  /// with that shape. Clearing the target (`valueM: null`) goes through
  /// [_withTargetDistance] rather than `copyWith` — `copyWith`'s
  /// `targetDistance` parameter can't tell an explicit `null` from "leave it
  /// alone", so it would silently keep the old value instead of clearing it.
  void updateSegmentTargetDistance(String dayId, String segmentId, double? valueM) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final segments = [
      for (final s in day.segments)
        if (s.id == segmentId)
          _withTargetDistance(
            s,
            valueM == null
                ? null
                : (hasTargetDistanceControl(s.shape)
                    ? bandedTargetDistance(valueM)
                    : TargetDistance(valueM: valueM)),
          )
        else
          s,
    ];
    _replaceDay(day.copyWith(segments: segments));
    markSegmentStale(dayId, segmentId);
  }

  /// `Segment.copyWith(targetDistance: ...)` uses `targetDistance ??
  /// this.targetDistance` like every other nullable field there, so it
  /// cannot represent "set it to null" — only "leave it as it was" or "set
  /// it to some real value." [updateSegmentTargetDistance] needs the former
  /// when the Author clears the target entirely, so this constructs the
  /// replacement `Segment` directly instead.
  Segment _withTargetDistance(Segment s, TargetDistance? targetDistance) => Segment(
        id: s.id,
        title: s.title,
        mode: s.mode,
        shape: s.shape,
        start: s.start,
        end: s.end,
        via: s.via,
        targetDistance: targetDistance,
        bands: s.bands,
        violations: s.violations,
        weights: s.weights,
        geometry: s.geometry,
        metrics: s.metrics,
        elevation: s.elevation,
        nodes: s.nodes,
        alternates: s.alternates,
        hazards: s.hazards,
        portages: s.portages,
        solve: s.solve,
      );

  /// FR8/A8's AC: "the Author can widen the band" — edits the band a target
  /// distance is held to without touching the target itself. There is no
  /// counterpart that clears the band back to nothing short of clearing the
  /// target itself (`updateSegmentTargetDistance(..., null)`), which is the
  /// AC's "never dropped from the explore search's constraint set." A no-op
  /// when the segment has no target distance to band in the first place.
  void updateSegmentTargetDistanceBand(String dayId, String segmentId,
      {double? minM, double? maxM}) {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final segments = [
      for (final s in day.segments)
        if (s.id == segmentId && s.targetDistance != null)
          s.copyWith(targetDistance: TargetDistance(
                valueM: s.targetDistance!.valueM,
                minM: minM,
                maxM: maxM,
                advisory: s.targetDistance!.advisory,
              ))
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
  ///
  /// [mode] is FR117/A0's planning posture for the day this segment belongs
  /// to (`dayPlanningModeProvider`; explore by default so every existing
  /// caller keeps its prior behavior). ARCH §7.7: compose never sends
  /// `target_m` — the solve reaches every via-anchor and reports whatever
  /// length that produces — but the Author's own explore-mode target is
  /// never cleared by it, only left out of the request, so a day switching
  /// back to explore (FR119) still finds it there.
  Future<void> regenerateSegment(
    String dayId,
    String segmentId, {
    PlanningMode mode = PlanningMode.explore,
  }) async {
    final day = state.days.firstWhere((d) => d.id == dayId);
    final old = day.segments.firstWhere((s) => s.id == segmentId);
    final needsEnd = old.shape != 'loop';
    if (old.start == null || (needsEnd && old.end == null)) {
      throw StateError('segment $segmentId has no start/end to re-solve from');
    }
    final client = _ref.read(routingClientProvider);
    final bbox = _ref.read(tripBboxProvider);
    if (bbox == null) {
      throw StateError(
          'no trip bbox — draw the trip area (FR120) before re-solving a route');
    }
    final region = await client.ensureRegion(bbox.bboxWsen);
    final weights = old.weights;
    // Author-facing 0.0-5.0 -> solver-internal 0.0-1.0 (bipolar -1..1 for
    // peaks and each surface_<class>), per scoring/profile.py's documented
    // conversion (risk A18, MVP doc §1.4.5 — "it lands with the first
    // weight slider": this is that slider).
    final peaks = weights == null ? null : peaksFromClimbing(weights.climbing);
    // FR3/A2: inverted, not scaled — see `quietFromTraffic`'s doc comment.
    final quiet = weights == null ? null : quietFromTraffic(weights.traffic);
    // FR4/A3: one bipolar dial per class — see `surfaceWeightsFromAuthor`'s doc
    // comment. Absent classes are simply absent from the spread, same
    // omit-rather-than-invent rule as `peaks`/`quiet` above.
    final surfaceWeights =
        weights == null ? const <String, double>{} : surfaceWeightsFromAuthor(weights.surface);
    // FR5/A4, ARCH §7.7: `interest` is explore-mode only — compose never sends
    // it, the same way it never sends `target_m` (the promoted anchors are
    // already the spine, so a salience bias has nothing left to decide).
    final interest = (weights == null || mode == PlanningMode.compose)
        ? null
        : interestFromAuthor(weights.interest);
    final weightsPayload = weights == null
        ? null
        : {
            if (peaks != null) 'peaks': peaks,
            if (quiet != null) 'quiet': quiet,
            ...surfaceWeights,
            if (interest != null) 'interest': interest,
          };
    final resolved = await client.generateSegment(
      region: region,
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
      targetM: composeAwareTargetM(mode, old.targetDistance),
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
      // `old.targetDistance` wins whenever the Author has one authored,
      // point_to_point included — that shape's target is advisory-only and
      // never echoed back in `resolved` (service/app.py never reads it for
      // point_to_point), so falling through to `resolved.targetDistance`
      // there would silently wipe it on every re-solve.
      targetDistance: old.targetDistance ?? resolved.targetDistance,
    );
    // FR9/A6 — the just-solved route's band violations, synchronous with
    // this solve (see `bandViolations`' doc comment). Explore mode only:
    // compose's own band goes through A0a's `_ComposeDeviationPanel`
    // instead, never this surface (ARCH D53). FR8/A8's distance band lives on
    // `targetDistance`, not `old.bands` (`statedDistanceBand`'s doc comment),
    // so it's folded in here as a plain `Band` for this one check — the only
    // place `bandViolations` needs to see it to flag a miss right after a
    // solve, same as any other band.
    final distanceBand = (old.targetDistance?.minM != null || old.targetDistance?.maxM != null)
        ? Band(attribute: 'distance_m', min: old.targetDistance!.minM, max: old.targetDistance!.maxM)
        : null;
    final violations = mode == PlanningMode.explore
        ? bandViolations(merged.metrics, [...old.bands, if (distanceBand != null) distanceBand])
        : const <Violation>[];
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
      violations: violations,
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

  /// FR140/Q3 — the stale list's "re-solve-all as one unconfirmed action":
  /// re-solves every currently-stale segment in the trip from its own
  /// current inputs (start/end/via/mode/weights), the same as calling
  /// [regenerateSegment] on each in turn, which clears each one's staleness
  /// as it completes. Destroys nothing — the AC's own reason this action
  /// never confirms — so a failure partway through simply leaves the
  /// remaining items stale for a retry rather than needing any rollback.
  Future<void> resolveAllStale({PlanningMode mode = PlanningMode.explore}) async {
    for (final item in tripStaleItems(state)) {
      await regenerateSegment(item.dayId, item.segmentId, mode: mode);
    }
  }

  /// FR140/Q3 — the stale list's "drop it instead of re-solving" resolution
  /// for one item, the one action on that list the AC says confirms (unlike
  /// re-solve-all); the caller is responsible for that confirmation.
  /// Dropping a stale passage is the same removal [removeSegment] already
  /// defines for Q2 — its anchors still survive unattached — not a new
  /// mechanism.
  void dropStaleSegment(String dayId, String segmentId) => removeSegment(dayId, segmentId);
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
      declaredModes: trip.declaredModes.toList(),
      payloadJson: _encode(trip),
      updatedAt: DateTime.now(),
    );
    _ref.invalidate(tripLibraryProvider);
  }

  Future<void> open(String id) async {
    final db = _ref.read(appDatabaseProvider);
    final row = await db.loadTrip(id);
    if (row == null) return;
    final trip = Trip.fromJson(_decode(row.payload)).copyWith(
      // FR144/N0 — `declaredModes` never rode in `payload` (`trip.dart`'s
      // doc comment); it comes back from its own column instead.
      declaredModes: row.declaredModes.isEmpty ? const {} : row.declaredModes.split(',').toSet(),
    );
    _ref.read(currentTripProvider.notifier).open(trip);
    // Party size is session-only (trip_authoring_meta_provider.dart's doc
    // comment) — a reopened trip starts without whatever was set for the
    // trip open before it, rather than inheriting a stale value. (Travel
    // modes used to be session-only too; FR144/N0 promoted them to
    // `Trip.declaredModes` above, which *does* survive reopening.) The trip
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
