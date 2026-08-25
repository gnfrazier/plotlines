/// `$defs/weight_profile` (ARCH §6.3's WeightProfile, Author-facing form) plus the
/// solver-internal theme catalog it is deliberately NOT the same shape as.
///
/// Two distinct `WeightProfile`s exist in this codebase and neither is a mistake:
///
///  * [WeightProfile] here mirrors `plotlines_core.trips.payload.WeightProfile` —
///    what an Author sets, 0.0-5.0, bipolar for `climbing`/`surface`/`traffic`
///    (FR2-FR4) but unipolar for `interest` (FR5 — no "avoid good places" case).
///    This is the one stored in `trip.payload` and is the schema's
///    `weight_profile` $def.
///  * [ThemeWeightProfile] mirrors `plotlines_core.scoring.profile.WeightProfile` —
///    the solver's internal 0.0-1.0 form (`quiet`/`surface`/`scenic`/`directness`,
///    `peaks` -1.0-1.0), named and catalogued in [themes]. `service/app.py`'s
///    `/segments/generate` takes a `theme` name against exactly this catalogue, or a
///    raw `weights` map matching these field names — never the Author-facing scale.
///
/// Storing both forms of one preference is what payload.py's docstring warns against
/// for the *same* concept; these are two different concepts (what the Author asked
/// for vs. what the solver consumes) and the payload never stores the second.
library;

import 'json_utils.dart';

class WeightProfile {
  WeightProfile({
    required this.name,
    this.climbing,
    this.traffic,
    this.surface = const {},
    this.interest,
    this.terrainTechnicality,
  });

  final String name;
  final double? climbing;
  final double? traffic;
  final Map<String, double> surface;

  /// FR5 (Story A4) / ARCH D46 — a single 0.0-5.0 salience bias, no POI-type
  /// parameter and no `detour_budget`. Unipolar, unlike [climbing]/[traffic]/
  /// [surface]: 0.0 is "no bias", not "avoid good places". Explore-mode only.
  final double? interest;
  final double? terrainTechnicality;

  factory WeightProfile.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'weight_profile');
    final name = f.takeString('name')!;
    final climbing = f.takeNum('climbing');
    final traffic = f.takeNum('traffic');
    final surface = f.takeWeights('surface');
    final interest = f.takeNum('interest');
    final technicality = f.takeNum('terrain_technicality');
    f.done();
    return WeightProfile(
      name: name,
      climbing: climbing,
      traffic: traffic,
      surface: surface,
      interest: interest,
      terrainTechnicality: technicality,
    );
  }

  Map<String, dynamic> toJson() => pruneJson({
        'name': name,
        'climbing': climbing == null ? null : finite(climbing!, 'weight_profile.climbing'),
        'traffic': traffic == null ? null : finite(traffic!, 'weight_profile.traffic'),
        'surface': surface.isEmpty
            ? null
            : surface.map((k, v) => MapEntry(k, finite(v, 'weight_profile.surface.$k'))),
        'interest': interest == null ? null : finite(interest!, 'weight_profile.interest'),
        'terrain_technicality': terrainTechnicality == null
            ? null
            : finite(terrainTechnicality!, 'weight_profile.terrain_technicality'),
      });

  WeightProfile copyWith({
    String? name,
    double? climbing,
    double? traffic,
    Map<String, double>? surface,
    double? interest,
    double? terrainTechnicality,
  }) =>
      WeightProfile(
        name: name ?? this.name,
        climbing: climbing ?? this.climbing,
        traffic: traffic ?? this.traffic,
        surface: surface ?? this.surface,
        interest: interest ?? this.interest,
        terrainTechnicality: terrainTechnicality ?? this.terrainTechnicality,
      );

  /// A copy with one surface class's weight set, leaving the rest untouched — the
  /// per-class dial FR4 requires (absent class reads as indifferent).
  WeightProfile withSurfaceClass(String surfaceClass, double value) =>
      copyWith(surface: {...surface, surfaceClass: value});
}

/// FR2/A1 — the Author-facing 0.0-5.0 "peaks" scale mapped onto
/// [ThemeWeightProfile.peaks]'s solver-internal bipolar -1.0..1.0 scale, per
/// `scoring/profile.py`'s documented conversion: `w = (ui - 2.5) / 2.5`. 2.5
/// is the midpoint of both scales — "indifferent" on the Author-facing side,
/// `0.0` (the identity weight; see `ThemeWeightProfile.peaks`'s doc) on the
/// solver side — so it maps to itself. `null` (no climbing preference
/// authored) stays `null`: the caller omits the `peaks` key from the solve
/// request entirely rather than sending an invented 0.0 (MVP punchlist
/// §2A.4 — this is the "one mapping function" it asks for, scoped to the
/// Dart side, which is where the Author-facing scale actually originates).
double? peaksFromClimbing(double? climbing) =>
    climbing == null ? null : (climbing - 2.5) / 2.5;

/// FR3/A2 — the Author-facing 0.0-5.0 "cars" (traffic-tolerance) scale mapped onto
/// [ThemeWeightProfile.quiet]'s solver-internal 0.0..1.0 scale.
///
/// Unlike [peaksFromClimbing], this is an inversion, not a direct scaling: `traffic`
/// is a *tolerance* (0.0 "avoid cars" .. 5.0 "seek cars"/direct urban egress), while
/// `quiet` is the solver's *aversion to traffic* strength (`scoring/profile.py`'s
/// `edge_cost`: `penalty += quiet * stress`, so `quiet` only ever penalises stress —
/// there is no "reward high-traffic edges" case). Low tolerance must therefore map to
/// *high* quiet-aversion for A2's AC ("at low tolerance the route measurably favors
/// lower road classes") to hold: `w = (5.0 - ui) / 5.0`. The Author-facing midpoint
/// (2.5, "indifferent") lands on 0.5, matching `ThemeWeightProfile.quiet`'s own
/// default and the `balanced` theme. `null` (no preference authored) stays `null`,
/// same rule as `peaksFromClimbing`.
double? quietFromTraffic(double? traffic) =>
    traffic == null ? null : (5.0 - traffic) / 5.0;

/// FR4/A3 — the Author-facing per-class 0.0-5.0 surface dials (`WeightProfile.surface`,
/// keyed `paved`/`gravel`/`singletrack`, each avoid<->indifferent<->seek) mapped onto
/// [ThemeWeightProfile]'s solver-internal bipolar -1.0..1.0 `surface_<class>` fields,
/// one class at a time, via the same `w = (ui - 2.5) / 2.5` conversion as
/// [peaksFromClimbing] — FR4 is bipolar for exactly the reason FR2 is (SPIKE-03:
/// "FR4's surface weight needs to be bipolar ... matching FR2's peaks", since a
/// unipolar dial can only ever tolerate a class, never seek it outright).
///
/// Unlike the single `climbing` dial this maps a *map* to a *map*: a class absent
/// from `surface` stays absent from the result — the schema's "absent class =
/// indifferent" rule already covers it, and omitting the key (not sending an
/// invented 0.0) is how the solve request expresses that, same rule as
/// [peaksFromClimbing]'s `null` handling. Result keys are
/// [ThemeWeightProfile]'s own `surface_<class>` field names, ready to spread
/// straight into a `weights` request map.
Map<String, double> surfaceWeightsFromAuthor(Map<String, double> surface) => {
      for (final entry in surface.entries) 'surface_${entry.key}': (entry.value - 2.5) / 2.5,
    };

/// FR5/A4 — the Author-facing 0.0-5.0 "interest" scale mapped onto
/// [ThemeWeightProfile.interest]'s solver-internal 0.0..1.0 scale.
///
/// Unlike [peaksFromClimbing]/[surfaceWeightsFromAuthor], this is the ordinary
/// `w = ui / 5.0` conversion the module doc opens with, not the bipolar
/// `(ui - 2.5) / 2.5` one — `interest` has no "avoid good places" reading, so
/// there is no indifference point to re-center around. `null` (no preference
/// authored) stays `null`, same omit-rather-than-invent rule as every other
/// conversion here.
double? interestFromAuthor(double? interest) => interest == null ? null : interest / 5.0;

/// `plotlines_core.scoring.profile.WeightProfile` — the solver's internal 0.0-1.0
/// theme shape. Never round-tripped through `trip.payload`; only through the
/// sidecar's `/segments/generate` (`theme` name or raw `weights` map).
class ThemeWeightProfile {
  const ThemeWeightProfile(
    this.name, {
    this.quiet = 0.5,
    this.scenic = 0.5,
    this.directness = 0.5,
    this.peaks = 0.0,
    this.surfacePaved = 0.0,
    this.surfaceGravel = 0.0,
    this.surfaceSingletrack = 0.0,
    this.interest = 0.0,
    this.extras = const {},
  });

  final String name;
  final double quiet;
  final double scenic;
  final double directness;

  /// FR2, bipolar: -1.0 avoid climbing .. 0.0 indifferent .. 1.0 seek climbing.
  final double peaks;

  /// FR4, one bipolar dial per class, same shape as [peaks]: -1.0 avoid ..
  /// 0.0 indifferent .. 1.0 seek that class outright.
  final double surfacePaved;
  final double surfaceGravel;
  final double surfaceSingletrack;

  /// FR5, unipolar unlike [peaks]/the surface dials: 0.0 no bias .. 1.0 max
  /// bias toward high-salience candidates (FR98). Explore-mode only.
  final double interest;
  final Map<String, double> extras;

  factory ThemeWeightProfile.fromJson(Map<String, dynamic> json) {
    final f = JsonFields(json, 'theme_weight_profile');
    final profile = ThemeWeightProfile(
      f.takeString('name') ?? 'balanced',
      quiet: f.takeNum('quiet') ?? 0.5,
      scenic: f.takeNum('scenic') ?? 0.5,
      directness: f.takeNum('directness') ?? 0.5,
      peaks: f.takeNum('peaks') ?? 0.0,
      surfacePaved: f.takeNum('surface_paved') ?? 0.0,
      surfaceGravel: f.takeNum('surface_gravel') ?? 0.0,
      surfaceSingletrack: f.takeNum('surface_singletrack') ?? 0.0,
      interest: f.takeNum('interest') ?? 0.0,
      extras: f.takeWeights('extras'),
    );
    f.done();
    return profile;
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'quiet': finite(quiet, 'theme_weight_profile.quiet'),
        'scenic': finite(scenic, 'theme_weight_profile.scenic'),
        'directness': finite(directness, 'theme_weight_profile.directness'),
        'peaks': finite(peaks, 'theme_weight_profile.peaks'),
        'surface_paved': finite(surfacePaved, 'theme_weight_profile.surface_paved'),
        'surface_gravel': finite(surfaceGravel, 'theme_weight_profile.surface_gravel'),
        'surface_singletrack':
            finite(surfaceSingletrack, 'theme_weight_profile.surface_singletrack'),
        'interest': finite(interest, 'theme_weight_profile.interest'),
        if (extras.isNotEmpty)
          'extras': extras.map((k, v) => MapEntry(k, finite(v, 'theme_weight_profile.extras.$k'))),
      };
}

/// `scoring.profile.THEMES` — the named theme catalogue `service/app.py`'s
/// `SegmentRequest.theme` (default `"balanced"`) resolves against.
const Map<String, ThemeWeightProfile> themes = {
  'balanced': ThemeWeightProfile('balanced'),
  'quiet_scenic': ThemeWeightProfile('quiet_scenic',
      quiet: 0.9, scenic: 0.9, directness: 0.2, surfacePaved: 0.4),
  'fastest': ThemeWeightProfile('fastest', quiet: 0.1, scenic: 0.0, directness: 0.95),
  // FR4: seeks gravel outright rather than merely tolerating it — see
  // `scoring/profile.py`'s `THEMES['gravel']` doc for why this is the theme
  // SPIKE-03 flagged as broken under the old unipolar dial.
  'gravel': ThemeWeightProfile('gravel',
      quiet: 0.8, scenic: 0.7, directness: 0.3,
      surfaceGravel: 1.0, surfaceSingletrack: 0.3, surfacePaved: -0.5),
};
