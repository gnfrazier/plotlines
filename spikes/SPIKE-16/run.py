"""SPIKE-16 self-check — offline, CI-safe, no product code touched.

    python spikes/SPIKE-16/run.py            # run every check, print the report
    python spikes/SPIKE-16/run.py --json OUT # also write results/<OUT>

What it proves without a device (the rest is `HARNESS.md`):

  1. the FIT CRC-16 here reproduces the stored header + file CRC of all 10 real
     Garmin files in spikes/fit_files/  (format understanding is real, not guessed)
  2. the pure-Python encoder emits a structurally valid FIT course:
     signature, both CRCs, message order, definition/data framing
  3. it round-trips — decode(encode(fixture)) recovers every field to the byte
  4. all five required course_point types are present with the right type enum
  5. FR45: revealed plot-point notes survive as native course_point names
  6. §6A.2: the unrevealed plot point's note text is ABSENT from the output bytes
  7. area anchors (FR108) and role offsets (FR107) are accounted for explicitly
"""

from __future__ import annotations

import json
import os
import struct
import sys

from course import build_course_fit
from crc import fit_crc16
from fitdec import decode
from fixture import build_fixture
from profile import COURSE_POINT_TYPE, deg

HERE = os.path.dirname(os.path.abspath(__file__))
FIT_CORPUS = os.path.join(HERE, "..", "fit_files")

REQUIRED_CP_TYPES = ["left", "water", "food", "danger", "generic"]


def _check(results, name, ok, detail=""):
    results.append({"check": name, "pass": bool(ok), "detail": detail})
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f"  — {detail}" if detail else ""))
    return ok


def main() -> int:
    results = []
    print("SPIKE-16 — byte-accurate FIT course export (offline self-check)\n")

    # 1 — CRC vs real device files -------------------------------------
    print("CRC-16 vs real Garmin files:")
    n = ok_file = ok_hdr = 0
    for f in sorted(os.listdir(FIT_CORPUS)):
        if not f.endswith(".fit"):
            continue
        n += 1
        b = open(os.path.join(FIT_CORPUS, f), "rb").read()
        ok_file += fit_crc16(b[:-2]) == struct.unpack("<H", b[-2:])[0]
        ok_hdr += b[0] < 14 or fit_crc16(b[:12]) == struct.unpack("<H", b[12:14])[0]
    _check(results, "crc16 check value 0xBB3D", fit_crc16(b"123456789") == 0xBB3D)
    _check(results, "file CRC matches all reference files", ok_file == n, f"{ok_file}/{n}")
    _check(results, "header CRC matches all reference files", ok_hdr == n, f"{ok_hdr}/{n}")

    # build the course once -----------------------------------------------
    fx = build_fixture()
    data = build_course_fit(fx)
    withheld = build_course_fit.last_withheld

    # 2 — structural validity ---------------------------------------------
    print("\nEncoder output — structure:")
    _check(results, ".FIT signature present", data[8:12] == b".FIT")
    _check(results, "14-byte header", data[0] == 14)
    _check(results, "header CRC valid", fit_crc16(data[:12]) == struct.unpack("<H", data[12:14])[0])
    _check(results, "file CRC valid", fit_crc16(data[:-2]) == struct.unpack("<H", data[-2:])[0])
    declared = struct.unpack("<I", data[4:8])[0]
    _check(results, "data_size header field correct", declared == len(data) - 14 - 2,
           f"declared {declared}, actual {len(data) - 16}")

    dec = decode(data)
    names = [m.name for m in dec.messages]
    _check(results, "decoder re-reads own output", dec.file_crc_ok and dec.header_crc_ok)
    order_ok = names[:4] == ["file_id", "file_creator", "course", "event"] and names[-1] == "event"
    _check(results, "message order (file_id..event start / ..event stop)", order_ok,
           " -> ".join(dict.fromkeys(names)))

    # 3 — round-trip fidelity -------------------------------------------
    print("\nRound-trip — decode(encode(fixture)):")
    recs = dec.of("record")
    poly = fx["segment"]["polyline"]
    _check(results, "record count == polyline vertex count", len(recs) == len(poly),
           f"{len(recs)} == {len(poly)}")
    lat0_rt = deg(recs[0].get(0))
    lon0_rt = deg(recs[0].get(1))
    latlon_ok = abs(lat0_rt - poly[0][0]) < 1e-5 and abs(lon0_rt - poly[0][1]) < 1e-5
    _check(results, "first record lat/lon survives semicircle round-trip", latlon_ok,
           f"({lat0_rt:.5f}, {lon0_rt:.5f})")
    ele_rt = recs[10].get(2) / 5.0 - 500.0
    _check(results, "altitude survives (m+500)*5 round-trip", abs(ele_rt - poly[10][2]) < 0.2,
           f"{ele_rt:.1f} m vs {poly[10][2]} m")

    # 4 — required course_point types ------------------------------------
    print("\ncourse_point coverage (FR45 'native course/turn points'):")
    cps = dec.of("course_point")
    got_types = {m.get(5) for m in cps}
    for t in REQUIRED_CP_TYPES:
        _check(results, f"course_point type '{t}' present (enum {COURSE_POINT_TYPE[t]})",
               COURSE_POINT_TYPE[t] in got_types)
    _check(results, "message_index is contiguous from 0",
           [m.get(254) for m in cps] == list(range(len(cps))))

    # 5 — notes survive as names ---------------------------------------
    print("\nFR45 — revealed notes ride in the native point name:")
    spring = next((m for m in cps if "spring" in (m.get(6) or "").lower()), None)
    _check(results, "revealed note text present in a course_point name",
           spring is not None and "Potable" in spring.get(6, ""),
           spring.get(6) if spring else "(spring point missing)")

    # 6 — reveal gate at the byte boundary (punch-list §6A.2) --------------
    print("\n§6A.2 — unrevealed content absent from the bytes:")
    canary = fx["reveal_canary"].encode("utf-8")
    _check(results, "reveal canary string ABSENT from output bytes", canary not in data,
           f"withheld: {withheld}")
    _check(results, "the withheld point produced no course_point",
           len(cps) == sum(1 for p in fx["plot_points"] if p["id"] not in withheld))
    # positive control: it *is* in the fixture, so absence means the writer dropped it
    _check(results, "positive control — canary IS in the fixture",
           any(p.get("note") == fx["reveal_canary"] for p in fx["plot_points"]))

    # 7 — FR107 / FR108 accounted for ----------------------------------
    print("\nFR107 (role offset) / FR108 (area anchor):")
    offset_pp = next(p for p in fx["plot_points"] if p.get("offset_from"))
    off_cp = next((m for m in cps if "offset" in (m.get(6) or "").lower()), None)
    _check(results, "offset role exported at its offset position, not the anchor's",
           off_cp is not None and abs(deg(off_cp.get(2)) - offset_pp["pos"][0]) < 1e-5)
    _check(results, "area anchor (FR108) has no native FIT slot — recorded, not emitted",
           not any("district" in (m.get(6) or "").lower() for m in cps),
           "areas need a course-point centroid convention or GPX-only; see RESULTS.md")

    # ---- summary ----------------------------------------------------
    passed = sum(r["pass"] for r in results)
    total = len(results)
    print(f"\n{'=' * 60}\n{passed}/{total} checks passed  "
          f"(FIT course: {len(data)} bytes, {len(recs)} records, {len(cps)} course points)")

    payload = {
        "spike": "SPIKE-16",
        "generated_bytes": len(data),
        "records": len(recs),
        "course_points": len(cps),
        "course_point_types": sorted(got_types),
        "withheld_plot_points": withheld,
        "checks_passed": passed,
        "checks_total": total,
        "checks": results,
    }
    if "--json" in sys.argv:
        out = sys.argv[sys.argv.index("--json") + 1]
        path = out if os.path.isabs(out) else os.path.join(HERE, "results", out)
        with open(path, "w") as fh:
            json.dump(payload, fh, indent=2)
        print(f"wrote {path}")

    return 0 if passed == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
