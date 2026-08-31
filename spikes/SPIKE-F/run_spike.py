"""SPIKE-F orchestration — issue #175. Settles the three strands of ARCH
Q17 / risk A26 and writes `results/run_spike.json` for `results/RESULTS.md`
to cite.

    python3 spikes/SPIKE-F/run_spike.py

No virtualenv needed — this spike is a design/security/product decision and
its harness is stdlib-only (http.server, urllib, hmac). It imports no
`plotlines_core`; the anonymous-view projection is modelled here because the
reveal resolver ARCH names lives in the Flutter Data layer, not core.
"""

from __future__ import annotations

import datetime as dt
import json
from pathlib import Path

# Fixed clock so the committed results file does not churn on re-run.
_FIXED_NOW = dt.datetime(2026, 8, 30, 12, 0, 0, tzinfo=dt.timezone.utc)

import carriers
import logredact
from anonview import anonymous_view, arc_shape
from fixtures import SECRET_PLOT_POINT, TRIP

HERE = Path(__file__).resolve().parent
RESULTS = HERE / "results"


def section(t: str) -> None:
    print(f"\n=== {t} ===")


def strand1() -> dict:
    section("Strand 1 — token carrier")
    data = carriers.run_all()
    for name, v in data["carriers"].items():
        if name == "exchange":
            continue
        leak = v["token_in_request_path"] or v["token_in_query_string"] or v["token_in_referer_header"]
        print(f"  {name:9} token reaches server logs / Referer: {leak}")
    ex = data["carriers"]["exchange"]
    print(f"  exchange: token hits in access log = {ex['token_hits_in_log']} "
          f"(want 1 — the one-time exchange), cookie HttpOnly={ex['cookie_httponly']} "
          f"SameSite=Strict={ex['cookie_samesite']} cookie_is_token={ex['cookie_is_token']}")
    return data


def strand2() -> dict:
    section("Strand 2 — log retention")
    raw = {
        "ts": "2026-08-30T12:00:00+00:00",
        "method": "GET",
        "path": f"/read/{carriers.SHARE_TOKEN}",
        "query": "",
        "referer": f"https://app.example.org/read/{carriers.SHARE_TOKEN}",
        "cookie": "__Host-pl_read=deadbeefdeadbeefdeadbeef",
        "user_agent": "Mozilla/5.0 (X11; Linux x86_64) Firefox/128.0",
        "client_ip": "203.0.113.47",
        "status": 200,
        "bytes": 5123,
        "cache_status": "HIT",
    }
    red = logredact.redact_record(raw, now=_FIXED_NOW)
    print("  raw keys   :", sorted(raw))
    print("  logged keys:", sorted(red))
    print("  token in redacted record:", logredact.leaks_secret(red, carriers.SHARE_TOKEN))
    print("  client ip  :", raw["client_ip"], "->", red["client_ip"])
    print(f"  retention  : edge/CDN {logredact.EDGE_LOG_RETENTION_HOURS}h, "
          f"app {logredact.APP_LOG_RETENTION_DAYS}d")
    return {
        "raw": raw,
        "redacted": red,
        "token_leaks": logredact.leaks_secret(red, carriers.SHARE_TOKEN),
        "edge_retention_hours": logredact.EDGE_LOG_RETENTION_HOURS,
        "app_retention_days": logredact.APP_LOG_RETENTION_DAYS,
        "route_template_example": logredact.route_template(raw["path"]),
    }


def strand3() -> dict:
    section("Strand 3 — anonymous reader reveal model")
    view = anonymous_view(TRIP)
    blob = json.dumps(view)
    secret_leaks = SECRET_PLOT_POINT in blob

    roles = [r for d in view["days"] for a in d["anchors"] for r in a["roles"]]
    kinds = {}
    for r in roles:
        kinds.setdefault(r["_visibility"], 0)
        kinds[r["_visibility"]] += 1

    haz_notes_present = "undercut and unfenced" in blob and "unbridged fords" in blob
    provision_present = "Last reliable water" in blob
    shape = arc_shape(view)

    print(f"  roles by visibility : {kinds}")
    print(f"  crux plot point in output : {secret_leaks}  (want False)")
    print(f"  hazard content in output  : {haz_notes_present}  (want True)")
    print(f"  provision content in output: {provision_present}  (want True)")
    print(f"  arc shape still visible    : {shape}")

    # determinism / identity-independence
    v2 = anonymous_view(TRIP)
    deterministic = json.dumps(v2, sort_keys=True) == json.dumps(view, sort_keys=True)
    print(f"  deterministic & identity-free: {deterministic}")

    return {
        "view": view,
        "secret_plot_point_leaks": secret_leaks,
        "hazard_content_present": haz_notes_present,
        "provision_content_present": provision_present,
        "arc_shape": shape,
        "roles_by_visibility": kinds,
        "deterministic": deterministic,
        "withheld_message": view["days"][0]["anchors"][2]["roles"][0]["note"],
    }


def main() -> None:
    RESULTS.mkdir(parents=True, exist_ok=True)
    out = {
        "issue": 175,
        "spike": "SPIKE-F",
        "strand1_token_carrier": strand1(),
        "strand2_log_retention": strand2(),
        "strand3_anonymous_reveal": strand3(),
    }

    # top-line pass/fail the RESULTS.md and the issue comment cite
    s1 = out["strand1_token_carrier"]["carriers"]
    verdict = {
        "path_carrier_leaks_token": (
            s1["path"]["token_in_request_path"] and s1["path"]["token_in_referer_header"]),
        "query_carrier_leaks_token": (
            s1["query"]["token_in_query_string"] and s1["query"]["token_in_referer_header"]),
        "fragment_keeps_token_off_wire": not (
            s1["fragment"]["token_in_request_path"]
            or s1["fragment"]["token_in_query_string"]
            or s1["fragment"]["token_in_referer_header"]),
        "exchange_token_in_log_once": s1["exchange"]["token_hits_in_log"] == 1,
        "exchange_cookie_not_token": not s1["exchange"]["cookie_is_token"],
        "redacted_log_no_token": not out["strand2_log_retention"]["token_leaks"],
        "anon_view_no_spoiler": not out["strand3_anonymous_reveal"]["secret_plot_point_leaks"],
        "anon_view_keeps_hazards": out["strand3_anonymous_reveal"]["hazard_content_present"],
        "anon_view_keeps_arc_shape": len(out["strand3_anonymous_reveal"]["arc_shape"]) >= 2,
    }
    out["verdict"] = verdict

    (RESULTS / "run_spike.json").write_text(json.dumps(out, indent=2) + "\n")

    section("VERDICT")
    for k, v in verdict.items():
        print(f"  {'ok  ' if v else 'FAIL'} {k}: {v}")
    print(f"\nwrote {RESULTS / 'run_spike.json'}")
    if not all(verdict.values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
