"""WeightProfile and the multi-factor scoring function (ARCH §6.2, §6.3).

§6.3's rule — "themes are data, not algorithms" — is honoured here: a theme is a
WeightProfile (plain data), and there is exactly one scoring function that consumes it.
Adding a theme must never mean adding a code path.

SPIKE-00 scope: enough real factors to make edge costs vary meaningfully across a real
graph. SPIKE-01/02/03 added `peaks` (FR2) — see below — and left everything else
untouched so SPIKE-00's measured routes remain reproducible.

Author-facing scale: the PRD states weights as 0.0–5.0 (FR2–FR5). Internally they are
0.0–1.0 (and -1..1 for `peaks`), so a UI value maps linearly: `w = ui / 5.0`, and for
peaks `w = (ui - 2.5) / 2.5`, since FR2's scale is explicitly bipolar
("flat ↔ maximal climbing") with a neutral middle. FR3's "cars" is the inverse case —
the Author-facing scale is a *tolerance* (0 avoid cars .. 5 seek directness), while
`quiet` below is an *aversion* strength, so the client-side conversion inverts rather
than scales directly (`weight_profile.dart`'s `quietFromTraffic`).

FR3 / ARCH D33 / SPIKE-03 §5: traffic stress is not simply read off `highway=*`
below — see `_TRAFFIC_STRESS`'s doc.

FR4 (Story A3) / SPIKE-03 §"lower-priority": surface, like `peaks`, is bipolar per
class (paved / gravel / singletrack), each -1.0 avoid .. 0.0 indifferent ..
+1.0 seek — a unipolar dial can only ever *tolerate* a class, never *seek* it
outright, which is the defect SPIKE-03 measured (no unpaved-minimum band was
satisfiable anywhere). The Author-facing conversion is the same
`w = (ui - 2.5) / 2.5` as `peaks`, applied once per class
(`weight_profile.dart`'s `surfaceWeightsFromAuthor`).
"""

from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field

# Surface desirability, 0.0 (avoid) .. 1.0 (ideal), for a general "bike" profile.
# Feeds `unpaved_frac` reporting (metrics.py) only — FR4's per-class *weighting*
# below uses `surface_bucket`, not this scale.
_SURFACE_QUALITY: dict[str, float] = {
    "asphalt": 1.0, "paved": 1.0, "concrete": 0.9, "paving_stones": 0.7,
    "compacted": 0.7, "fine_gravel": 0.65, "gravel": 0.5, "unpaved": 0.45,
    "ground": 0.35, "dirt": 0.35, "grass": 0.2, "sand": 0.1,
}

# FR4's three classes, from the `surface` tag's tread material. Mirrors
# `trips/cues.py`'s `_PAVED`/`_GRAVEL` sets (cue text stays two-bucket; this is
# scoring's own three-bucket read of the same tag).
_PAVED_SURFACE = frozenset({
    "asphalt", "paved", "concrete", "concrete:plates", "concrete:lanes",
    "paving_stones", "sett", "cobblestone", "chipseal", "metal", "wood",
    "bricks", "brick",
})
_UNPAVED_SURFACE = frozenset({
    "gravel", "fine_gravel", "compacted", "unpaved", "dirt", "ground", "earth",
    "grass", "sand", "mud", "pebblestone", "rock", "woodchips",
})

# `highway` classes narrow enough to read as a trail rather than a road, once the
# tread is unpaved or untagged. `cues.py.surface_class` explicitly leaves FR4's
# third class unmodeled ("no source here... a modelling decision this function
# deliberately leaves to whoever takes it", SPIKE-21 §5.3) — this is that
# decision, scoped to scoring (a routing bias) rather than to cue text. Per
# `docs/osm_reference.md`'s "off-road singletrack/trail" row, `path`/`bridleway`
# are the classes that carry that character; `track` is left out because it
# reads more like a double-track farm/forest road (SPIKE-03's "gravel" theme
# territory) than singletrack.
_SINGLETRACK_HIGHWAY = frozenset({"path", "bridleway"})


def surface_bucket(highway: str, data: dict) -> str | None:
    """`paved` / `gravel` / `singletrack` / `None` (unknown) — the class FR4's
    per-class weights bias on.

    Tread material (`surface`) decides paved vs. gravel wherever it is tagged,
    same as `cues.py.surface_class`. Singletrack has no tag of its own — it's a
    way-*width* fact, not a tread fact — so a natural (unpaved or untagged) tread
    on a narrow trail way reads as singletrack, while the identical tread on a
    wider way (`track`, `residential`, ...) reads as gravel. An unknown surface
    on anything but a trail way stays unknown, same as `cues.py`'s rule: absence
    is a fact about the map, never guessed into a value.
    """
    surface = _first(data.get("surface"))
    surface = str(surface).lower() if surface else None
    if surface in _PAVED_SURFACE:
        return "paved"
    is_trail_way = highway in _SINGLETRACK_HIGHWAY
    if surface in _UNPAVED_SURFACE:
        return "singletrack" if is_trail_way else "gravel"
    if surface is None and is_trail_way:
        return "singletrack"
    return None

# Traffic stress by highway class, 0.0 (calm) .. 1.0 (hostile) — the *ceiling* a class
# can reach, not what every edge of that class gets (see `_stress` below).
_TRAFFIC_STRESS: dict[str, float] = {
    "cycleway": 0.0, "path": 0.05, "track": 0.1, "footway": 0.15,
    "living_street": 0.2, "residential": 0.3, "unclassified": 0.4,
    "tertiary": 0.55, "secondary": 0.75, "primary": 0.9, "trunk": 1.0,
}

# FR3 / ARCH D33 / SPIKE-03 §5: for these classes the tag itself is decisive — a
# cycleway or a residential street is calm by definition, maxspeed/lanes or not.
_EXPLICIT_STRESS_CLASSES = frozenset({
    "cycleway", "path", "track", "footway", "living_street", "residential",
})

# Every other class (tertiary/secondary/primary/trunk/unclassified, and anything
# untagged or unrecognised) is ambiguous: SPIKE-03 measured Viroqua's rural county
# roads tagged `tertiary`/`secondary` sitting at a manufactured 35-48% "traffic
# exposure" floor purely from the class tag, though nothing distinguishes them from a
# genuinely busy road of the same class. D33 resolves this: these classes are the
# model's zero-stress baseline, and only a real capacity/speed signal — `maxspeed` or
# `lanes` — raises them off it, up to the class's usual ceiling above.
_MAXSPEED_SIGNAL_KMH = 50.0  # above a typical rural road's posted speed (25-45 km/h)
_LANES_SIGNAL = 4  # more than one lane in each direction


def _first(value):
    """OSM tags arrive as str or list[str] depending on way merging."""
    return value[0] if isinstance(value, list) and value else value


def _maxspeed_kmh(value) -> float | None:
    """Parse an OSM `maxspeed` tag to km/h, or `None` if absent/unparseable.

    Handles bare km/h ("50"), explicit mph ("35 mph"), and leaves non-numeric
    conventions (`"walk"`, `"national"`, `"none"`) as no signal rather than guessing.
    """
    value = _first(value)
    if value is None:
        return None
    text = str(value).strip().lower()
    try:
        if text.endswith("mph"):
            return float(text[:-3].strip()) * 1.60934
        return float(text)
    except ValueError:
        return None


def _lane_count(value) -> int | None:
    value = _first(value)
    if value is None:
        return None
    try:
        return int(float(str(value).strip()))
    except ValueError:
        return None


def _has_capacity_signal(data: dict) -> bool:
    """The "contrary signal" D33 requires before a low-signal class's stress rises
    off its zero baseline: a real posted speed or lane count, not the class tag."""
    maxspeed = _maxspeed_kmh(data.get("maxspeed"))
    if maxspeed is not None and maxspeed >= _MAXSPEED_SIGNAL_KMH:
        return True
    lanes = _lane_count(data.get("lanes"))
    if lanes is not None and lanes >= _LANES_SIGNAL:
        return True
    return False


def _stress(highway: str, data: dict) -> float:
    """FR3 / D33 — road-class ceiling gated by a vehicle-density/speed threshold."""
    class_stress = _TRAFFIC_STRESS.get(highway, 0.5)
    if highway in _EXPLICIT_STRESS_CLASSES or _has_capacity_signal(data):
        return class_stress
    return 0.0


@dataclass(frozen=True)
class WeightProfile:
    """A theme, expressed as data. All weights 0.0..1.0."""

    name: str = "balanced"
    quiet: float = 0.5       # prefer low-traffic ways
    scenic: float = 0.5      # prefer green/park/water-adjacent ways
    directness: float = 0.5  # penalise detour; 1.0 ≈ shortest path
    # FR2 "peaks", the one bipolar weight: -1.0 avoid climbing .. 0.0 indifferent ..
    # +1.0 seek climbing. Zero is the identity, which is why adding it did not change
    # any route SPIKE-00 measured.
    peaks: float = 0.0
    # FR4 "surface", one bipolar dial per class, same shape as `peaks` and same
    # reason: 0.0 is indifferent/identity, -1.0 avoids that class outright, +1.0
    # seeks it outright — an Author can point the engine at gravel or singletrack,
    # not merely relax pavement preference toward zero (SPIKE-03).
    surface_paved: float = 0.0
    surface_gravel: float = 0.0
    surface_singletrack: float = 0.0
    extras: dict[str, float] = field(default_factory=dict)

    def __post_init__(self) -> None:
        for key in ("quiet", "scenic", "directness"):
            val = getattr(self, key)
            if not 0.0 <= val <= 1.0:
                raise ValueError(f"weight {key}={val} outside 0.0..1.0")
        for key in ("peaks", "surface_paved", "surface_gravel", "surface_singletrack"):
            val = getattr(self, key)
            if not -1.0 <= val <= 1.0:
                raise ValueError(f"weight {key}={val} outside -1.0..1.0")

    def replace(self, **changes) -> WeightProfile:
        """A copy with some weights changed — what a band search walks over."""
        return dataclasses.replace(self, **changes)


#: Weight names the band search may tune, with their legal range.
TUNABLE: dict[str, tuple[float, float]] = {
    "quiet": (0.0, 1.0),
    "scenic": (0.0, 1.0),
    "directness": (0.0, 1.0),
    "peaks": (-1.0, 1.0),
    "surface_paved": (-1.0, 1.0),
    "surface_gravel": (-1.0, 1.0),
    "surface_singletrack": (-1.0, 1.0),
}


#: Grade at which the climbing term saturates. Above ~12% a cyclist is walking, so
#: more gradient stops reading as "more climbing" and starts reading as "impassable".
_GRADE_SATURATION = 0.12


def features(data: dict) -> tuple[float, float, float, bool, float, str | None]:
    """Static per-edge features: (length_m, stress, surface_quality, scenic, grade,
    surface_bucket).

    Cached onto the edge dict. SPIKE-03's band search re-solves one graph dozens of
    times per scenario, and re-parsing OSM tag lists on every Dijkstra relaxation made
    the search a measurement of string handling rather than of routing.
    """
    cached = data.get("_pl_feat")
    if cached is not None:
        return cached

    length = float(data.get("length", 1.0)) or 1.0

    highway = _first(data.get("highway")) or "unclassified"
    stress = _stress(highway, data)

    surface = _first(data.get("surface"))
    quality = _SURFACE_QUALITY.get(surface, 0.6)  # untagged ≈ mediocre-but-fine
    bucket = surface_bucket(highway, data)

    # Scenic proxy: OSM doesn't tag "scenic", so stand in with the signals that
    # correlate with it on a real graph. A real implementation reads content/ POIs.
    name = str(_first(data.get("name")) or "").lower()
    scenic_hit = any(
        token in name for token in ("trail", "creek", "park", "greenway", "path")
    ) or highway in ("cycleway", "path")

    # `grade_abs` is baked in at fixture-build time by osmnx from node elevations.
    try:
        grade = abs(float(_first(data.get("grade_abs")) or 0.0))
    except (TypeError, ValueError):
        grade = 0.0

    feat = (length, stress, quality, scenic_hit, grade, bucket)
    data["_pl_feat"] = feat
    return feat


#: Class name -> the `WeightProfile` field that biases it (FR4).
_SURFACE_WEIGHT_FIELD = {
    "paved": "surface_paved",
    "gravel": "surface_gravel",
    "singletrack": "surface_singletrack",
}


def edge_cost(data: dict, profile: WeightProfile) -> float:
    """The one scoring function. Returns a positive cost for one edge."""
    length, stress, quality, scenic_hit, grade, bucket = features(data)

    penalty = 1.0
    penalty += profile.quiet * stress * 2.0
    if scenic_hit:
        penalty -= profile.scenic * 0.35

    # FR4, bipolar per class like peaks below: negative avoids this edge's class
    # (charges a penalty), positive seeks it (discounts). An edge whose class is
    # unknown (`bucket is None`) carries no surface bias at all — an unclassifiable
    # edge is neither sought nor avoided by any class weight.
    if bucket is not None:
        surface_weight = getattr(profile, _SURFACE_WEIGHT_FIELD[bucket])
        if surface_weight:
            penalty -= surface_weight * 0.6

    # FR2. Positive peaks discount steep edges (seek them), negative peaks charge for
    # them (stay flat). The clamp below keeps every cost strictly positive, which
    # Dijkstra requires — a "seek climbing" weight must never buy a negative edge.
    if profile.peaks:
        penalty -= profile.peaks * (min(grade, _GRADE_SATURATION) / _GRADE_SATURATION) * 0.6

    # directness pulls every penalty back toward pure distance
    penalty = 1.0 + (penalty - 1.0) * (1.0 - profile.directness)

    return length * max(penalty, 0.05)


THEMES: dict[str, WeightProfile] = {
    "balanced": WeightProfile("balanced"),
    "quiet_scenic": WeightProfile("quiet_scenic", quiet=0.9, scenic=0.9,
                                  directness=0.2, surface_paved=0.4),
    "fastest": WeightProfile("fastest", quiet=0.1, scenic=0.0, directness=0.95),
    # FR4 / SPIKE-03's own flagged example: this theme's whole point is to prefer
    # gravel, which the old unipolar `surface` dial could only ever *tolerate*
    # (surface=0.0, i.e. fully relaxed), never actually seek. Bipolar fixes it.
    "gravel": WeightProfile("gravel", quiet=0.8, scenic=0.7, directness=0.3,
                            surface_gravel=1.0, surface_singletrack=0.3,
                            surface_paved=-0.5),
}
