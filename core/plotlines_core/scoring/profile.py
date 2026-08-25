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
"""

from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field

# Surface desirability, 0.0 (avoid) .. 1.0 (ideal), for a general "bike" profile.
_SURFACE_QUALITY: dict[str, float] = {
    "asphalt": 1.0, "paved": 1.0, "concrete": 0.9, "paving_stones": 0.7,
    "compacted": 0.7, "fine_gravel": 0.65, "gravel": 0.5, "unpaved": 0.45,
    "ground": 0.35, "dirt": 0.35, "grass": 0.2, "sand": 0.1,
}

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
    surface: float = 0.5     # prefer good surface
    scenic: float = 0.5      # prefer green/park/water-adjacent ways
    directness: float = 0.5  # penalise detour; 1.0 ≈ shortest path
    # FR2 "peaks", the one bipolar weight: -1.0 avoid climbing .. 0.0 indifferent ..
    # +1.0 seek climbing. Zero is the identity, which is why adding it did not change
    # any route SPIKE-00 measured.
    peaks: float = 0.0
    extras: dict[str, float] = field(default_factory=dict)

    def __post_init__(self) -> None:
        for key in ("quiet", "surface", "scenic", "directness"):
            val = getattr(self, key)
            if not 0.0 <= val <= 1.0:
                raise ValueError(f"weight {key}={val} outside 0.0..1.0")
        if not -1.0 <= self.peaks <= 1.0:
            raise ValueError(f"weight peaks={self.peaks} outside -1.0..1.0")

    def replace(self, **changes) -> WeightProfile:
        """A copy with some weights changed — what a band search walks over."""
        return dataclasses.replace(self, **changes)


#: Weight names the band search may tune, with their legal range.
TUNABLE: dict[str, tuple[float, float]] = {
    "quiet": (0.0, 1.0),
    "surface": (0.0, 1.0),
    "scenic": (0.0, 1.0),
    "directness": (0.0, 1.0),
    "peaks": (-1.0, 1.0),
}


#: Grade at which the climbing term saturates. Above ~12% a cyclist is walking, so
#: more gradient stops reading as "more climbing" and starts reading as "impassable".
_GRADE_SATURATION = 0.12


def features(data: dict) -> tuple[float, float, float, bool, float]:
    """Static per-edge features: (length_m, stress, surface_quality, scenic, grade).

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

    feat = (length, stress, quality, scenic_hit, grade)
    data["_pl_feat"] = feat
    return feat


def edge_cost(data: dict, profile: WeightProfile) -> float:
    """The one scoring function. Returns a positive cost for one edge."""
    length, stress, quality, scenic_hit, grade = features(data)

    penalty = 1.0
    penalty += profile.quiet * stress * 2.0
    penalty += profile.surface * (1.0 - quality) * 1.5
    if scenic_hit:
        penalty -= profile.scenic * 0.35

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
    "quiet_scenic": WeightProfile("quiet_scenic", quiet=0.9, surface=0.5, scenic=0.9,
                                  directness=0.2),
    "fastest": WeightProfile("fastest", quiet=0.1, surface=0.3, scenic=0.0,
                             directness=0.95),
    "gravel": WeightProfile("gravel", quiet=0.8, surface=0.0, scenic=0.7,
                            directness=0.3),
}
