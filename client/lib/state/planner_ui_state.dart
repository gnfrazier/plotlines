// Ephemeral UI-only state — not part of the trip payload, so it lives
// outside domain/ entirely. Just enough for the planner to hand the New
// Route flow a target day without routing path params.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/domain.dart';

/// Set before navigating to `/new` when adding a segment to an existing
/// day; null means "start a new day". Read once by NewRouteScreen and reset.
final plannerTargetDayIdProvider = StateProvider<String?>((ref) => null);

/// Which segment is focused on the planner's map/metrics pane.
final selectedSegmentProvider = StateProvider<(String dayId, String segmentId)?>((ref) => null);

/// Resolves [selectedSegmentProvider]'s `(dayId, segmentId)` tuple against a
/// [Trip] — shared by the Route and Content tabs (`plan_tabs/route_tab.dart`,
/// `plan_tabs/content_tab.dart`) so there's exactly one lookup to keep
/// correct, not two hand-rolled scans that can silently drift.
(Day, Segment)? resolveSelectedSegment(Trip trip, (String, String)? selected) {
  if (selected == null) return null;
  for (final d in trip.days) {
    if (d.id != selected.$1) continue;
    for (final s in d.segments) {
      if (s.id == selected.$2) return (d, s);
    }
  }
  return null;
}

/// FR7/A7 — the shape a new passage starts on, until the Author picks
/// otherwise: loop, because it is the one shape that needs neither a
/// destination nor even a fixed turnaround, only a start and a target
/// distance. `NewRouteScreen`'s `_shape` reads this rather than a local
/// literal so the default has exactly one source of truth to test.
const defaultSegmentShape = 'loop';

/// FR7/A7's AC: "point-to-point requires a destination, loop/out-and-back
/// require only a start." `hasTargetM` covers both loop's own required
/// target distance and out-and-back's target-distance alternative to a
/// picked-by-hand turnaround (`routing/loops.py`'s `generate_out_and_back`
/// accepts either); `hasEnd` alone never satisfies loop, which closes on
/// its own start by definition (`service/app.py` ignores `end` there).
bool canGenerateShape({
  required String shape,
  required bool hasStart,
  required bool hasEnd,
  required bool hasTargetM,
}) {
  if (!hasStart) return false;
  return switch (shape) {
    'loop' => hasTargetM,
    'out_and_back' => hasEnd || hasTargetM,
    _ => hasEnd, // point_to_point, and any shape this planner doesn't know yet
  };
}

/// FR8/A8's AC: "target-distance control for loop/out-and-back only... "
/// point-to-point has no target-distance input." Point-to-point's start/end
/// (A7) already govern its route, so there is nothing for a target distance
/// to constrain — `new_route_screen.dart`'s creation flow already gates its
/// own target-distance field on this same pair of shapes.
bool hasTargetDistanceControl(String shape) => shape == 'loop' || shape == 'out_and_back';

/// FR8/A8, SPIKE-03 §4 (`spikes/SPIKE-03/results/RESULTS.md`): left unbanded,
/// the search silently spent up to +14.8% extra mileage satisfying other
/// bands. §3's convergence sweep found two-sided bands hold to within ±10%
/// of centre in every region tested (±5% failed in one of three) — the
/// half-width a fresh target distance is banded to by default. Mirrors
/// `core/plotlines_core/scoring/bands.py`'s `DEFAULT_DISTANCE_BAND_FRAC`
/// (kept as an independently-declared constant, not a cross-language import —
/// see that module's own citation of the same spike section).
const double defaultDistanceBandFrac = 0.10;

/// FR8/A8's AC: "banded by default in explore mode." Always centres the band
/// on [valueM] — there is deliberately no way back to an unbanded target
/// short of clearing the target itself, which is the AC's "never dropped
/// from the explore search's constraint set."
TargetDistance bandedTargetDistance(double valueM, {double halfWidthFrac = defaultDistanceBandFrac}) {
  final half = valueM * halfWidthFrac;
  return TargetDistance(valueM: valueM, minM: valueM - half, maxM: valueM + half);
}

/// FR117/A0 — the Author's per-day choice of **explore** (distance/shape/
/// weights/bands in, route out) or **compose** (promoted anchors in, route
/// out). ARCH §7.7: "not a second solver" — the two postures share every
/// authored field a segment already has (`via`, `weights`, `targetDistance`);
/// only which of them the outgoing solve request honors changes. That is
/// what makes FR119's "switch either way, no work lost" free: nothing about
/// a segment is mutated by a mode switch, only how it is presented and sent.
enum PlanningMode { explore, compose }

/// Ephemeral, like the rest of this file: a reopened trip starts back in
/// explore, the same way [selectedSegmentProvider] starts unselected. There
/// is no `trip_payload.schema.json` field for this because there is nothing
/// authored to lose — the segment fields the two postures read are already
/// persisted on their own.
final dayPlanningModeProvider =
    StateProvider.family<PlanningMode, String>((ref, dayId) => PlanningMode.explore);

/// ARCH §7.7 — the one difference the solve request itself carries between
/// the two postures: explore sends whatever target distance the Author
/// authored as a constraint, compose sends none so the engine reports
/// realized length as an outcome instead of chasing a band. Never clears
/// [targetDistance] itself — only the outgoing request — which is what lets
/// a day return to explore with its old constraint intact (FR119).
double? composeAwareTargetM(PlanningMode mode, TargetDistance? targetDistance) =>
    mode == PlanningMode.compose ? null : targetDistance?.valueM;

/// FR119's "compose -> loosen the spine -> explore": a day switching back to
/// explore with no explore constraint of its own yet inherits compose's
/// discovered length as its starting point, rather than opening on an empty
/// distance field. An existing explore target always wins — this only fills
/// a gap, never overwrites authored work.
double? loosenedTargetDistanceM({
  required TargetDistance? existingTarget,
  required double? realizedDistanceM,
}) =>
    existingTarget?.valueM ?? realizedDistanceM;

/// FR118/A0a — the stated band a compose day's realized distance is judged
/// against: the segment's own `distance_m` [Band], when the Author (or
/// FR119's carry-over from an explore session) has set one. Absent whenever
/// none exists — A0a's AC compares against "any stated band," not a band
/// compose mode requires; `TargetDistance.minM/maxM` is a separate, explore-
/// only banding mechanism (FR8) and is not read here.
Band? statedDistanceBand(Segment segment) {
  for (final band in segment.bands) {
    if (band.attribute == 'distance_m' && (band.min != null || band.max != null)) {
      return band;
    }
  }
  return null;
}

/// FR118 — does [realizedDistanceM] fall outside [band]? `null` means there
/// is nothing yet to judge (no realized distance, or no stated band) —
/// distinct from `false`, a real "within band" reading.
bool? distanceDeviatesFromBand(double? realizedDistanceM, Band? band) {
  if (realizedDistanceM == null || band == null) return null;
  if (band.min != null && realizedDistanceM < band.min!) return true;
  if (band.max != null && realizedDistanceM > band.max!) return true;
  return false;
}

/// FR9/A6's AC: "the best-effort route and its band violations return with
/// the initial solve" — synchronous, unlike the named-conflict-plus-
/// relaxations half of A6 (`RoutingClient.submitDiagnose`/`pollDiagnose`),
/// which SPIKE-02 measured at 1.3-15.0s and cannot sit inside a solve
/// request. Knowing *whether* a band was missed, and by how much, costs
/// nothing beyond comparing numbers the solve already returned, so this runs
/// client-side right after every explore-mode regenerate
/// (`CurrentTripNotifier.regenerateSegment`) rather than waiting on a
/// diagnose round trip just to learn there is nothing to diagnose.
///
/// Compose mode never calls this — its own band (distance only) goes through
/// [distanceDeviatesFromBand]/A0a, which is deliberately a separate surface
/// from A6/M13 (ARCH D53).
List<Violation> bandViolations(RouteMetrics? metrics, List<Band> bands) {
  if (metrics == null) return const [];
  final out = <Violation>[];
  for (final band in bands) {
    final value = _bandableMetricValue(metrics, band.attribute);
    if (value == null) continue;
    double shortfall;
    if (band.min != null && value < band.min!) {
      shortfall = value - band.min!;
    } else if (band.max != null && value > band.max!) {
      shortfall = value - band.max!;
    } else {
      shortfall = 0.0;
    }
    if (shortfall != 0.0) {
      out.add(Violation(attribute: band.attribute, realised: value, shortfall: shortfall));
    }
  }
  return out;
}

/// The realized-attribute values [Band.attribute] can name (`band.dart`'s
/// `attributeValues`), read off [RouteMetrics] — every one of those
/// attributes is a metrics field of the same name.
double? _bandableMetricValue(RouteMetrics metrics, String attribute) {
  switch (attribute) {
    case 'distance_m':
      return metrics.distanceM;
    case 'climb_m':
      return metrics.climbM;
    case 'descent_m':
      return metrics.descentM;
    case 'traffic':
      return metrics.traffic;
    case 'unpaved_frac':
      return metrics.unpavedFrac;
    case 'scenic_frac':
      return metrics.scenicFrac;
    case 'salience':
      return metrics.salience;
    default:
      return null;
  }
}

/// FR118's quoted editing-decision headline — *"these seven plot points
/// make a 94-mile day; your band was 55–70"* — built from the segment
/// actually in front of the Author. Reports in km, matching this rail's
/// other realized-distance readout (`_TargetDistanceField`'s compose
/// branch in `weights_rail.dart`) rather than the AC's illustrative miles —
/// this app's distance prose is km throughout, and A0a is not the place to
/// introduce a second unit system.
String composeDeviationHeadline({
  required int placeCount,
  required double realizedDistanceM,
  Band? band,
}) {
  final km = (realizedDistanceM / 1000).toStringAsFixed(1);
  final noun = placeCount == 1 ? 'plot point' : 'plot points';
  final base = 'These $placeCount $noun make a $km km day.';
  if (band == null) return base;
  return '$base Your band was ${_describeBandKm(band)}.';
}

String _describeBandKm(Band band) {
  final min = band.min == null ? null : (band.min! / 1000).toStringAsFixed(1);
  final max = band.max == null ? null : (band.max! / 1000).toStringAsFixed(1);
  if (min != null && max != null) return '$min–$max km';
  if (min != null) return 'at least $min km';
  return 'at most $max km';
}

/// FR118/A0a — "widen the band" is one of the deviation panel's five
/// affordances: re-widens [band] to admit [realizedDistanceM] on whichever
/// side it currently violates, leaving the other side untouched. A no-op
/// input ([band] already admitting the value) is never called by the panel
/// — the affordance only appears when [distanceDeviatesFromBand] is `true`.
Band widenBandToAdmit(Band band, double realizedDistanceM) => band.copyWith(
      min: (band.min != null && realizedDistanceM < band.min!) ? realizedDistanceM : band.min,
      max: (band.max != null && realizedDistanceM > band.max!) ? realizedDistanceM : band.max,
    );

/// FR118 — "accept" is the fifth affordance: acknowledging the deviation
/// rather than acting on it. Ephemeral, like [dayPlanningModeProvider],
/// keyed by segment id, and storing the realized distance *at* the moment
/// of acceptance rather than a bare flag — so a later edit that changes the
/// realized distance (a dropped anchor, a re-solve) silently un-accepts
/// instead of leaving a stale acknowledgement standing over a new number.
final composeDeviationAcceptedProvider =
    StateProvider.family<double?, String>((ref, segmentId) => null);

/// Whether an earlier "accept" (recorded as [acceptedAtDistanceM]) still
/// covers the current [realizedDistanceM] — a small tolerance rather than
/// exact equality, since re-solving the identical spine can return a
/// float that differs in the last decimal without being a new deviation.
bool isDeviationAccepted({
  required double? acceptedAtDistanceM,
  required double? realizedDistanceM,
}) =>
    acceptedAtDistanceM != null &&
    realizedDistanceM != null &&
    (acceptedAtDistanceM - realizedDistanceM).abs() < 1.0;
