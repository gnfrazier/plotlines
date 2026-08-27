/// `$defs/day`.
library;

import 'hazard.dart';
import 'json_utils.dart';
import 'node.dart';
import 'route_metrics.dart';
import 'cue.dart';
import 'segment.dart';
import 'transition.dart';
import 'weight_profile.dart';

/// FR18 / C2. A rest day is a day with no segments — not a different type —
/// so every list, roll-up and itinerary iterates one collection. `kind` is
/// `route` | `rest`.
class Day {
  Day({
    required this.id,
    required this.index,
    this.kind = 'route',
    this.roles = const {},
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

  /// 1-based position in the trip. Distinct from [date], which may be absent
  /// (FR17 allows a day count with no dates).
  final int index;
  final String kind;

  /// Start and End are marks on a day, not day kinds — a start day is
  /// usually also a route day. Values are `start` | `end`.
  final Set<String> roles;
  final String? date;
  final String? title;
  final String? note;

  /// A rest day holds a location without an active route.
  final Coord? location;
  final List<Segment> segments;
  final List<Transition> transitions;

  /// Day-scoped nodes — a rest day's POIs and scheduled events, which
  /// belong to no segment.
  final List<Node> nodes;
  final List<Hazard> hazards;

  /// C3 — overrides the trip default for this day.
  final Map<String, DayLimit> limits;

  /// FR36 / C15 — day-scoped weight override.
  final WeightProfile? weights;
  final RollUp? metrics;
  final CueSheet? cueSheet;

  bool get isRest => kind == 'rest';

  factory Day.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'day');
    final rawLimits = f.take('limits');
    final d = Day(
      id: f.takeString('id')!,
      index: f.takeInt('index')!,
      kind: f.takeString('kind') ?? 'route',
      roles: f.takeStrings('roles').toSet(),
      date: f.takeString('date'),
      title: f.takeString('title'),
      note: f.takeString('note'),
      location: f.takeCoord('location'),
      segments: f.takeList('segments', Segment.fromJson),
      transitions: f.takeList('transitions', Transition.fromJson),
      nodes: f.takeList('nodes', Node.fromJson),
      hazards: f.takeList('hazards', Hazard.fromJson),
      limits: rawLimits == null ? const {} : dayLimitsFromJson(rawLimits),
      weights: f.takeObject('weights', WeightProfile.fromJson),
      metrics: f.takeObject('metrics', RollUp.fromJson),
      cueSheet: f.takeObject('cue_sheet', CueSheet.fromJson),
    );
    f.done();
    if (d.kind == 'rest' && d.segments.isNotEmpty) {
      throw FormatException('day ${d.id}: a rest day holds no active route (FR18/C2)');
    }
    return d;
  }

  Map<String, dynamic> toJson() => pruneJson({
        'id': id,
        'index': index,
        'kind': kind,
        'roles': roles.isEmpty ? null : roles.toList(),
        'date': date,
        'title': title,
        'note': note,
        'location': location == null ? null : checkCoord(location!, 'day.location'),
        'segments': segments.isEmpty ? null : segments.map((s) => s.toJson()).toList(),
        'transitions':
            transitions.isEmpty ? null : transitions.map((t) => t.toJson()).toList(),
        'nodes': nodes.isEmpty ? null : nodes.map((n) => n.toJson()).toList(),
        'hazards': hazards.isEmpty ? null : hazards.map((h) => h.toJson()).toList(),
        'limits': limits.isEmpty ? null : dayLimitsToJson(limits),
        'weights': weights?.toJson(),
        'metrics': metrics?.toJson(),
        'cue_sheet': cueSheet?.toJson(),
      });

  /// C2 — [clearTitle], [clearNote] and [clearLocation] are the only way to
  /// take those fields off a day: a bare `null` reads as "leave it as it
  /// was" like every other optional field here, mirroring
  /// `Transition.copyWith`'s `clearNode` (FR12/B3) — a caller clearing a
  /// rest day's location or itinerary note should have to say so.
  Day copyWith({
    int? index,
    String? kind,
    Set<String>? roles,
    String? date,
    String? title,
    bool clearTitle = false,
    String? note,
    bool clearNote = false,
    Coord? location,
    bool clearLocation = false,
    List<Segment>? segments,
    List<Transition>? transitions,
    List<Node>? nodes,
    List<Hazard>? hazards,
    Map<String, DayLimit>? limits,
    WeightProfile? weights,
    RollUp? metrics,
    CueSheet? cueSheet,
  }) =>
      Day(
        id: id,
        index: index ?? this.index,
        kind: kind ?? this.kind,
        roles: roles ?? this.roles,
        date: date ?? this.date,
        title: clearTitle ? null : (title ?? this.title),
        note: clearNote ? null : (note ?? this.note),
        location: clearLocation ? null : (location ?? this.location),
        segments: segments ?? this.segments,
        transitions: transitions ?? this.transitions,
        nodes: nodes ?? this.nodes,
        hazards: hazards ?? this.hazards,
        limits: limits ?? this.limits,
        weights: weights ?? this.weights,
        metrics: metrics ?? this.metrics,
        cueSheet: cueSheet ?? this.cueSheet,
      );
}

/// FR19 / C3 — per-mode min/max distance breaches for [day]. [Day.limits]'
/// keys are travel modes (the schema's own words: "Keys are travel modes;
/// key order is meaningless"), so a day mixing cycling and hiking can carry
/// one band per mode rather than one blended distance for the whole day.
///
/// Mirrors `plotlines_core.trips.compose._breaches`/`_ends_at_resolution`
/// exactly, including FR38/O6's exemption of a min breach when the day
/// closes at a resolution-stage anchor (a deliberate early ending, not a
/// shortfall) — over-length is never excused, only under. Pure and
/// synchronous: every input (segment metrics, day limits, node arc stages)
/// already sits on the payload, so this needs no solve to answer, and is
/// the one place both the day-timeline breach chip and the metrics
/// dashboard compute it, so they can never disagree.
List<LimitBreach> computeDayLimitBreaches(Day day) {
  if (day.limits.isEmpty) return const [];
  final realisedByMode = <String, double>{};
  for (final segment in day.segments) {
    final distance = segment.metrics?.distanceM;
    if (distance == null) continue;
    realisedByMode.update(segment.mode, (v) => v + distance, ifAbsent: () => distance);
  }
  final closesAtResolution = _dayEndsAtResolution(day);
  final breaches = <LimitBreach>[];
  for (final entry in day.limits.entries) {
    final realised = realisedByMode[entry.key];
    if (realised == null) continue; // no segment in this mode — nothing realized to breach.
    final limit = entry.value;
    if (limit.minM != null && realised < limit.minM! && !closesAtResolution) {
      breaches.add(LimitBreach(
        mode: entry.key, bound: 'min', limitM: limit.minM!, realisedM: realised, dayId: day.id,
      ));
    }
    if (limit.maxM != null && realised > limit.maxM!) {
      breaches.add(LimitBreach(
        mode: entry.key, bound: 'max', limitM: limit.maxM!, realisedM: realised, dayId: day.id,
      ));
    }
  }
  return breaches;
}

bool _dayEndsAtResolution(Day day) {
  if (day.segments.isEmpty) return false;
  final nodes = day.segments.last.nodes;
  if (nodes.isEmpty) return false;
  final ordered = [...nodes]..sort((a, b) {
      final aUnset = a.distanceAlongM == null;
      final bUnset = b.distanceAlongM == null;
      if (aUnset != bUnset) return aUnset ? -1 : 1;
      return (a.distanceAlongM ?? 0.0).compareTo(b.distanceAlongM ?? 0.0);
    });
  return ordered.last.arcStage == 'resolution';
}
