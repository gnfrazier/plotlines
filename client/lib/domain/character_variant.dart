/// H6 (FR6, FR20) — Character personalization as a **layer over canon**, not
/// an edit to it.
///
/// ARCH §7.8 / P8: "Character personalization ... [is a] layer rendered over
/// the canonical plotline — never [an] edit to it. Incorporating any of these
/// into the canon is an explicit Author action." A [CharacterVariant] is that
/// layer for one Character on one passage: which of the Author's *variable*
/// parameters the Character moved (within the Author's own min/max), and which
/// authored accommodation alternate (FR20) they took.
///
/// Nothing here is part of `trip_payload.schema.json` — a variant lives in a
/// Character-side provider (`state/character_variant_provider.dart`), the same
/// way [RevealState] does. Every function that "applies" a variant returns a
/// fresh derived value and leaves the input [Segment] untouched; that is the
/// AC's "never alters the Author's canonical route", enforced by having no
/// code path from here back into a `Segment`/`Trip` mutation.
///
/// Two kinds of variable parameter, both bounded by the Author:
///
///   * **FR6 bands.** Where the Author left a min/max band on a realised
///     attribute, the Character may pick a tighter target inside it. A band
///     the Author did not set is a *locked* parameter — shown with its
///     canonical realised value, not adjustable ([lockedParameters]).
///   * **FR20 accommodation alternates.** `bypass` (easier) and `extension`
///     (challenge) alternates the Author attached are an effort toggle; the
///     Character picks one or stays on the canonical line. Branch alternates
///     (narrative choices, FR125/P2) are a separate story and a separate
///     schema shape — not handled here.
library;

import 'band.dart';
import 'route_metrics.dart';
import 'segment.dart';

/// One realised attribute the Author left open for the Character to move
/// within — an FR6 band paired with the route's canonical realised value so a
/// Character surface can show "you're here, you may choose anywhere in this
/// range".
class AdjustableParameter {
  const AdjustableParameter({
    required this.attribute,
    required this.min,
    required this.max,
    required this.canonical,
  });

  final String attribute;

  /// The Author's band bounds. At least one is non-null (a [Band] with
  /// neither bound cannot exist); the open side means "no Character limit
  /// that direction beyond what the engine can produce".
  final double? min;
  final double? max;

  /// The canonical route's realised value for this attribute, or null when
  /// the route has not been solved yet — the starting point a Character
  /// adjusts away from.
  final double? canonical;

  /// Clamp [requested] into `[min, max]`. An open side does not clamp.
  double clamp(double requested) {
    var v = requested;
    if (min != null && v < min!) v = min!;
    if (max != null && v > max!) v = max!;
    return v;
  }

  /// Whether [value] falls inside the Author's band — the check
  /// [adjustParameter] enforces so a Character can never move a parameter
  /// outside the bounds the Author set.
  bool admits(double value) => (min == null || value >= min!) && (max == null || value <= max!);
}

/// A realised attribute the Author pinned (no band) — visible to the
/// Character with its canonical value, but not adjustable. The AC's "locked
/// ones visible but fixed".
class LockedParameter {
  const LockedParameter({required this.attribute, required this.value});

  final String attribute;
  final double value;
}

/// The Character's personal choices for one passage. Immutable; every change
/// goes through a `with*`/[adjust] call that returns a new instance, so a
/// provider holding one of these can diff old against new to know a re-solve
/// or a metrics refresh is due.
class CharacterVariant {
  const CharacterVariant({
    required this.segmentId,
    this.bandTargets = const {},
    this.chosenAlternateId,
  });

  final String segmentId;

  /// attribute -> the Character's chosen target inside the Author's band.
  /// Always already clamped (see [adjustParameter]).
  final Map<String, double> bandTargets;

  /// The id of the accommodation alternate the Character took, or null for
  /// the canonical line.
  final String? chosenAlternateId;

  bool get isEmpty => bandTargets.isEmpty && chosenAlternateId == null;

  /// True once the Character has narrowed a band — the realised metrics can
  /// only reflect that after a Character-scoped re-solve, so a surface shows
  /// "tap to update" rather than stale numbers. Choosing an alternate does
  /// not set this: an alternate carries its own precomputed metrics
  /// ([variantMetrics] swaps them in with no solve).
  bool get needsResolve => bandTargets.isNotEmpty;

  CharacterVariant copyWith({
    Map<String, double>? bandTargets,
    Object? chosenAlternateId = _unset,
  }) =>
      CharacterVariant(
        segmentId: segmentId,
        bandTargets: bandTargets ?? this.bandTargets,
        chosenAlternateId: identical(chosenAlternateId, _unset)
            ? this.chosenAlternateId
            : chosenAlternateId as String?,
      );
}

const Object _unset = Object();

/// The FR6 bands the Author left open for the Character on [segment], each
/// paired with the canonical realised value. Empty when the Author set no
/// bands — an explore passage with fixed weights and no bands offers the
/// Character nothing to move, which is a valid, common case.
List<AdjustableParameter> adjustableParameters(Segment segment) {
  final canonical = segment.metrics;
  return [
    for (final band in segment.bands)
      if (band.min != null || band.max != null)
        AdjustableParameter(
          attribute: band.attribute,
          min: band.min,
          max: band.max,
          canonical: _metricValue(canonical, band.attribute),
        ),
  ];
}

/// Every realised attribute the solved route reports that the Author did
/// *not* band — visible to the Character, fixed. Returns nothing before the
/// route is solved (no realised values to show).
List<LockedParameter> lockedParameters(Segment segment) {
  final metrics = segment.metrics;
  if (metrics == null) return const [];
  final banded = {for (final b in segment.bands) b.attribute};
  return [
    for (final attribute in attributeValues)
      if (!banded.contains(attribute))
        if (_metricValue(metrics, attribute) case final v?)
          LockedParameter(attribute: attribute, value: v),
  ];
}

/// Record the Character moving one parameter to [requested], clamped into the
/// Author's band. Throws [ArgumentError] if [attribute] is not one the Author
/// left adjustable — the AC's "locked ones ... fixed" made unbypassable
/// rather than merely not offered in the UI.
CharacterVariant adjustParameter(
  CharacterVariant variant,
  Segment segment,
  String attribute,
  double requested,
) {
  final param = adjustableParameters(segment).where((p) => p.attribute == attribute).firstOrNull;
  if (param == null) {
    throw ArgumentError.value(
      attribute,
      'attribute',
      'is locked on this passage — the Author set no band for it',
    );
  }
  return variant.copyWith(
    bandTargets: {...variant.bandTargets, attribute: param.clamp(requested)},
  );
}

/// Clear one Character adjustment, returning the parameter to the Author's
/// full band.
CharacterVariant clearAdjustment(CharacterVariant variant, String attribute) {
  if (!variant.bandTargets.containsKey(attribute)) return variant;
  return variant.copyWith(
    bandTargets: {
      for (final e in variant.bandTargets.entries)
        if (e.key != attribute) e.key: e.value,
    },
  );
}

/// Record the Character taking accommodation alternate [alternateId] (or
/// passing null to return to the canonical line). Throws [ArgumentError] for
/// an id that is not one of [segment]'s alternates.
CharacterVariant chooseAlternate(CharacterVariant variant, Segment segment, String? alternateId) {
  if (alternateId != null && !segment.alternates.any((a) => a.id == alternateId)) {
    throw ArgumentError.value(alternateId, 'alternateId', 'is not an alternate of this passage');
  }
  return variant.copyWith(chosenAlternateId: alternateId);
}

/// The Author's bands for [segment], each tightened to the Character's chosen
/// target where they set one — the constraint set a Character-scoped re-solve
/// would run against. Never widens a band, only narrows, and only within the
/// Author's own bounds; a `source` of `character` marks which bands the
/// Character moved so a later surface can tell them from the Author's.
List<Band> characterBands(Segment segment, CharacterVariant variant) {
  return [
    for (final band in segment.bands)
      if (variant.bandTargets[band.attribute] case final target?)
        band.copyWith(
          min: band.min == null ? null : target,
          max: band.max == null ? null : target,
          source: 'character',
        )
      else
        band,
  ];
}

/// The realised metrics for the Character's variant — the AC's "metrics
/// update on toggle".
///
/// Choosing an accommodation alternate swaps in that alternate's own
/// precomputed [RouteMetrics] (the Author attached them so alternates are
/// "comparable side-by-side", H10); the canonical [Segment.metrics] is
/// untouched and returned whenever no alternate is chosen, the chosen
/// alternate carries no metrics, or the route is unsolved. A narrowed FR6
/// band ([CharacterVariant.needsResolve]) is *not* reflected here — that
/// needs a Character-scoped solve — so a caller shows [needsResolve] state
/// rather than trusting these numbers after a band move.
RouteMetrics? variantMetrics(Segment segment, CharacterVariant variant) {
  final id = variant.chosenAlternateId;
  if (id == null) return segment.metrics;
  final alternate = segment.alternates.where((a) => a.id == id).firstOrNull;
  return alternate?.metrics ?? segment.metrics;
}

/// Additive roll-up of per-segment variant metrics for one day — distance,
/// climb, and descent only, matching `plotlines_core.trips.compose.roll_up`'s
/// additive fields. [variantFor] supplies the variant for a segment id, or
/// null to roll that segment up at its canonical metrics. Returns null when
/// no segment in the day has any metrics at all.
RouteMetrics? variantDayDistanceClimb(
  Iterable<Segment> segments,
  CharacterVariant? Function(String segmentId) variantFor,
) {
  double? distance;
  double? climb;
  double? descent;
  var any = false;
  for (final segment in segments) {
    final variant = variantFor(segment.id);
    final metrics = variant == null ? segment.metrics : variantMetrics(segment, variant);
    if (metrics == null) continue;
    any = true;
    if (metrics.distanceM != null) distance = (distance ?? 0) + metrics.distanceM!;
    if (metrics.climbM != null) climb = (climb ?? 0) + metrics.climbM!;
    if (metrics.descentM != null) descent = (descent ?? 0) + metrics.descentM!;
  }
  if (!any) return null;
  return RouteMetrics(distanceM: distance, climbM: climb, descentM: descent);
}

double? _metricValue(RouteMetrics? m, String attribute) {
  if (m == null) return null;
  return switch (attribute) {
    'distance_m' => m.distanceM,
    'climb_m' => m.climbM,
    'descent_m' => m.descentM,
    'traffic' => m.traffic,
    'unpaved_frac' => m.unpavedFrac,
    'scenic_frac' => m.scenicFrac,
    'salience' => m.salience,
    _ => null,
  };
}
