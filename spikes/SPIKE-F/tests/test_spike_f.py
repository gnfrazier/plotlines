"""SPIKE-F assertions — the three strands of ARCH Q17 / risk A26.

Run:  python3 -m pytest spikes/SPIKE-F/tests -q
(stdlib only; no plotlines_core import.)
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import carriers  # noqa: E402
import logredact  # noqa: E402
from anonview import anonymous_view, arc_shape  # noqa: E402
from fixtures import SECRET_PLOT_POINT, TRIP  # noqa: E402


# ---------------------------------------------------------------- strand 1

def test_path_and_query_carriers_leak_token_to_logs_and_referer():
    data = carriers.run_all()
    for name in ("path", "query"):
        v = data["carriers"][name]
        assert v["token_in_referer_header"], name
        assert v["token_in_request_path"] or v["token_in_query_string"], name


def test_fragment_keeps_token_off_the_wire():
    v = carriers.run_all()["carriers"]["fragment"]
    assert not v["token_in_request_path"]
    assert not v["token_in_query_string"]
    assert not v["token_in_referer_header"]
    # ...but it is not a complete answer:
    assert "browser_history" in v["residual_exposure"]


def test_exchange_for_cookie_puts_token_in_log_exactly_once():
    v = carriers.run_all()["carriers"]["exchange"]
    assert v["token_hits_in_log"] == 1
    assert v["cookie_httponly"] is True
    assert v["cookie_samesite"] is True
    assert v["cookie_is_token"] is False  # opaque, not the share token


# ---------------------------------------------------------------- strand 2

def test_redacted_app_log_record_is_an_allowlist_with_no_token():
    raw = {
        "path": f"/read/{carriers.SHARE_TOKEN}",
        "referer": f"https://app.example.org/read/{carriers.SHARE_TOKEN}",
        "cookie": "__Host-pl_read=abc123",
        "user_agent": "Mozilla/5.0 Firefox/128.0",
        "client_ip": "203.0.113.47",
    }
    red = logredact.redact_record(raw)
    assert not logredact.leaks_secret(red, carriers.SHARE_TOKEN)
    assert "referer" not in red and "cookie" not in red
    assert red["route"] == "/read/{share_token}"
    assert red["client_ip"] == "203.0.113.0/24"
    assert "retain_until" in red
    assert set(red["_dropped_fields"]) >= {"path", "referer", "cookie"}


def test_retention_windows_are_short_for_edge_and_bounded_for_app():
    assert logredact.EDGE_LOG_RETENTION_HOURS <= 72
    assert logredact.APP_LOG_RETENTION_DAYS <= 30


# ---------------------------------------------------------------- strand 3

def test_anonymous_view_never_emits_an_on_arrival_plot_point():
    import json
    view = anonymous_view(TRIP)
    assert SECRET_PLOT_POINT not in json.dumps(view)


def test_anonymous_view_always_emits_hazards_and_provisions():
    import json
    blob = json.dumps(anonymous_view(TRIP))
    assert "undercut and unfenced" in blob       # role hazard
    assert "unbridged fords" in blob             # segment hazards[]
    assert "Last reliable water" in blob         # provision


def test_anonymous_view_keeps_the_arc_shape_visible():
    shape = arc_shape(anonymous_view(TRIP))
    assert "exposition" in shape and "crux" in shape  # crux position kept, content not


def test_anonymous_view_takes_no_identity_and_is_deterministic():
    import inspect, json
    params = inspect.signature(anonymous_view).parameters
    assert list(params) == ["payload"]
    assert json.dumps(anonymous_view(TRIP), sort_keys=True) == \
        json.dumps(anonymous_view(TRIP), sort_keys=True)


def test_withheld_role_is_a_placeholder_not_an_omission():
    view = anonymous_view(TRIP)
    overlook = view["days"][0]["anchors"][2]["roles"]
    withheld = [r for r in overlook if r.get("_visibility") == "withheld"]
    assert len(withheld) == 1
    assert withheld[0]["withheld"] is True
    assert withheld[0]["arc"] == "crux"          # shape survives
    assert "held here until you arrive" in withheld[0]["note"]
