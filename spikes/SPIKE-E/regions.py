"""SPIKE-E's approaches, signal set, and bands — **pre-registered**.

Everything in this file was fixed before a route was solved or a tag counted, the
discipline SPIKE-C used for its coverage bands and SPIKE-G for its cost coefficients.
Changing a value here after a run is allowed only with a written reason, because these
are the knobs a spike can otherwise turn until it likes its own answer.

**The approaches.** The issue asks for "the shared fixture regions plus at least one
genuinely remote approach". Two of the four are inside `spikes/shared/regions.py`'s
own bboxes, unmodified — a trailhead and a put-in that happen to sit in the cycling
fixtures SPIKE-01/02/03 measured, so this spike composes with those the way SPIKE-D
composed with SPIKE-B. The other two are genuinely remote: a Wind River trailhead at
the end of ~50 km of dirt, and a Middle Fork put-in reached by a numbered forest
road. Remote is not decoration here — the whole FR29 sentence is about the last mile,
and a last mile inside a city is not the case the requirement is worried about.

**Every destination is a real OSM element, cited by id.** They were resolved against
live Overpass before this file was written (see `destination_osm`), not recalled — a
seed coordinate a few hundred metres off would show up as a snapping artefact and get
read as a routing finding.
"""

from __future__ import annotations

import importlib.util
import sys
from dataclasses import dataclass
from pathlib import Path

SPIKE = Path(__file__).resolve().parent
RAW = SPIKE / "raw"
RESULTS = SPIKE / "results"


def _shared_regions() -> dict:
    """The two shared-fixture bboxes come from the fixture definitions themselves
    rather than being copied — if SPIKE-01/02/03's regions move, these move with
    them. Loaded by path because that module is also called `regions`."""
    path = SPIKE.parent / "shared" / "regions.py"
    spec = importlib.util.spec_from_file_location("spike_shared_regions", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # @dataclass resolves its own module by name
    spec.loader.exec_module(module)
    return module.REGIONS


SHARED_REGIONS = _shared_regions()


@dataclass(frozen=True)
class Approach:
    """One drive to a trailhead or put-in: where a Character starts, where the
    walking or paddling starts, and the box that has to contain both."""

    key: str
    name: str
    character: str
    #: (west, south, east, north) — osmnx 2.x order.
    bbox: tuple[float, float, float, float]
    #: (lat, lon) of the paved-network starting point: a town, a highway junction.
    origin: tuple[float, float]
    origin_label: str
    #: (lat, lon) of the trailhead / put-in.
    destination: tuple[float, float]
    destination_label: str
    #: The OSM element the destination coordinate came from, so the seed is
    #: evidence rather than memory.
    destination_osm: str
    #: True where the bbox is a `spikes/shared` fixture region, unmodified.
    shared_fixture: bool
    #: True for an approach whose last mile is genuinely remote — no cell service,
    #: no pavement, and a long way from a tow truck.
    remote: bool


APPROACHES: dict[str, Approach] = {
    # ---------------------------------------------------------------- fixtures
    "boulder": Approach(
        key="boulder",
        name="Gregory Canyon Trailhead, Boulder CO",
        character="city trailhead — pavement to the mouth of the canyon, then not",
        bbox=SHARED_REGIONS["boulder"].bbox,
        origin=(40.0176, -105.2797),
        origin_label="Downtown Boulder (Broadway & Canyon)",
        destination=(39.99751, -105.29271),
        destination_label="Gregory Canyon Trailhead",
        # way 417243786 "Gregory Canyon Trailhead"; its access road is way
        # 17027065 "Gregory Canyon Road", tagged highway=service.
        destination_osm="way/417243786",
        shared_fixture=True,
        remote=False,
    ),
    "viroqua": Approach(
        key="viroqua",
        name="Sidie Hollow landing, Viroqua WI",
        character="Driftless coulee country — county blacktop then gravel town roads",
        bbox=SHARED_REGIONS["viroqua"].bbox,
        origin=(43.5566, -90.8879),
        origin_label="Viroqua, WI (Main & Decker)",
        destination=(43.53792, -90.95289),
        destination_label="Sidie Hollow boat landing",
        destination_osm="node/2618977896 (leisure=slipway)",
        shared_fixture=True,
        remote=False,
    ),
    # ------------------------------------------------------------------ remote
    "bigsandy": Approach(
        key="bigsandy",
        name="Big Sandy Trailhead, Bridger-Teton NF, WY",
        character="the canonical case — ~50 km of dirt to the Wind River crest",
        bbox=(-109.78, 42.54, -109.20, 42.80),
        origin=(42.7433, -109.7166),
        origin_label="Boulder, WY (US-191)",
        destination=(42.68837, -109.27079),
        destination_label="Big Sandy Trailhead",
        destination_osm="node/1042137527 (highway=trailhead)",
        shared_fixture=False,
        remote=True,
    ),
    "middlefork": Approach(
        key="middlefork",
        name="Boundary Creek put-in, Salmon-Challis NF, ID",
        character="a river put-in reached by numbered forest road — FR29's own example",
        bbox=(-115.38, 44.19, -114.88, 44.58),
        origin=(44.2166, -114.9366),
        origin_label="Stanley, ID (ID-21 / ID-75)",
        destination=(44.5295, -115.29354),
        destination_label="Boundary Creek Campground (Middle Fork put-in)",
        destination_osm="way/13983172 (NFSR 549, highway=service, surface=gravel)",
        shared_fixture=False,
        remote=True,
    ),
}


# --------------------------------------------------------------------- signals

#: FR29a's signal list, verbatim from the requirement. The value sets and what each
#: one implies about a vehicle live in `advisory.py`; this is only the list of keys
#: whose *coverage* is measured, so the coverage half cannot quietly widen to
#: whichever tag happens to be well populated.
FR29A_SIGNALS: tuple[str, ...] = (
    "surface", "smoothness", "tracktype", "4wd_only", "highway=track",
    "motor_vehicle",
)

#: Tags the *product* reads on an edge today but the shipped graph builder does not
#: download (`core/plotlines_core/graph/regions.py`'s `useful_tags_way`). Measured
#: here because punch-list §5.3 names the mapping gap as this spike's dependency and
#: the gap is not only in the markdown.
UNREQUESTED_BY_PRODUCT: tuple[str, ...] = ("4wd_only", "motor_vehicle", "motorcar", "ford")


# ----------------------------------------------------------------------- bands

#: Coverage bands, declared before the first count, and deliberately the same three
#: SPIKE-C used (`spikes/SPIKE-C/schemas.py`). Reused rather than reinvented because
#: the question has the same shape — can a surface *read* a published tag, or must it
#: *ask* the Author — and a second spike inventing a second ladder for the same
#: judgement makes the two unreadable side by side. What differs is the denominator
#: (approach roads, not the network at large) and the harm model (`analyze.py`'s
#: `degrade` section), because an advisory that fails silent is a different animal
#: from a difficulty grade that fails low.
BANDS: tuple[tuple[str, float], ...] = (
    ("read", 70.0),           # an unflagged leg carries information
    ("opportunistic", 20.0),  # flag where tagged; silence means nothing
    ("absent", 0.0),          # Author-declared only
)

#: Below this many eligible ways a cell is reported `n/a`, not `absent` — SPIKE-C's
#: rule, for its reason: an unmeasurable cell and an empty one are different findings.
MIN_ELIGIBLE_WAYS = 30

#: The harm ceiling, declared before the thinning model was written: the share of
#: genuinely-rough approaches that may come back **"no contrary signal"** — the
#: confident-clear state, not the unsurveyed one — before the feature is doing damage
#: rather than merely being thin. 10% is SPIKE-C's number for the same kind of
#: question, and the same argument carries: below the ceiling the feature is a thin
#: help, above it the feature is a lie an Author acts on.
FALSE_CLEAR_CEILING_PCT = 10.0


def band_for(pct: float, eligible: int) -> str:
    if eligible < MIN_ELIGIBLE_WAYS:
        return "n/a"
    for name, floor in BANDS:
        if pct >= floor:
            return name
    return "absent"


# ------------------------------------------------------------------ geometry

#: "The last mile" is FR29's own phrase; 5 km is the operational reading of it and is
#: reported beside the whole route, never instead of it.
LAST_MILE_M = 5_000.0

#: Radius (driving distance from the destination, along the graph) defining the
#: *approach corridor* denominator — the ways that lead to this trailhead, as opposed
#: to the ways that happen to be in the same bbox. 15 km because it is longer than
#: every last-mile in the set and shorter than every whole approach, so the corridor
#: is a real narrowing in all four regions rather than a synonym for one of the two.
CORRIDOR_M = 15_000.0
