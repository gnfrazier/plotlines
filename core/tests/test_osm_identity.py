"""Issue #241 — Plotlines identifies itself to public OSM services.

Policy under test (review §5.1, §3.4; licensing addendum P2): every Overpass
and Nominatim request must go out under a `User-Agent`/referer that names
Plotlines, a version, and a URL an operator can reach — never osmnx's stock
default, which points an operator investigating our load at an unrelated
maintainer's GitHub repo and leaves them no lever but an IP block (#232).
"""

from __future__ import annotations

import threading
import time

import osmnx as ox
import pytest

from plotlines_core import osm_identity

OSMNX_DEFAULT_UA = "OSMnx Python package (https://github.com/gboeing/osmnx)"


@pytest.fixture(autouse=True)
def _restore_ox_identity():
    """Keep a test that calls `apply_osm_http_identity` from leaking its
    version string into the rest of the suite."""
    saved_ua = ox.settings.http_user_agent
    saved_referer = ox.settings.http_referer
    yield
    ox.settings.http_user_agent = saved_ua
    ox.settings.http_referer = saved_referer


def test_user_agent_names_product_version_and_contact_url():
    ua = osm_identity.osm_user_agent("1.4.2")
    assert "Plotlines" in ua
    assert "1.4.2" in ua
    assert osm_identity.CONTACT_URL in ua
    assert osm_identity.CONTACT_URL.startswith("https://")


def test_user_agent_is_never_the_osmnx_default_even_without_a_version():
    ua = osm_identity.osm_user_agent(None)
    assert ua == osm_identity.DEFAULT_OSM_USER_AGENT
    assert ua != OSMNX_DEFAULT_UA
    assert "gboeing" not in ua and "OSMnx" not in ua
    assert ua.startswith("Plotlines/")


@pytest.mark.parametrize("version", ["", None])
def test_missing_version_degrades_to_unknown_not_to_the_default(version):
    assert osm_identity.osm_user_agent(version) == "Plotlines/unknown (+" \
        f"{osm_identity.CONTACT_URL})"


def test_apply_sets_both_ox_settings_to_the_same_string():
    ox.settings.http_user_agent = OSMNX_DEFAULT_UA
    ox.settings.http_referer = OSMNX_DEFAULT_UA

    returned = osm_identity.apply_osm_http_identity("9.9.9")

    assert returned == osm_identity.osm_user_agent("9.9.9")
    assert ox.settings.http_user_agent == returned
    assert ox.settings.http_referer == returned


def test_apply_reaches_the_outbound_overpass_and_nominatim_headers():
    """`osmnx._overpass` and `osmnx._nominatim` both build their request
    headers from `osmnx._http._get_http_headers()`, which reads exactly the
    two settings `apply_osm_http_identity` writes — so this asserts the
    header that actually leaves the process, not just the settings value
    (issue #241 acceptance: "verified against a real request")."""
    from osmnx import _http

    ox.settings.http_user_agent = OSMNX_DEFAULT_UA
    ox.settings.http_referer = OSMNX_DEFAULT_UA
    osm_identity.apply_osm_http_identity("2.0.0")

    headers = _http._get_http_headers()
    assert headers["User-Agent"] == osm_identity.osm_user_agent("2.0.0")
    assert headers["referer"] == osm_identity.osm_user_agent("2.0.0")
    assert "gboeing" not in headers["User-Agent"]


# ── Issue #490 — bounding the wait for `OSM_SETTINGS_LOCK` ────────────────
#
# `overpass_settings` used to hold `OSM_SETTINGS_LOCK` with a plain, unbounded
# `with OSM_SETTINGS_LOCK:`. That protects the settings mutation fine, but the
# lock is held across the *whole* Overpass round trip in both real callers
# (`graph/regions.py`, `curation/providers.py`), and a second caller waiting
# for it had no bound of its own — it waited on whatever the holder's osmnx
# internals were doing, which can be unbounded (ARCH A23a). `timeout=` turns
# that into an honest, finite `OverpassSettingsBusy` instead.


def test_overpass_settings_waits_for_a_real_release_under_a_generous_timeout():
    """The ordinary case: a lock released promptly is waited for and used,
    not treated as busy just because `timeout=` was given."""
    released = threading.Event()

    def hold_briefly():
        with osm_identity.OSM_SETTINGS_LOCK:
            released.wait(timeout=5)

    holder = threading.Thread(target=hold_briefly)
    holder.start()
    try:
        time.sleep(0.05)  # let the holder actually claim the lock first
        released.set()
        with osm_identity.overpass_settings(timeout=5.0):
            pass  # acquired — did not raise OverpassSettingsBusy
    finally:
        holder.join(timeout=5)


def test_overpass_settings_raises_overpass_settings_busy_after_timeout_even_against_a_lock_held_forever():
    """A lock still held past `timeout` seconds raises `OverpassSettingsBusy`
    rather than blocking past it — the property the whole fix rests on:
    `Lock.acquire(timeout=)` polls wall-clock time, so the wait is bounded
    even against a lock that is never released for the life of this test,
    the pathological case a stalled DNS lookup or osmnx's unbounded
    recursive pause (ARCH A23a) produces."""
    with osm_identity.OSM_SETTINGS_LOCK:  # never released within this test
        started = time.monotonic()
        with pytest.raises(osm_identity.OverpassSettingsBusy):
            with osm_identity.overpass_settings(timeout=0.15):
                pass  # never reached
        elapsed = time.monotonic() - started

    assert 0.15 <= elapsed < 2.0, elapsed


def test_overpass_settings_busy_never_mutates_globals_it_never_entered():
    """A caller that never acquired the lock must never see its `url` /
    `rate_limit` request take effect — there was nothing to restore because
    nothing was ever changed."""
    original_url = ox.settings.overpass_url

    with osm_identity.OSM_SETTINGS_LOCK:
        with pytest.raises(osm_identity.OverpassSettingsBusy):
            with osm_identity.overpass_settings(
                url="https://busy.example/api", timeout=0.1,
            ):
                pass

    assert ox.settings.overpass_url == original_url


# ── Issue #249 — `nominatim_rate_limit` ────────────────────────────────────
#
# Nominatim's usage policy: "an absolute maximum of 1 request per second".
# osmnx's own `pause = 1` (`osmnx/_nominatim.py`) sleeps inside whichever
# thread calls it and shares no state across threads, so it cannot enforce
# the policy across concurrent callers in one process. `nominatim_rate_limit`
# is the process-wide lock plus last-call timestamp that can.


@pytest.fixture(autouse=True)
def _reset_nominatim_rate_limit_state():
    """`_last_nominatim_call_finished` is process-global by design (that is
    the point of the lock) — reset it around every test in this block so one
    test's recorded timestamp can't make the next test's "no prior call"
    assumption false."""
    saved = osm_identity._last_nominatim_call_finished
    saved_interval = osm_identity.NOMINATIM_MIN_INTERVAL_S
    osm_identity._last_nominatim_call_finished = None
    yield
    osm_identity._last_nominatim_call_finished = saved
    osm_identity.NOMINATIM_MIN_INTERVAL_S = saved_interval


def test_first_call_never_waits():
    """No prior call recorded -> the block runs immediately."""
    slept: list[float] = []
    with osm_identity.nominatim_rate_limit(sleep=slept.append, monotonic=lambda: 100.0):
        pass
    assert slept == []


def test_a_second_call_waits_out_the_remainder_of_the_interval():
    """`monotonic` is only consulted on entry (to check the gap) and on exit
    (to record when the block finished) — never on a first call's entry,
    since there's no prior timestamp to compare against yet."""
    slept: list[float] = []
    # 1st block: no prior timestamp, so entry draws nothing; exit -> t=0.0.
    # 2nd block: entry -> t=0.4 (0.4s have elapsed); exit -> t=0.9.
    clock = iter([0.0, 0.4, 0.9])
    with osm_identity.nominatim_rate_limit(sleep=slept.append, monotonic=lambda: next(clock)):
        pass
    with osm_identity.nominatim_rate_limit(sleep=slept.append, monotonic=lambda: next(clock)):
        pass
    assert slept == pytest.approx([osm_identity.NOMINATIM_MIN_INTERVAL_S - 0.4])


def test_no_wait_once_the_interval_has_already_elapsed():
    slept: list[float] = []
    # 1st block exit -> t=0.0. 2nd block entry -> t=5.0 (well past the
    # interval); exit -> t=5.1.
    clock = iter([0.0, 5.0, 5.1])
    with osm_identity.nominatim_rate_limit(sleep=slept.append, monotonic=lambda: next(clock)):
        pass
    with osm_identity.nominatim_rate_limit(sleep=slept.append, monotonic=lambda: next(clock)):
        pass
    assert slept == []


def test_restores_after_an_exception_and_still_records_the_finish_time():
    slept: list[float] = []
    clock = iter([0.0])  # no prior timestamp yet -> only the exit is drawn
    with pytest.raises(RuntimeError):
        with osm_identity.nominatim_rate_limit(sleep=slept.append, monotonic=lambda: next(clock)):
            raise RuntimeError("boom")

    clock2 = iter([0.05, 0.1])  # entry -> t=0.05; exit -> t=0.1
    with osm_identity.nominatim_rate_limit(sleep=slept.append, monotonic=lambda: next(clock2)):
        pass
    # The failed block still counted as "finished" at t=0.0, so the next
    # block at t=0.05 waits out the rest of the interval rather than running
    # free — a raising caller must not let the next one skip the pacing.
    assert slept == pytest.approx([osm_identity.NOMINATIM_MIN_INTERVAL_S - 0.05])


def test_serialises_two_threads_and_neither_ever_overlaps():
    """The real invariant end to end, with the real clock: two threads that
    both want to call at once are forced apart by at least the interval, and
    the tracked in-flight count never exceeds 1."""
    lock = threading.Lock()
    in_flight = 0
    max_in_flight = 0
    starts: list[float] = []
    interval = 0.15

    def call():
        nonlocal in_flight, max_in_flight
        with osm_identity.nominatim_rate_limit():
            with lock:
                in_flight += 1
                max_in_flight = max(max_in_flight, in_flight)
                starts.append(time.monotonic())
            time.sleep(0.02)
            with lock:
                in_flight -= 1

    osm_identity.NOMINATIM_MIN_INTERVAL_S = interval
    threads = [threading.Thread(target=call) for _ in range(3)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=5)

    assert max_in_flight == 1
    starts.sort()
    gaps = [b - a for a, b in zip(starts, starts[1:])]
    assert all(gap >= interval - 0.02 for gap in gaps), gaps
