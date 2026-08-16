"""SPIKE-20 — the trip payload schema, implemented three times over one fixture trip.

    .venv/bin/python spikes/SPIKE-20/run.py [--regions boulder,davis,viroqua]

What this measures, in the order it measures it:

  1. **Does one document describe what the core produces?** A real four-day
     multimodal trip is solved on the SPIKE-01/02/03 shared graphs, returned by
     `compose_day`/`split_trip` as plain data, and validated against
     `docs/schemas/trip_payload.schema.json`.
  2. **Does it survive the client?** The same JSON is handed to a Dart process that
     deserializes it into ARCH §9.1's domain classes, writes it to a drift
     `trip.payload` column, reads it back, and re-serializes — with a reader that
     throws on any field it does not consume, so "no loss" is proven rather than
     assumed.
  3. **Does an Author edit stay an Author edit?** Add a via-node, reword a node note,
     change one surface weight — then diff the result against the original at every
     field. Anything that moved and should not have is a silent coercion.
  4. **What breaks it?** Four probes for the specific ways a Python→JSON→Dart round
     trip goes subtly wrong: an int where a float was meant, an explicit null, an
     unknown key, and a non-finite float.

Exits non-zero if any self-check fails, so this works as a CI gate.
"""

from __future__ import annotations

import argparse
import gzip
import json
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path

SPIKE = Path(__file__).resolve().parent
SPIKES = SPIKE.parent
ROOT = SPIKES.parent
sys.path.insert(0, str(SPIKES / "shared"))
sys.path.insert(0, str(SPIKE))

import jsonschema  # noqa: E402

from plotlines_core.trips.payload import dumps  # noqa: E402

from fr_map import MAPPING, summary as fr_summary  # noqa: E402

# `build_fixture` and `harness` pull in osmnx, rasterio and the graph fixtures. They are
# imported inside `main()` rather than here so `--check-committed` — the CI-shaped mode
# that validates the committed payloads against the committed schema — needs nothing but
# `jsonschema` and this repo.

SCHEMA_PATH = ROOT / "docs" / "schemas" / "trip_payload.schema.json"
RESULTS = SPIKE / "results"
FIXTURES_OUT = RESULTS / "fixtures"
DART_DIR = SPIKE / "dart"
DART_OUT = RESULTS / "dart"

#: The three edits the Dart side applies, as patterns over JSON-pointer paths. Any
#: difference NOT matching one of these is a silent change, which is the failure this
#: spike exists to detect.
EXPECTED_EDIT_PATTERNS = [
    (r"^/days/\d+/segments/\d+/via/\d+$", "via-node added (A9 → A9a boundary)"),
    (r"^/days/\d+/segments/\d+/nodes/\d+/note$", "node note reworded (E1)"),
    (r"^/days/\d+/segments/\d+/weights/surface/gravel$", "surface weight changed (FR4)"),
    (r"^/days/\d+/segments/\d+/solve/stale$", "derived geometry marked stale"),
]


# --------------------------------------------------------------------- diffing

def diff(left, right, path: str = "") -> list[dict]:
    """Field-level difference between two decoded payloads.

    Type-aware on purpose: `4` and `4.0` compare equal in Python and are *not* the
    same JSON, and a producer that retypes a distance is exactly the silent coercion
    this spike is hunting.
    """
    out: list[dict] = []
    if type(left) is not type(right) and not (
            isinstance(left, bool) or isinstance(right, bool)):
        if isinstance(left, (int, float)) and isinstance(right, (int, float)):
            out.append({"path": path or "/", "kind": "retyped",
                        "left": f"{type(left).__name__}:{left}",
                        "right": f"{type(right).__name__}:{right}"})
            return out
        out.append({"path": path or "/", "kind": "type_changed",
                    "left": type(left).__name__, "right": type(right).__name__})
        return out

    if isinstance(left, dict):
        for key in sorted(set(left) | set(right)):
            child = f"{path}/{key}"
            if key not in right:
                out.append({"path": child, "kind": "removed", "left": _brief(left[key])})
            elif key not in left:
                out.append({"path": child, "kind": "added", "right": _brief(right[key])})
            else:
                out.extend(diff(left[key], right[key], child))
        return out

    if isinstance(left, list):
        for index in range(max(len(left), len(right))):
            child = f"{path}/{index}"
            if index >= len(right):
                out.append({"path": child, "kind": "removed", "left": _brief(left[index])})
            elif index >= len(left):
                out.append({"path": child, "kind": "added", "right": _brief(right[index])})
            else:
                out.extend(diff(left[index], right[index], child))
        return out

    if left != right:
        out.append({"path": path or "/", "kind": "changed",
                    "left": _brief(left), "right": _brief(right)})
    return out


def _brief(value):
    text = json.dumps(value, ensure_ascii=False, default=str)
    return text if len(text) <= 120 else text[:117] + "..."


def canonical(payload) -> str:
    """One text form for comparing two payloads regardless of key order."""
    return json.dumps(payload, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False)


def shuffle_keys(value, seed: int = 0):
    """Re-order every object's keys, deterministically.

    Postgres JSONB does not preserve key order (ARCH §10.1), and neither does any
    reasonable serializer. If a single reader depends on order, this finds it here
    instead of on the day the hosted tier lands.
    """
    if isinstance(value, dict):
        keys = sorted(value, key=lambda k: ((hash(k) + seed) % 997, k))
        return {k: shuffle_keys(value[k], seed + 1) for k in reversed(keys)}
    if isinstance(value, list):
        return [shuffle_keys(v, seed + 1) for v in value]
    return value


def count_vertices(payload: dict) -> int:
    total = 0
    for day in payload.get("days", []):
        for segment in day.get("segments", []):
            geometry = segment.get("geometry")
            if geometry:
                total += len(geometry["coordinates"])
            for alternate in segment.get("alternates", []):
                total += len(alternate["geometry"]["coordinates"])
    return total


def count_nodes(payload: dict) -> int:
    total = 0
    for day in payload.get("days", []):
        total += len(day.get("nodes", []))
        for segment in day.get("segments", []):
            total += len(segment.get("nodes", []))
        for transition in day.get("transitions", []):
            total += 1 if transition.get("node") else 0
    return total


# ------------------------------------------------------------------- schema use

def load_validator() -> jsonschema.protocols.Validator:
    schema = json.loads(SCHEMA_PATH.read_text())
    cls = jsonschema.validators.validator_for(schema)
    cls.check_schema(schema)
    return cls(schema)


def validation_errors(validator, payload: dict) -> list[str]:
    return [f"{'/'.join(str(p) for p in error.absolute_path) or '/'}: {error.message}"
            for error in validator.iter_errors(payload)]


def resolve_pointer(document, pointer: str):
    node = document
    for token in pointer.lstrip("/").split("/"):
        token = token.replace("~1", "/").replace("~0", "~")
        node = node[token]
    return node


# ---------------------------------------------------------------------- the run

def run_dart(input_path: Path, out_dir: Path) -> dict:
    """Hand the payload to the Dart client half. Returns its report."""
    out_dir.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    proc = subprocess.run(
        ["dart", "run", "bin/roundtrip.dart",
         "--input", str(input_path), "--outdir", str(out_dir)],
        cwd=DART_DIR, capture_output=True, text=True,
    )
    wall_ms = (time.perf_counter() - started) * 1000.0
    stem = input_path.stem
    report_path = out_dir / f"{stem}.dart_report.json"
    if proc.returncode != 0 or not report_path.exists():
        return {"ok": False, "returncode": proc.returncode,
                "stdout": proc.stdout[-2000:], "stderr": proc.stderr[-2000:],
                "wall_ms": round(wall_ms, 1)}
    report = json.loads(report_path.read_text())
    report["ok"] = True
    report["wall_ms"] = round(wall_ms, 1)
    return report


def region_pass(validator, bench, key: str) -> dict:
    """Build, validate and round-trip one region's fixture trip."""
    from build_fixture import build_trip  # noqa: PLC0415 — see the import note

    started = time.perf_counter()
    trip = build_trip(bench, key)
    build_ms = (time.perf_counter() - started) * 1000.0

    payload = trip.to_dict()
    text = dumps(payload, indent=None)

    FIXTURES_OUT.mkdir(parents=True, exist_ok=True)
    fixture_path = FIXTURES_OUT / f"{key}_trip.json"
    fixture_path.write_text(text + "\n")

    result = {
        "region": key,
        "build_ms": round(build_ms, 1),
        "bytes": len(text.encode()),
        "gzip_bytes": len(gzip.compress(text.encode())),
        "days": len(payload["days"]),
        "segments": sum(len(d.get("segments", [])) for d in payload["days"]),
        "geometry_vertices": count_vertices(payload),
        "curated_nodes": count_nodes(payload),
        "schema_errors": validation_errors(validator, payload),
        "failures": [],
    }
    if result["schema_errors"]:
        result["failures"].append(
            f"{key}: core output failed schema validation "
            f"({len(result['schema_errors'])} error(s))")

    # --- the Dart leg -----------------------------------------------------
    dart = run_dart(fixture_path, DART_OUT)
    result["dart"] = dart
    if not dart.get("ok"):
        result["failures"].append(f"{key}: dart round-trip failed")
        return result

    reserialized = json.loads(Path(dart["reserialized_path"]).read_text())
    edited = json.loads(Path(dart["edited_path"]).read_text())

    # 1. nothing may change on the way out and back.
    loss = diff(payload, reserialized)
    result["roundtrip_diff"] = loss
    result["roundtrip_lossless"] = not loss
    result["canonical_identical"] = canonical(payload) == canonical(reserialized)
    if loss:
        result["failures"].append(
            f"{key}: {len(loss)} field(s) changed in core → drift → Dart → JSON")

    # 2. the Dart re-serialization must itself validate.
    result["dart_schema_errors"] = validation_errors(validator, reserialized)
    if result["dart_schema_errors"]:
        result["failures"].append(f"{key}: Dart's re-serialization failed the schema")

    # 3. an Author edit must move exactly what it claims to move.
    edit_diff = diff(payload, edited)
    classified, unexpected = [], []
    for entry in edit_diff:
        for pattern, label in EXPECTED_EDIT_PATTERNS:
            if re.match(pattern, entry["path"]):
                classified.append({**entry, "expected": label})
                break
        else:
            unexpected.append(entry)
    result["edit_diff"] = classified
    result["edit_unexpected"] = unexpected
    result["edit_schema_errors"] = validation_errors(validator, edited)
    if unexpected:
        result["failures"].append(
            f"{key}: {len(unexpected)} unexpected change(s) from an Author edit")
    if len(classified) != len(EXPECTED_EDIT_PATTERNS):
        result["failures"].append(
            f"{key}: expected {len(EXPECTED_EDIT_PATTERNS)} edits, saw "
            f"{len(classified)}")
    if result["edit_schema_errors"]:
        result["failures"].append(f"{key}: the edited payload failed the schema")

    return result


def probes(validator, payload: dict) -> dict:
    """The four coercion probes, from the producer's side."""
    out: dict = {}

    # (a) key order must carry no meaning — the JSONB rule (ARCH §10.1).
    shuffled = shuffle_keys(payload)
    shuffled_path = FIXTURES_OUT / "probe_shuffled.json"
    shuffled_path.write_text(json.dumps(shuffled, ensure_ascii=False) + "\n")
    dart = run_dart(shuffled_path, DART_OUT)
    same = False
    if dart.get("ok"):
        back = json.loads(Path(dart["reserialized_path"]).read_text())
        same = canonical(back) == canonical(payload)
    out["key_order"] = {
        "schema_errors": validation_errors(validator, shuffled),
        "dart_ok": dart.get("ok", False),
        "identical_after_roundtrip": same,
        "verdict": ("key order carries nothing" if same
                    else "a reader depends on key order"),
    }

    # (b) an explicit null where the rule says omit.
    nulled = json.loads(json.dumps(payload))
    nulled["days"][0]["title"] = None
    out["explicit_null"] = {
        "schema_errors": validation_errors(validator, nulled)[:3],
        "rejected_by_schema": bool(validation_errors(validator, nulled)),
    }

    # (c) an unknown key from a newer producer.
    extra = json.loads(json.dumps(payload))
    extra["days"][0]["segments"][0]["unexpected_field"] = "from a newer producer"
    out["unknown_key"] = {
        "schema_errors": validation_errors(validator, extra)[:3],
        "rejected_by_schema": bool(validation_errors(validator, extra)),
    }

    # (d) an int where a float was meant — the `round(x)` vs `round(x, 1)` defect.
    retyped = json.loads(json.dumps(payload))
    target = retyped["days"][0]["segments"][0]["metrics"]
    before = target["distance_m"]
    target["distance_m"] = int(before)
    errors = validation_errors(validator, retyped)
    out["int_where_float"] = {
        "before": before,
        "after": int(before),
        "rejected_by_schema": bool(errors),
        "schema_errors": errors[:3],
        "note": "JSON Schema's `number` accepts an integer, so the schema cannot "
                "catch this. Only the reader can — which is why the Dart layer reads "
                "every fractional field through `num`.",
    }

    # (e) a non-finite float, as an unguarded elevation void would produce.
    try:
        dumps({"ascent_m": float("nan")})
        refused = False
        error = None
    except ValueError as exc:
        refused, error = True, str(exc)
    out["non_finite"] = {
        "refused_by_producer": refused,
        "error": error,
        "note": "json.dumps writes bare NaN by default, which is not JSON and which "
                "Dart's jsonDecode rejects — a file this codebase could write and "
                "the client could not read.",
    }
    return out


def sizing(payload: dict) -> dict:
    """What the payload costs, and what it would cost at real trip scale.

    The fixture regions are small bboxes, so a fixture day is a few kilometres where
    a real one is sixty. Rather than pretend otherwise, this measures the marginal
    cost of a geometry vertex on real data and projects from it — SPIKE-14's own
    figures (6,864 vertices on a rendered route, 41k on a ~660 km worst case) are the
    scale being projected to, so the two spikes' numbers are comparable.
    """
    full = dumps(payload).encode()
    vertices = count_vertices(payload)

    stripped = json.loads(json.dumps(payload))
    for day in stripped.get("days", []):
        for segment in day.get("segments", []):
            if segment.get("geometry"):
                segment["geometry"]["coordinates"] = []
            for alternate in segment.get("alternates", []):
                alternate["geometry"]["coordinates"] = []
    without = dumps(stripped).encode()
    per_vertex = (len(full) - len(without)) / vertices if vertices else 0.0

    # What per-vertex elevation samples would add, if the schema stored them.
    sampled = json.loads(json.dumps(payload))
    added = 0
    for day in sampled.get("days", []):
        for segment in day.get("segments", []):
            geometry = segment.get("geometry")
            if not geometry:
                continue
            count = len(geometry["coordinates"])
            segment.setdefault("elevation", {})["samples"] = [
                1234.5 for _ in range(count)]
            added += count
    with_samples = dumps(sampled).encode()

    def projected(vertex_count: int) -> int:
        return int(len(without) + per_vertex * vertex_count)

    return {
        "bytes": len(full),
        "gzip_bytes": len(gzip.compress(full)),
        "bytes_without_geometry": len(without),
        "geometry_share": round(1 - len(without) / len(full), 3),
        "geometry_vertices": vertices,
        "bytes_per_vertex": round(per_vertex, 1),
        "bytes_with_elevation_samples": len(with_samples),
        "elevation_sample_cost_bytes": len(with_samples) - len(full),
        "projected": {
            "one_spike14_route_6864_vertices": projected(6864),
            "seven_days_at_6864_vertices": projected(7 * 6864),
            "spike14_worst_case_41k_vertices": projected(41_000),
        },
    }


def scale_payload(payload: dict, *, days: int = 7, densify: int = 4) -> dict:
    """A real payload inflated to real trip scale.

    The shared fixture regions are small bboxes, so a fixture day is a few kilometres
    where a real one is sixty. Rather than measure a toy and project, this clones the
    fixture's days out to a week and densifies the geometry — the structure stays
    exactly what the core produced, and only the vertex count moves. Identifiers are
    remapped consistently so internal references (transition → segment, hazard →
    node, cue → segment) still resolve; duplicating them would make the test cheaper
    than the thing it stands in for.
    """
    text = json.dumps(payload)
    uuid_pattern = re.compile(
        r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

    def reid(fragment: dict) -> dict:
        blob = json.dumps(fragment)
        for old in sorted(set(uuid_pattern.findall(blob))):
            blob = blob.replace(old, str(uuid.uuid4()))
        return json.loads(blob)

    source = json.loads(text)
    grown: list[dict] = []
    index = 1
    while len(grown) < days:
        for day in source["days"]:
            if len(grown) >= days:
                break
            clone = reid(day)
            clone["index"] = index
            clone.pop("roles", None)
            index += 1
            grown.append(clone)
    grown[0]["roles"] = ["start"]
    grown[-1]["roles"] = ["end"]

    def densified(coords: list[list[float]]) -> list[list[float]]:
        out = coords
        for _ in range(densify):
            grown_coords = [out[0]]
            for previous, current in zip(out, out[1:]):
                grown_coords.append([
                    round((previous[0] + current[0]) / 2, 7),
                    round((previous[1] + current[1]) / 2, 7),
                ])
                grown_coords.append(current)
            out = grown_coords
        return out

    for day in grown:
        for segment in day.get("segments", []):
            if segment.get("geometry"):
                segment["geometry"]["coordinates"] = densified(
                    segment["geometry"]["coordinates"])
            for alternate in segment.get("alternates", []):
                alternate["geometry"]["coordinates"] = densified(
                    alternate["geometry"]["coordinates"])

    scaled = json.loads(text)
    scaled["days"] = grown
    scaled["duration"] = {"day_count": len(grown)}
    return scaled


def scale_test(validator, payload: dict) -> dict:
    """Measure the client cost at real trip scale rather than projecting it."""
    scaled = scale_payload(payload)
    text = dumps(scaled)
    path = FIXTURES_OUT / "scaled_week.json"
    path.write_text(text + "\n")

    errors = validation_errors(validator, scaled)
    dart = run_dart(path, DART_OUT)
    result = {
        "days": len(scaled["days"]),
        "bytes": len(text.encode()),
        "gzip_bytes": len(gzip.compress(text.encode())),
        "geometry_vertices": count_vertices(scaled),
        "schema_errors": errors,
        "dart": dart,
    }
    if dart.get("ok"):
        back = json.loads(Path(dart["reserialized_path"]).read_text())
        result["roundtrip_lossless"] = not diff(scaled, back)
    return result


def check_fr_map(validator) -> dict:
    schema = json.loads(SCHEMA_PATH.read_text())
    unresolved = []
    for row in MAPPING:
        pointer = row.get("pointer")
        if not pointer:
            continue
        try:
            resolve_pointer(schema, pointer)
        except (KeyError, TypeError):
            unresolved.append({"fr": row["fr"], "pointer": pointer})
    return {**fr_summary(), "unresolved_pointers": unresolved,
            "rows": MAPPING}


def run(bench, regions: list[str]) -> dict:
    validator = load_validator()
    payload_out: dict = {
        "spike": "SPIKE-20",
        "question": "One schema for plotlines-core's output, drift's blob, and "
                    "Flutter's domain classes — with a real trip round-tripped "
                    "through all three.",
        "schema": str(SCHEMA_PATH.relative_to(ROOT)),
        "environment": bench.environment(),
        "regions": [],
    }

    for key in regions:
        payload_out["regions"].append(region_pass(validator, bench, key))

    # Probes run once, on the largest payload built.
    biggest = max(payload_out["regions"], key=lambda r: r["bytes"])
    fixture = json.loads((FIXTURES_OUT / f"{biggest['region']}_trip.json").read_text())
    payload_out["probe_region"] = biggest["region"]
    payload_out["sizing"] = sizing(fixture)
    payload_out["scale_test"] = scale_test(validator, fixture)
    payload_out["probes"] = probes(validator, fixture)
    payload_out["fr_coverage"] = check_fr_map(validator)

    failures = [f for region in payload_out["regions"] for f in region["failures"]]
    if payload_out["fr_coverage"]["unresolved_pointers"]:
        failures.append("FR map points at schema fields that do not exist")
    if not payload_out["probes"]["key_order"]["identical_after_roundtrip"]:
        failures.append("payload survived a key-order shuffle unequally")
    if not payload_out["probes"]["explicit_null"]["rejected_by_schema"]:
        failures.append("schema accepted an explicit null")
    if not payload_out["probes"]["unknown_key"]["rejected_by_schema"]:
        failures.append("schema accepted an unknown key")
    if not payload_out["probes"]["non_finite"]["refused_by_producer"]:
        failures.append("producer emitted a non-finite float")
    scale = payload_out["scale_test"]
    if scale["schema_errors"]:
        failures.append("the week-scale payload failed the schema")
    if not scale.get("roundtrip_lossless"):
        failures.append("the week-scale payload did not round-trip losslessly")
    payload_out["failures"] = failures
    payload_out["passed"] = not failures

    # The scale test's SQLite file is 25 MB of regenerable evidence; the numbers it
    # produced are in this document.
    for database in DART_OUT.glob("*.sqlite"):
        database.unlink()
    return payload_out


def check_committed() -> int:
    """Validate what is in the repo, without building or solving anything.

    The CI-shaped mode: every committed fixture payload must still validate against the
    committed schema, and every FR-map pointer must still resolve. Needs `jsonschema`
    and nothing else — no graphs, no Dart, no network. It cannot prove the round trip
    (that is the full run), but it does catch the failure that actually happens between
    runs: the schema and the payloads drifting apart in a later edit.
    """
    validator = load_validator()
    failures = []
    fixtures = sorted(FIXTURES_OUT.glob("*_trip.json"))
    if not fixtures:
        print(f"no committed fixtures under {FIXTURES_OUT}")
        return 1
    for fixture in fixtures:
        errors = validation_errors(validator, json.loads(fixture.read_text()))
        print(f"{fixture.name:<24} {'OK' if not errors else f'{len(errors)} error(s)'}")
        failures.extend(f"{fixture.name}: {error}" for error in errors)

    coverage = check_fr_map(validator)
    print(f"FR coverage: {coverage['by_status']}")
    for row in coverage["unresolved_pointers"]:
        failures.append(f"{row['fr']}: pointer {row['pointer']} does not resolve")

    for failure in failures:
        print(f"  - {failure}")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--regions", default="boulder,davis,viroqua")
    parser.add_argument("--check-committed", action="store_true",
                        help="validate the committed payloads and FR map only")
    args = parser.parse_args()
    if args.check_committed:
        return check_committed()

    from harness import Bench  # noqa: PLC0415 — see the import note at the top

    regions = [r.strip() for r in args.regions.split(",") if r.strip()]

    with Bench.setup(regions) as bench:
        results = run(bench, regions)

    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / "results.json").write_text(json.dumps(results, indent=2) + "\n")

    for region in results["regions"]:
        print(f"{region['region']:<9} {region['bytes'] / 1024:8.1f} KiB  "
              f"{region['geometry_vertices']:>6} vertices  "
              f"lossless={region.get('roundtrip_lossless')}  "
              f"edits={len(region.get('edit_diff', []))}  "
              f"unexpected={len(region.get('edit_unexpected', []))}")
    print(f"FR coverage: {results['fr_coverage']['by_status']}")
    if results["failures"]:
        print("\nFAILURES:")
        for failure in results["failures"]:
            print(f"  - {failure}")
        return 1
    print("\nAll self-checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
