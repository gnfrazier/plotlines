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
("flat ↔ maximal climbing") with a neutral middle.
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

# Traffic stress by highway class, 0.0 (calm) .. 1.0 (hostile).
_TRAFFIC_STRESS: dict[str, float] = {
    "cycleway": 0.0, "path": 0.05, "track": 0.1, "footway": 0.15,
    "living_street": 0.2, "residential": 0.3, "unclassified": 0.4,
    "tertiary": 0.55, "secondary": 0.75, "primary": 0.9, "trunk": 1.0,
}


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


def _first(value):
    """OSM tags arrive as str or list[str] depending on way merging."""
    return value[0] if isinstance(value, list) and value else value


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
    stress = _TRAFFIC_STRESS.get(highway, 0.5)

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
