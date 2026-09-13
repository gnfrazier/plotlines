"""SPIKE-I leg 5 (B8) — Q6's arithmetic.

§12 closes with the one thing it could not close:

    "**One measurement still owed against Q6.** §11.5's premise — 'an active
    Author re-pulls a regional extract for each new trip in a new region' — is
    arithmetic once SPIKE-I reports extract sizes (§7.1(4)) and we guess at
    trips-per-Author-per-region. Q1-C makes it much smaller; it does not make it
    unnecessary to check."

So this is arithmetic over two measured numbers and one honest guess, and the
guess is reported as a guess. The output that matters is the **ratio**, not the
absolute: a ratio survives being wrong about the population, and being wrong
about the population is the most likely thing about any figure here.

The two columns are the two worlds §12 chose between:

    Q1-A/B   the client downloads a region extract per trip in a new region.
             This is what the review's §11.5 cost curve describes and what
             Q1-D's fallback would partially reinstate.
    Q1-C     the client downloads one bbox clip per trip. Adopted.

Nothing here models CDN caching or object-storage economics. Q6 landed on
**D + C** — clip server-side, remaining bulk on zero-egress storage — so the
bytes counted here are the ones that still cross a paid boundary under the
decision as adopted, which is the clip path only. The region-extract column is
the counterfactual, kept so the ratio has a denominator.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

#: Trips per Author per region. A stated guess, not a measurement — nothing in
#: the product has shipped to enough Authors to measure it. Three values rather
#: than one so the answer is a curve and a reader can find their own assumption
#: on it.
TRIPS_PER_AUTHOR_PER_REGION = (1, 3, 10)

#: Author population. Same status: a range, deliberately spanning two orders of
#: magnitude, because §11.5's actual claim is "cheap at a hundred users, a line
#: item at scale" and the question is where the crossover sits.
AUTHOR_POPULATIONS = (100, 1_000, 10_000)

#: What a byte of egress costs, for the one line that has to be in currency to
#: be legible. Origin egress from a commodity VPS/cloud is the comparison Q6-C
#: (R2/B2, zero egress) is measured against; $0.09/GB is AWS/GCP list for the
#: first tier and is the number the "line item at scale" worry is priced on.
#: Q6 adopted C, so this column is what the decision *avoids*, not what it costs.
USD_PER_GB_ORIGIN_EGRESS = 0.09


@dataclass(frozen=True)
class RegionFigures:
    """One region's two measured sizes."""

    region: str
    extract_bytes: int
    #: The bbox clip for a realistic trip in that region, complete_ways.
    clip_bytes: int
    bbox_km2: float

    @property
    def ratio(self) -> float:
        """How many times smaller a clip is than its region extract. This is the
        number Q1-C bought, and it is the only figure here that is entirely
        measured."""
        return self.extract_bytes / self.clip_bytes if self.clip_bytes else 0.0


def arithmetic(regions: list[RegionFigures]) -> dict[str, Any]:
    """The table §12-Q6 is owed."""
    if not regions:
        return {"error": "no regions measured"}

    mean_extract = sum(r.extract_bytes for r in regions) / len(regions)
    mean_clip = sum(r.clip_bytes for r in regions) / len(regions)

    rows = []
    for pop in AUTHOR_POPULATIONS:
        for trips in TRIPS_PER_AUTHOR_PER_REGION:
            pulls = pop * trips
            extract_gb = pulls * mean_extract / 1e9
            clip_gb = pulls * mean_clip / 1e9
            rows.append({
                "authors": pop,
                "trips_per_author_per_region": trips,
                "pulls": pulls,
                "region_extract_gb": round(extract_gb, 2),
                "bbox_clip_gb": round(clip_gb, 4),
                "region_extract_usd": round(extract_gb * USD_PER_GB_ORIGIN_EGRESS, 2),
                "bbox_clip_usd": round(clip_gb * USD_PER_GB_ORIGIN_EGRESS, 4),
                "ratio": round(extract_gb / clip_gb, 1) if clip_gb else None,
            })

    return {
        "per_region": [
            {
                "region": r.region,
                "extract_mb": round(r.extract_bytes / 1e6, 1),
                "clip_mb": round(r.clip_bytes / 1e6, 3),
                "bbox_km2": round(r.bbox_km2, 1),
                "ratio": round(r.ratio, 1),
            }
            for r in regions
        ],
        "mean_extract_mb": round(mean_extract / 1e6, 1),
        "mean_clip_mb": round(mean_clip / 1e6, 3),
        "assumptions": {
            "trips_per_author_per_region": list(TRIPS_PER_AUTHOR_PER_REGION),
            "author_populations": list(AUTHOR_POPULATIONS),
            "usd_per_gb_origin_egress": USD_PER_GB_ORIGIN_EGRESS,
            "stated_as": "guess — nothing shipped measures Author behaviour yet",
        },
        "rows": rows,
    }
