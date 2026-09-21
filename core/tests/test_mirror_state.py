"""Unit tests for `plotlines_core.tiles.mirror_state` — issue #260 (Phase
1.6 of epic #264; docs/Plotlines_OSM_Acquisition_Review.md §6.6, addendum
Q2/L7).

Covers the staleness monitor `GET /health` surfaces (a deliberately-stalled
pull must read as stale, a fresh one must not) and the L7 pin format
(`geofabrik_attribution_fields`) that Phase 3's payload write is specified
against.
"""

from __future__ import annotations

import http.server
import json
import threading
from datetime import datetime, timedelta, timezone

import pytest

from plotlines_core.curation.providers import OSM_LICENCE
from plotlines_core.tiles.mirror import MIRROR_HOST
from plotlines_core.tiles.mirror_state import (
    DEFAULT_BASEMAP_TTL_DAYS,
    MAX_PIN_AGE_DAYS,
    MIRROR_NOT_CONFIGURED,
    basemap_health,
    geofabrik_attribution_fields,
    geofabrik_health,
    geofabrik_pin_credit,
    load_mirror_state,
    mirror_health,
    pin_age_days,
)

_NOW = datetime(2026, 9, 6, tzinfo=timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.isoformat().replace("+00:00", "Z")


# --- basemap ---------------------------------------------------------------

def test_basemap_health_fresh_build_is_not_stale():
    state = {"basemap": {"build_id": "20260901-wnc"}}
    health = basemap_health(state, now=_NOW)
    assert health == {
        "build_id": "20260901-wnc", "age_days": 5.0, "stale": False,
        "max_age_days": DEFAULT_BASEMAP_TTL_DAYS,
    }


def test_basemap_health_old_build_is_stale():
    state = {"basemap": {"build_id": "20250101-wnc"}}
    health = basemap_health(state, now=_NOW)
    assert health["age_days"] > DEFAULT_BASEMAP_TTL_DAYS
    assert health["stale"] is True


def test_basemap_health_missing_build_id_is_stale():
    state = {"basemap": {"build_id": None}}
    assert basemap_health(state, now=_NOW) == {
        "build_id": None, "age_days": None, "stale": True,
        "max_age_days": DEFAULT_BASEMAP_TTL_DAYS,
    }


def test_basemap_health_prefers_extracted_at_over_the_build_id_date():
    # deploy/mirror/protomaps_extract.py (#394) writes a real pull
    # timestamp — age should read off that, not the build id literal, so a
    # fresh automated pull under an old-looking build id doesn't read stale.
    state = {"basemap": {
        "build_id": "20250101-wnc",
        "extracted_at": _iso(_NOW - timedelta(days=2)),
    }}
    health = basemap_health(state, now=_NOW)
    assert health == {
        "build_id": "20250101-wnc", "age_days": 2.0, "stale": False,
        "max_age_days": DEFAULT_BASEMAP_TTL_DAYS,
    }


def test_basemap_health_ttl_is_independent_of_the_geofabrik_pin_age():
    """Issue #457 acceptance: a 29-day-old extract reads fresh and a
    31-day-old one reads stale, using `DEFAULT_BASEMAP_TTL_DAYS` (30) —
    distinct from `MAX_PIN_AGE_DAYS` (45), which stays Geofabrik's own."""
    assert DEFAULT_BASEMAP_TTL_DAYS < MAX_PIN_AGE_DAYS

    fresh_state = {"basemap": {
        "build_id": "20260101-wnc",
        "extracted_at": _iso(_NOW - timedelta(days=29)),
    }}
    assert basemap_health(fresh_state, now=_NOW)["stale"] is False

    stale_state = {"basemap": {
        "build_id": "20260101-wnc",
        "extracted_at": _iso(_NOW - timedelta(days=31)),
    }}
    assert basemap_health(stale_state, now=_NOW)["stale"] is True


def test_basemap_health_max_age_days_is_configurable():
    state = {"basemap": {
        "build_id": "20260101-wnc",
        "extracted_at": _iso(_NOW - timedelta(days=10)),
    }}
    assert basemap_health(state, now=_NOW, max_age_days=5.0)["stale"] is True
    assert basemap_health(state, now=_NOW, max_age_days=15.0)["stale"] is False


def test_basemap_health_falls_back_to_build_id_when_extracted_at_absent():
    # The manual copy_basemap_standin.sh stand-in path (#257) carries no
    # extracted_at — this is the behaviour test_basemap_health_fresh_build_
    # is_not_stale already covers; this test names the fallback explicitly.
    state = {"basemap": {"build_id": "20260901-wnc"}}
    assert basemap_health(state, now=_NOW)["age_days"] == 5.0


def test_basemap_health_missing_basemap_key_is_stale():
    assert basemap_health({}, now=_NOW)["stale"] is True


# --- pin_age_days (issue #274's shared date-parsing rule) -------------------

def test_pin_age_days_reads_a_bare_pinned_date():
    assert pin_age_days("2026-09-01", now=_NOW) == 5.0


def test_pin_age_days_reads_a_build_id_leading_date():
    assert pin_age_days("20260901-wnc", now=_NOW) == 5.0


def test_pin_age_days_is_none_for_no_pin():
    assert pin_age_days(None, now=_NOW) is None


def test_pin_age_days_is_none_for_an_unparseable_pin():
    assert pin_age_days("not-a-date", now=_NOW) is None


# --- geofabrik ---------------------------------------------------------------

def test_geofabrik_health_no_regions_pulled_yet_is_stale():
    state = {"geofabrik": {"pinned_date": None, "regions": {}, "index": {}}}
    health = geofabrik_health(state, now=_NOW)
    assert health["stale"] is True
    assert health["regions"] == {}


def test_geofabrik_health_freshly_checked_region_is_not_stale():
    checked = _iso(_NOW - timedelta(days=3))
    state = {
        "geofabrik": {
            "pinned_date": "2026-09-01",
            "regions": {
                "north-america/us/north-carolina": {
                    "checked_at": checked, "pulled_at": checked,
                    "consecutive_failures": 0, "last_failure": None,
                },
            },
        },
    }
    health = geofabrik_health(state, now=_NOW)
    assert health["stale"] is False
    region = health["regions"]["north-america/us/north-carolina"]
    assert region["age_days"] == 3.0
    assert region["stale"] is False


def test_a_deliberately_stalled_pull_makes_the_region_visibly_stale():
    """Acceptance criterion: "a deliberately-stalled pull makes it visibly
    stale." A `checked_at` far older than the monthly-pin-plus-grace window
    is exactly a cron that silently stopped running — §11.3's failure
    mode — and must not read the same as a healthy mirror."""
    stalled_checked_at = _iso(_NOW - timedelta(days=120))
    state = {
        "geofabrik": {
            "pinned_date": "2026-05-01",
            "regions": {
                "north-america/us/north-carolina": {
                    "checked_at": stalled_checked_at,
                    "pulled_at": stalled_checked_at,
                    "consecutive_failures": 0, "last_failure": None,
                },
            },
        },
    }
    health = geofabrik_health(state, now=_NOW)
    assert health["stale"] is True
    assert health["regions"]["north-america/us/north-carolina"]["stale"] is True


def test_geofabrik_health_surfaces_last_failure_and_consecutive_failures():
    state = {
        "geofabrik": {
            "pinned_date": "2026-08-01",
            "regions": {
                "north-america/us/north-carolina": {
                    "checked_at": _iso(_NOW - timedelta(days=1)),
                    "consecutive_failures": 4,
                    "last_failure": {"at": _iso(_NOW - timedelta(days=1)),
                                      "reason": ".md5 check failed: timed out"},
                },
            },
        },
    }
    region = geofabrik_health(state, now=_NOW)["regions"]["north-america/us/north-carolina"]
    assert region["consecutive_failures"] == 4
    assert region["last_failure"]["reason"] == ".md5 check failed: timed out"


def test_geofabrik_health_a_stale_index_marks_the_whole_source_stale():
    fresh_region = {
        "checked_at": _iso(_NOW - timedelta(days=1)),
        "consecutive_failures": 0, "last_failure": None,
    }
    stale_index = {
        "checked_at": _iso(_NOW - timedelta(days=200)),
        "etag": "abc", "consecutive_failures": 0, "last_failure": None,
    }
    state = {
        "geofabrik": {
            "pinned_date": "2026-09-05",
            "regions": {"north-america/us/north-carolina": fresh_region},
            "index": stale_index,
        },
    }
    health = geofabrik_health(state, now=_NOW)
    assert health["index"]["stale"] is True
    assert health["stale"] is True


def test_geofabrik_health_unpulled_index_is_not_counted_against_staleness():
    """The `index` pull is opt-in (`--pull-index`) — a mirror that has never
    pulled it (the example skeleton's all-null `index` block) must not read
    as stale on that account alone when its regions are healthy."""
    fresh_region = {
        "checked_at": _iso(_NOW - timedelta(days=1)),
        "consecutive_failures": 0, "last_failure": None,
    }
    state = {
        "geofabrik": {
            "pinned_date": "2026-09-05",
            "regions": {"north-america/us/north-carolina": fresh_region},
            "index": {"etag": None, "checked_at": None, "pulled_at": None,
                      "consecutive_failures": 0, "last_failure": None},
        },
    }
    health = geofabrik_health(state, now=_NOW)
    assert health["index"] is None
    assert health["stale"] is False


# --- mirror_health (the combined /health shape) -----------------------------

def test_mirror_health_is_stale_if_either_half_is():
    state = {
        "basemap": {"build_id": "20260901-wnc"},  # fresh
        "geofabrik": {"pinned_date": None, "regions": {}, "index": {}},  # never pulled
    }
    health = mirror_health(state, now=_NOW)
    assert health["configured"] is True
    assert health["basemap"]["stale"] is False
    assert health["geofabrik"]["stale"] is True
    assert health["stale"] is True


def test_mirror_health_not_stale_when_both_halves_are_fresh():
    state = {
        "basemap": {"build_id": "20260901-wnc"},
        "geofabrik": {
            "pinned_date": "2026-09-01",
            "regions": {
                "north-america/us/north-carolina": {
                    "checked_at": _iso(_NOW - timedelta(days=1)),
                    "consecutive_failures": 0, "last_failure": None,
                },
            },
        },
    }
    assert mirror_health(state, now=_NOW)["stale"] is False


def test_mirror_health_threads_a_separate_basemap_ttl():
    # A build 40 days old is stale against MAX_PIN_AGE_DAYS-shared logic
    # (pre-#457) but fresh against a widened basemap-only TTL passed in.
    state = {
        "basemap": {
            "build_id": "20260101-wnc",
            "extracted_at": _iso(_NOW - timedelta(days=40)),
        },
        "geofabrik": {
            "pinned_date": "2026-09-01",
            "regions": {
                "north-america/us/north-carolina": {
                    "checked_at": _iso(_NOW - timedelta(days=1)),
                    "consecutive_failures": 0, "last_failure": None,
                },
            },
        },
    }
    default_health = mirror_health(state, now=_NOW)
    assert default_health["basemap"]["stale"] is True  # 40 > DEFAULT_BASEMAP_TTL_DAYS (30)
    assert default_health["stale"] is True

    widened_health = mirror_health(state, now=_NOW, basemap_max_age_days=60.0)
    assert widened_health["basemap"]["stale"] is False
    assert widened_health["stale"] is False
    assert widened_health["geofabrik"]["stale"] is False


def test_mirror_not_configured_sentinel_is_a_plain_flag():
    assert MIRROR_NOT_CONFIGURED == {"configured": False}


# --- load_mirror_state -------------------------------------------------------

def test_load_mirror_state_reads_a_local_path(tmp_path):
    state_path = tmp_path / "MIRROR_STATE.json"
    state_path.write_text(json.dumps({"schema_version": 1, "basemap": {}}))
    assert load_mirror_state(state_path) == {"schema_version": 1, "basemap": {}}


def test_load_mirror_state_reads_a_local_path_given_as_a_string(tmp_path):
    state_path = tmp_path / "MIRROR_STATE.json"
    state_path.write_text(json.dumps({"schema_version": 1}))
    assert load_mirror_state(str(state_path)) == {"schema_version": 1}


class _StateHandler(http.server.BaseHTTPRequestHandler):
    """Serves a fixed `MIRROR_STATE.json` body and records the request's
    User-Agent, so the identification requirement (osm_identity's
    contactable UA, addendum P6) is asserted against a real request rather
    than an internal flag."""

    body = b'{"schema_version": 1, "basemap": {"build_id": "20260901-wnc"}}'
    seen_user_agents: list[str] = []

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler's own naming
        self.seen_user_agents.append(self.headers.get("User-Agent", ""))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(self.body)

    def log_message(self, *args):  # silence BaseHTTPRequestHandler's stderr log
        pass


@pytest.fixture
def _state_server():
    _StateHandler.seen_user_agents = []
    server = http.server.HTTPServer(("127.0.0.1", 0), _StateHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        thread.join()


def test_load_mirror_state_fetches_over_http_identified(_state_server):
    host, port = _state_server.server_address
    state = load_mirror_state(f"http://{host}:{port}/MIRROR_STATE.json")
    assert state == {"schema_version": 1, "basemap": {"build_id": "20260901-wnc"}}
    assert len(_StateHandler.seen_user_agents) == 1
    assert _StateHandler.seen_user_agents[0].startswith("Plotlines/")


# --- L7: the on-disk pin format for Provenance/Attribution ------------------

def test_geofabrik_pin_credit_names_the_snapshot_date():
    assert geofabrik_pin_credit("2026-09-01") == "contains OSM data, snapshot 2026-09-01"


def test_geofabrik_pin_credit_handles_an_unknown_date_honestly():
    assert "unknown" in geofabrik_pin_credit(None)


def test_geofabrik_attribution_fields_shape_matches_the_attribution_dataclass():
    """`trips/payload.py`'s `Attribution` takes exactly these four fields —
    Phase 3 constructs it as `Attribution(**geofabrik_attribution_fields(...))`,
    so the keys here are load-bearing, not incidental."""
    state = {"geofabrik": {"pinned_date": "2026-09-01", "regions": {}}}
    fields = geofabrik_attribution_fields(state, "north-america/us/north-carolina")
    assert set(fields) == {"source", "licence", "credit", "url"}
    assert fields["source"] == "geofabrik:north-america/us/north-carolina"
    assert fields["licence"] == OSM_LICENCE.id
    assert fields["credit"] == "contains OSM data, snapshot 2026-09-01"
    assert fields["url"] == (
        f"https://{MIRROR_HOST}/osm/geofabrik/2026-09-01/"
        f"north-america/us/north-carolina.osm.pbf"
    )


def test_geofabrik_attribution_fields_with_no_pin_yet_has_no_url():
    state = {"geofabrik": {"pinned_date": None, "regions": {}}}
    fields = geofabrik_attribution_fields(state, "north-america/us/north-carolina")
    assert fields["url"] is None
    assert "unknown" in fields["credit"]


def test_geofabrik_attribution_fields_constructs_a_real_attribution_dataclass():
    """Proves the L7 contract end to end against the real dataclass, not
    just its field names."""
    from plotlines_core.trips.payload import Attribution

    state = {"geofabrik": {"pinned_date": "2026-09-01", "regions": {}}}
    attribution = Attribution(**geofabrik_attribution_fields(state, "wnc"))
    assert attribution.credit == "contains OSM data, snapshot 2026-09-01"
    assert attribution.to_dict()["licence"] == OSM_LICENCE.id
