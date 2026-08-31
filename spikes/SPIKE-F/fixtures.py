"""A small, realistic trip payload for SPIKE-F's anonymous-reader strand.

Deliberately mixes every case the anonymous view has to get right:

* a **provision** role (water) — content is always visible (PRD §1.4-1.5);
* a **narrative** role with `reveal: always_visible` — an Author chose to
  show it up front;
* a **narrative** role with `reveal: on_arrival` — the plot point that a
  web/print copy must NOT spoil (FR116);
* a **hazard** role — always visible, no Author setting can hide it
  (schema `role` `not` clause, PRD §1.5);
* passage-level `hazards[]` — the other place a hazard can live;
* `arc` stages on roles and on a segment — the "arc's shape" FR116 says a
  paper copy must still show.

Only the fields the projection reads are populated; it is not a full
`trip_payload.schema.json` document.
"""

from __future__ import annotations

# The one string the anonymous view must never emit. Kept as a module
# constant so the test can assert on it directly.
SECRET_PLOT_POINT = (
    "The dam breached in 1907 and the drowned village is still down there; "
    "on a low-water year you can see the church spire. Tell them the story "
    "only once everyone is standing on the overlook."
)

TRIP = {
    "schema_version": "2.0.0",
    "name": "The Drowned Valley",
    "bbox": [-82.75, 35.50, -81.65, 36.30],
    "days": [
        {
            "index": 1,
            "title": "Up the tailwater",
            "anchors": [
                {
                    "id": "a-spring",
                    "coord": [-82.51, 35.61],
                    "roles": [
                        {
                            "kind": "provision",
                            "reveal": "always_visible",
                            "note": "Piped spring, runs year round. Last "
                                    "reliable water for 18 km — fill here.",
                        }
                    ],
                },
                {
                    "id": "a-mill",
                    "coord": [-82.48, 35.63],
                    "roles": [
                        {
                            "kind": "narrative",
                            "reveal": "always_visible",
                            "arc": "exposition",
                            "note": "The old grist mill. Wheel's gone but the "
                                    "race is intact; this is where the valley "
                                    "road used to start.",
                        }
                    ],
                },
                {
                    "id": "a-overlook",
                    "coord": [-82.40, 35.70],
                    "roles": [
                        {
                            # THE crux plot point. Held for arrival.
                            "kind": "narrative",
                            "reveal": "on_arrival",
                            "arc": "crux",
                            "note": SECRET_PLOT_POINT,
                        },
                        {
                            # ... on the SAME anchor, a hazard role. Always
                            # visible even though it rides next to a withheld
                            # one.
                            "kind": "narrative",
                            "reveal": "always_visible",
                            "hazard": True,
                            "arc": None,
                            "note": "Overlook edge is undercut and unfenced. "
                                    "20 m drop. Keep back from the lip.",
                        },
                    ],
                },
            ],
            "segments": [
                {
                    "id": "s-1",
                    "from": "a-spring",
                    "to": "a-overlook",
                    "arc": "rising_action",
                    "hazards": [
                        {
                            "kind": "technical",
                            "note": "Two unbridged fords below the mill; "
                                    "impassable above ~40 cm gauge.",
                        }
                    ],
                }
            ],
        }
    ],
}
