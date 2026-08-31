"""Write the fixture course to a real .fit file for the HARNESS.md device tests.

    python spikes/SPIKE-16/emit_fit.py            -> results/spike16_course.fit
    python spikes/SPIKE-16/emit_fit.py --dump     -> also print the decoded messages

The emitted file is the Python-in-core arm's candidate. The Dart-FFI arm
produces its own file from the same fixture JSON (results/fixture.json) — see
HARNESS.md.
"""

from __future__ import annotations

import json
import os
import sys

from course import build_course_fit
from fitdec import decode
from fixture import build_fixture
from profile import deg

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_FIT = os.path.join(HERE, "results", "spike16_course.fit")
OUT_FIXTURE = os.path.join(HERE, "results", "fixture.json")


def _fixture_json(fx: dict) -> dict:
    """A flat, language-neutral view of the fixture for the Dart-FFI arm."""
    seg = fx["segment"]
    return {
        "trip": fx["trip"],
        "start_unix": seg["start_unix"],
        "nominal_speed_mps": seg["nominal_speed_mps"],
        "polyline": [{"lat": a, "lon": b, "ele_m": c} for a, b, c in seg["polyline"]],
        "plot_points": [
            {
                "id": p["id"], "role": p["role"], "reveal": p["reveal"],
                "hazard": bool(p.get("hazard")), "cp_type": p["cp_type"],
                "name": p["name"], "note": p["note"],
                "lat": p["pos"][0], "lon": p["pos"][1], "distance_m": p["pos"][3],
                "offset_from": p.get("offset_from"),
            }
            for p in fx["plot_points"]
        ],
        "area_anchors": [
            {"id": a["id"], "name": a["name"],
             "polygon": [{"lat": x, "lon": y} for x, y in a["polygon"]]}
            for a in fx["area_anchors"]
        ],
        "reveal_canary": fx["reveal_canary"],
        "note": "The reveal_canary MUST NOT appear in any exported byte stream.",
    }


def main() -> int:
    fx = build_fixture()
    data = build_course_fit(fx)
    os.makedirs(os.path.dirname(OUT_FIT), exist_ok=True)
    with open(OUT_FIT, "wb") as fh:
        fh.write(data)
    with open(OUT_FIXTURE, "w") as fh:
        json.dump(_fixture_json(fx), fh, indent=2)
    print(f"wrote {OUT_FIT}  ({len(data)} bytes)")
    print(f"wrote {OUT_FIXTURE}")

    if "--dump" in sys.argv:
        dec = decode(data)
        print(f"\nheader: proto={dec.protocol_version:#x} profile={dec.profile_version} "
              f"data_size={dec.data_size} hdrCRC={dec.header_crc_ok} fileCRC={dec.file_crc_ok}")
        for m in dec.messages:
            if m.name == "record":
                continue
            pretty = dict(m.fields)
            if m.name == "course_point":
                pretty["_lat"] = round(deg(m.get(2)), 6)
                pretty["_lon"] = round(deg(m.get(3)), 6)
            print(f"  {m.name}: {pretty}")
        print(f"  (+ {len(dec.of('record'))} record messages)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
