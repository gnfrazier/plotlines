/// Compose mode's places-first views — the client half of Story E3 (FR39,
/// FR117, FR118), issue #214.
///
/// `plotlines_core.trips.spine` is the authority: `compose_itinerary` (an
/// ordered list of [ComposeStop]s — the promoted anchors — with the
/// [ComposeLeg]s between them, plus A0a's [ComposeDistanceOutcome]),
/// `recap_spine` ([SpineRecapEntry]), and `spine_cues` (reuses [Cue]).
/// `/days/compose` now returns all three alongside the `Day`
/// ([ComposeItinerary.fromResponse]) so a sidecar and a future hosted
/// assembly hand the client identical structure — nothing here recomputes
/// them.
///
/// Distinct from `itinerary.dart`, which is F2's Character-facing *export*
/// itinerary. This one is the Author's compose-mode planning readout: the
/// ordered places, the reported (never targeted, FR118) distance, and the
/// A0a dispositions when the length missed what the Author had in mind.
///
/// Parsed with plain `json['key']` access rather than `JsonFields` (same as
/// `trip_dashboard.dart`): these are derived server output, not a slice of
/// the trip payload the domain layer round-trips, and several fields are
/// emitted as an explicit `null` the strict reader would reject.
library;

import 'cue.dart';
import 'json_utils.dart' show Coord;

double? _num(Object? v) => v == null ? null : (v as num).toDouble();

List<String> _strings(Object? v) =>
    v == null ? const [] : [for (final s in v as List) s as String];

/// A0a / FR118 — the compose-mode distance conversation, as data. Mirrors
/// `spine.DistanceOutcome.to_dict()`. [isConflict] / [isError] are `false`
/// by construction: a compose deviation never routes through the error
/// surface (ARCH §7.7), whatever [deviationM] is.
class ComposeDistanceOutcome {
  ComposeDistanceOutcome({
    required this.realisedM,
    this.targetM,
    this.deviationM,
    this.deviationFrac,
    this.dispositions = const [],
    this.isConflict = false,
    this.isError = false,
  });

  final double realisedM;

  /// What the Author had in mind, if anything. Null in pure compose — the
  /// length is simply reported.
  final double? targetM;

  /// Realised minus target; positive means the places made a longer day
  /// than intended. Null when there is no target to miss.
  final double? deviationM;
  final double? deviationFrac;

  /// The Author's moves, in Flow 4 order: `drop` / `defer` / `split` /
  /// `accept` when a target is present, just `accept` when it is not. None
  /// of them is an error handler — they are ordinary editing.
  final List<String> dispositions;
  final bool isConflict;
  final bool isError;

  bool get hasTarget => targetM != null;

  factory ComposeDistanceOutcome.fromJson(Map<String, dynamic> json) =>
      ComposeDistanceOutcome(
        realisedM: _num(json['realised_m'])!,
        targetM: _num(json['target_m']),
        deviationM: _num(json['deviation_m']),
        deviationFrac: _num(json['deviation_frac']),
        dispositions: _strings(json['dispositions']),
        isConflict: json['is_conflict'] as bool? ?? false,
        isError: json['is_error'] as bool? ?? false,
      );
}

/// One place on the spine — an anchor rendered as an itinerary entry.
/// Mirrors `spine.ItineraryStop.to_dict()`.
class ComposeStop {
  ComposeStop({
    required this.anchorId,
    required this.order,
    this.title,
    required this.coord,
    this.roles = const [],
    this.arcStages = const [],
    this.hazard = false,
    this.distanceAlongM,
    this.hasUnrevealedNarrative = false,
  });

  final String anchorId;
  final int order;
  final String? title;
  final Coord coord;

  /// The anchor's role kinds, in canonical order (a set, not a type).
  final List<String> roles;

  /// The arc beats this stop's roles carry, in story order.
  final List<String> arcStages;
  final bool hazard;

  /// Cumulative distance along the spine to this stop. Null — never a
  /// guessed `0.0` — once an earlier passage has no solved metrics.
  final double? distanceAlongM;

  /// FR116 — a narrative role held until arrival. Print and web read this
  /// to render the stop's shape without spilling its content.
  final bool hasUnrevealedNarrative;

  factory ComposeStop.fromJson(Map<String, dynamic> json) => ComposeStop(
        anchorId: json['anchor_id'] as String,
        order: (json['order'] as num).toInt(),
        title: json['title'] as String?,
        coord: [for (final n in json['coord'] as List) (n as num).toDouble()],
        roles: _strings(json['roles']),
        arcStages: _strings(json['arc_stages']),
        hazard: json['hazard'] as bool? ?? false,
        distanceAlongM: _num(json['distance_along_m']),
        hasUnrevealedNarrative: json['has_unrevealed_narrative'] as bool? ?? false,
      );
}

/// The passage *between* two stops — subordinate to the places it joins.
/// Mirrors `spine.ItineraryLeg.to_dict()`.
class ComposeLeg {
  ComposeLeg({
    required this.order,
    required this.segmentId,
    required this.mode,
    this.distanceM,
    this.arcStage,
    required this.planningMode,
    this.hazards = const [],
  });

  /// Sits between stop [order] and stop `order + 1`.
  final int order;
  final String segmentId;
  final String mode;

  /// Null when the connecting passage has no solved metrics yet.
  final double? distanceM;
  final String? arcStage;

  /// `explore` or `compose` — a leg carries its own posture (a spine can
  /// mix them, FR119).
  final String planningMode;

  /// This passage's own hazard / technical-crux markers, never reveal-gated
  /// (FR115). Kept as raw maps — the itinerary readout only needs their
  /// presence and labels, not the full [Hazard] model.
  final List<Map<String, dynamic>> hazards;

  factory ComposeLeg.fromJson(Map<String, dynamic> json) => ComposeLeg(
        order: (json['order'] as num).toInt(),
        segmentId: json['segment_id'] as String,
        mode: json['mode'] as String,
        distanceM: _num(json['distance_m']),
        arcStage: json['arc_stage'] as String?,
        planningMode: json['planning_mode'] as String,
        hazards: json['hazards'] == null
            ? const []
            : [
                for (final h in json['hazards'] as List)
                  Map<String, dynamic>.from(h as Map),
              ],
      );
}

/// FR73 [AMENDED v2.0] narrative axis, planned half — which plot points the
/// spine reaches and in what order. Mirrors `spine.RecapEntry.to_dict()`.
/// A provision-only stop (water, toilets, a bail-out) is logistics, not
/// story, and does not appear here.
class SpineRecapEntry {
  SpineRecapEntry({
    required this.order,
    required this.anchorId,
    this.title,
    this.arcStages = const [],
    this.distanceAlongM,
  });

  final int order;
  final String anchorId;
  final String? title;
  final List<String> arcStages;
  final double? distanceAlongM;

  factory SpineRecapEntry.fromJson(Map<String, dynamic> json) => SpineRecapEntry(
        order: (json['order'] as num).toInt(),
        anchorId: json['anchor_id'] as String,
        title: json['title'] as String?,
        arcStages: _strings(json['arc_stages']),
        distanceAlongM: _num(json['distance_along_m']),
      );
}

/// A compose-mode day organised around its places (FR39). [stops] is the
/// spine; [legs] the connective tissue, one fewer than the stops. [recap]
/// and [cues] are the sibling views `/days/compose` returns in the same
/// response — bundled here so a caller holds one object.
class ComposeItinerary {
  ComposeItinerary({
    required this.planningMode,
    required this.spine,
    required this.stops,
    required this.legs,
    required this.distance,
    this.recap = const [],
    this.cues = const [],
  });

  final String planningMode;

  /// The anchor ids, in spine order — the day's organizing structure.
  final List<String> spine;
  final List<ComposeStop> stops;
  final List<ComposeLeg> legs;
  final ComposeDistanceOutcome distance;
  final List<SpineRecapEntry> recap;
  final List<Cue> cues;

  /// Reads the `itinerary` block of a `/days/compose` response, folding in
  /// the sibling `recap` / `cues` arrays from the same response body.
  /// Returns null when the response carries no `itinerary` (the day has
  /// fewer than two places in its spine).
  static ComposeItinerary? fromResponse(Map<String, dynamic> body) {
    final raw = body['itinerary'];
    if (raw == null) return null;
    final itin = Map<String, dynamic>.from(raw as Map);
    return ComposeItinerary(
      planningMode: itin['planning_mode'] as String,
      spine: _strings(itin['spine']),
      stops: [
        for (final s in itin['stops'] as List)
          ComposeStop.fromJson(Map<String, dynamic>.from(s as Map)),
      ],
      legs: [
        for (final l in itin['legs'] as List)
          ComposeLeg.fromJson(Map<String, dynamic>.from(l as Map)),
      ],
      distance: ComposeDistanceOutcome.fromJson(
          Map<String, dynamic>.from(itin['distance'] as Map)),
      recap: [
        for (final e in (body['recap'] as List? ?? const []))
          SpineRecapEntry.fromJson(Map<String, dynamic>.from(e as Map)),
      ],
      cues: [
        for (final c in (body['cues'] as List? ?? const []))
          Cue.fromJson(Map<String, dynamic>.from(c as Map)),
      ],
    );
  }
}
