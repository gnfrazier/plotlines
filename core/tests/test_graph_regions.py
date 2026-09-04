"""Unit tests for `plotlines_core.graph.regions` (issue #154) — the bbox ->
graph acquisition pipeline promoted from `spikes/shared/regions.py`.

`ensure_graph` makes a live Overpass call when the cache misses; every test
that would miss the cache monkeypatches `ox.graph_from_bbox` with a tiny
synthetic graph instead of touching the network.
"""

from __future__ import annotations

import threading
import time

import networkx as nx
import osmnx as ox
import pytest

from plotlines_core.graph import regions

_BBOX = (-105.30, 39.99, -105.25, 40.03)  # SPIKE-00's Boulder fixture bbox


def _fake_graph(*_args, **_kwargs) -> nx.MultiDiGraph:
    g = nx.MultiDiGraph()
    g.add_node(1, y=40.0, x=-105.28)
    g.add_node(2, y=40.01, x=-105.27)
    g.add_edge(1, 2, length=100.0)
    g.add_edge(2, 1, length=100.0)
    g.graph["crs"] = "epsg:4326"
    return g


def test_region_key_is_stable_for_the_same_bbox():
    a = regions.region_key(_BBOX, "bike")
    b = regions.region_key(_BBOX, "bike")
    assert a == b


def test_region_key_differs_for_a_different_bbox():
    other = (-82.83, 35.36, -82.14, 35.79)  # Buncombe County
    assert regions.region_key(_BBOX, "bike") != regions.region_key(other, "bike")


def test_region_key_differs_for_a_different_network_type():
    assert regions.region_key(_BBOX, "bike") != regions.region_key(_BBOX, "walk")


def test_region_key_differs_across_ruleset_versions():
    assert (regions.region_key(_BBOX, "bike", ruleset_version=1)
            != regions.region_key(_BBOX, "bike", ruleset_version=2))


def test_region_key_ignores_float_noise_below_a_centimetre():
    west, south, east, north = _BBOX
    noisy = (west + 1e-9, south, east, north)
    assert regions.region_key(_BBOX, "bike") == regions.region_key(noisy, "bike")


def test_region_for_derives_the_matching_key():
    region = regions.region_for(_BBOX, "bike")
    assert region.key == regions.region_key(_BBOX, "bike")
    assert region.bbox == _BBOX


def test_region_centre_is_the_bbox_midpoint():
    region = regions.region_for((-1.0, -1.0, 1.0, 1.0))
    assert region.centre == (0.0, 0.0)


def test_ensure_graph_builds_and_caches(tmp_path, monkeypatch):
    monkeypatch.setattr(ox, "graph_from_bbox", _fake_graph)
    monkeypatch.setattr(ox, "simplify_graph", lambda g, **_: g)
    monkeypatch.setattr(ox.truncate, "largest_component", lambda g, **_: g)

    region = regions.region_for(_BBOX, "bike")
    path = regions.ensure_graph(region, tmp_path)

    assert path == region.graph_path(tmp_path)
    assert path.exists()
    reloaded = ox.io.load_graphml(path)
    assert reloaded.number_of_nodes() == 2


def test_ensure_graph_reuses_the_cache_without_hitting_the_network(tmp_path, monkeypatch):
    calls = {"n": 0}

    def counting_fake_graph(*args, **kwargs):
        calls["n"] += 1
        return _fake_graph(*args, **kwargs)

    monkeypatch.setattr(ox, "graph_from_bbox", counting_fake_graph)
    monkeypatch.setattr(ox, "simplify_graph", lambda g, **_: g)
    monkeypatch.setattr(ox.truncate, "largest_component", lambda g, **_: g)

    region = regions.region_for(_BBOX, "bike")
    regions.ensure_graph(region, tmp_path)
    regions.ensure_graph(region, tmp_path)

    assert calls["n"] == 1


def test_ensure_graph_force_rebuilds(tmp_path, monkeypatch):
    calls = {"n": 0}

    def counting_fake_graph(*args, **kwargs):
        calls["n"] += 1
        return _fake_graph(*args, **kwargs)

    monkeypatch.setattr(ox, "graph_from_bbox", counting_fake_graph)
    monkeypatch.setattr(ox, "simplify_graph", lambda g, **_: g)
    monkeypatch.setattr(ox.truncate, "largest_component", lambda g, **_: g)

    region = regions.region_for(_BBOX, "bike")
    regions.ensure_graph(region, tmp_path)
    regions.ensure_graph(region, tmp_path, force=True)

    assert calls["n"] == 2


def test_useful_tags_way_carries_the_surface_extension():
    # FR4's surface weight is inert without this (module import time side
    # effect — spikes/shared/regions.py:47-56's finding).
    for tag in ("surface", "tracktype", "smoothness", "maxspeed", "lanes", "bicycle"):
        assert tag in ox.settings.useful_tags_way


def test_useful_tags_way_carries_the_access_and_ford_tags():
    # Issue #206: driving's legality row is keyed on `motor_vehicle`, and both
    # driving and cycling hard-exclude a ford — neither is recoverable if the
    # tag was never downloaded.
    for tag in ("motor_vehicle", "motorcar", "4wd_only", "ford"):
        assert tag in ox.settings.useful_tags_way


def test_every_tag_the_legality_and_scoring_models_read_is_downloaded():
    """Issue #206: a rule keyed on a tag the builder never requests goes
    silently inert on every real graph. This is the guard that turns that into
    a test failure the moment a new rule reaches for a new tag."""
    from plotlines_core.routing import access
    from plotlines_core.scoring import profile

    way_tags = set(ox.settings.useful_tags_way)
    node_tags = set(ox.settings.useful_tags_node)

    assert access.WAY_ACCESS_KEYS <= way_tags
    assert profile.WAY_SCORING_KEYS <= way_tags
    assert access.NODE_ACCESS_KEYS <= node_tags


def test_ruleset_version_bumped_for_the_new_tag_set():
    # The download tag set is part of the cache key's meaning; every graph
    # cached before issue #206 predates these tags.
    assert regions.GRAPH_RULESET_VERSION >= 2


def test_fold_node_barriers_moves_the_gate_onto_incident_edges():
    g = nx.MultiDiGraph()
    for n in (1, 2, 3):
        g.add_node(n, y=40.0 + n * 0.01, x=-105.28)
    g.add_edge(1, 2, length=100.0)
    g.add_edge(2, 1, length=100.0)
    g.add_edge(2, 3, length=100.0)
    g.nodes[2]["barrier"] = "gate"

    folded = regions.fold_node_barriers(g)

    assert folded == 1
    assert g[1][2][0]["barrier"] == "gate"
    assert g[2][1][0]["barrier"] == "gate"
    assert g[2][3][0]["barrier"] == "gate"


def test_ensure_graph_folds_barriers_and_keeps_the_ford_tag(tmp_path, monkeypatch):
    """Issue #206 acceptance: ford exclusion and barrier surfacing are exercised
    on a graph that has been through `ensure_graph` (build -> simplify -> fold ->
    graphml round-trip), not only on hand-built edge dicts."""
    from plotlines_core.routing.access import evaluate_edge

    def fake_graph(*_a, **_k):
        g = nx.MultiDiGraph()
        for n in (1, 2, 3):
            g.add_node(n, y=40.0 + n * 0.01, x=-105.28)
        g.add_edge(1, 2, length=100.0, highway="service")
        g.add_edge(2, 1, length=100.0, highway="service")
        g.add_edge(2, 3, length=100.0, highway="service", ford="yes")
        g.add_edge(3, 2, length=100.0, highway="service", ford="yes")
        g.nodes[2]["barrier"] = "gate"
        g.graph["crs"] = "epsg:4326"
        return g

    monkeypatch.setattr(ox, "graph_from_bbox", fake_graph)
    monkeypatch.setattr(ox, "simplify_graph", lambda g, **_: g)
    monkeypatch.setattr(ox.truncate, "largest_component", lambda g, **_: g)

    region = regions.region_for(_BBOX, "drive")
    path = regions.ensure_graph(region, tmp_path)
    reloaded = ox.io.load_graphml(path)

    edges = [data for *_uv, data in reloaded.edges(data=True)]
    ford_free_gate = [d for d in edges if d.get("barrier") and not d.get("ford")]
    forded = [d for d in edges if d.get("ford")]

    assert ford_free_gate, "the gate node's tag was not folded onto an edge"
    for data in ford_free_gate:
        assert "gate" in str(data.get("barrier"))
        assert evaluate_edge(data, "driving").flags == frozenset({"barrier=gate"})

    assert forded
    for data in forded:
        verdict = evaluate_edge(data, "driving")
        assert not verdict.passable
        assert verdict.reason == "ford=yes"


def test_configure_overpass_cache_points_at_the_given_dir(tmp_path):
    regions.configure_overpass_cache(tmp_path)
    assert ox.settings.cache_folder == str(tmp_path / "overpass")
    assert ox.settings.use_cache is True


def test_ensure_graph_configures_the_cache_even_on_a_warm_cache_hit(tmp_path, monkeypatch):
    """Issue #242: `configure_overpass_cache` used to sit *past* the
    warm-cache early return, so a direct `ensure_graph` caller that hit the
    cache left `ox.settings.cache_folder` at whatever it was — the
    CWD-relative `./cache` default for a process that never got further.
    Pre-seed the graph so the early return fires, and assert the cache was
    still pointed inside `cache_dir` with no network call.
    """
    ox.settings.cache_folder = "./cache"  # the stray default this issue kills

    region = regions.region_for(_BBOX, "bike")
    seeded = region.graph_path(tmp_path)
    seeded.parent.mkdir(parents=True, exist_ok=True)
    seeded.write_bytes(b"<graphml/>")  # contents irrelevant — only .exists() matters

    def fail_if_called(_region):
        raise AssertionError("warm-cache hit must not touch the network")

    monkeypatch.setattr(regions, "_download_region_graph", fail_if_called)

    path = regions.ensure_graph(region, tmp_path)

    assert path == seeded
    assert ox.settings.cache_folder == str(tmp_path / "overpass")


def test_importing_this_module_sets_a_non_default_osm_user_agent():
    """Politeness policy (issue #241 / #251, review §3.4, addendum P2): a
    graph build must reach Overpass as a named, contactable client — never
    osmnx's stock UA, which points an operator at an unrelated library and
    already draws a 403 from `overpass.openstreetmap.fr` (see this module's
    `DEFAULT_OVERPASS_ENDPOINTS` neighbourhood). Importing `regions` applies
    it as a floor; a real entrypoint re-stamps the build version. Removing
    the module-level `apply_osm_http_identity()` call fails this test.
    """
    ua = ox.settings.http_user_agent
    assert ua == ox.settings.http_referer
    assert ua.startswith("Plotlines/")
    assert "github.com/gnfrazier/plotlines" in ua
    assert "OSMnx" not in ua and "gboeing" not in ua


# --- Overpass endpoint failover (issue #229) ---------------------------------

import requests  # noqa: E402 — grouped with the failover tests it belongs to


def test_overpass_endpoints_defaults_when_env_unset(monkeypatch):
    monkeypatch.delenv("PLOTLINES_OVERPASS_ENDPOINTS", raising=False)
    assert regions.overpass_endpoints() == regions.DEFAULT_OVERPASS_ENDPOINTS


def test_overpass_endpoints_env_override_wins(monkeypatch):
    monkeypatch.setenv(
        "PLOTLINES_OVERPASS_ENDPOINTS",
        " https://mirror.example/api/ , https://other.example/api ",
    )
    assert regions.overpass_endpoints() == (
        "https://mirror.example/api",
        "https://other.example/api",
    )


def test_ensure_graph_fails_over_to_the_next_endpoint(tmp_path, monkeypatch):
    """First endpoint refuses the connection; `ensure_graph` retries the next
    and succeeds, leaving a cached graph."""
    seen: list[str] = []

    def flaky_download(_region):
        seen.append(ox.settings.overpass_url)
        if ox.settings.overpass_url == "https://a.example/api":
            raise requests.exceptions.ConnectionError("connection refused")
        return _fake_graph()

    monkeypatch.setattr(regions, "_download_region_graph", flaky_download)

    region = regions.region_for(_BBOX, "bike")
    path = regions.ensure_graph(
        region, tmp_path,
        endpoints=("https://a.example/api", "https://b.example/api"),
        sleep=lambda _s: None,
    )

    assert path.exists()
    assert seen == ["https://a.example/api", "https://a.example/api",
                    "https://b.example/api"]  # 2 attempts on a, then b


def test_ensure_graph_raises_overpass_unavailable_when_every_endpoint_fails(
    tmp_path, monkeypatch,
):
    def always_refuse(_region):
        raise requests.exceptions.ConnectionError("connection refused")

    monkeypatch.setattr(regions, "_download_region_graph", always_refuse)

    region = regions.region_for(_BBOX, "bike")
    with pytest.raises(regions.OverpassUnavailable) as excinfo:
        regions.ensure_graph(
            region, tmp_path,
            endpoints=("https://a.example/api", "https://b.example/api"),
            sleep=lambda _s: None,
        )

    msg = str(excinfo.value)
    assert "map-data service" in msg           # a sentence, not an exception repr
    assert "ConnectionError" not in msg or "tried:" in msg
    assert not region.graph_path(tmp_path).exists()


def test_ensure_graph_backs_off_between_attempts(tmp_path, monkeypatch):
    slept: list[float] = []

    def always_refuse(_region):
        raise requests.exceptions.ConnectionError("connection refused")

    monkeypatch.setattr(regions, "_download_region_graph", always_refuse)

    region = regions.region_for(_BBOX, "bike")
    with pytest.raises(regions.OverpassUnavailable):
        regions.ensure_graph(
            region, tmp_path,
            endpoints=("https://a.example/api",),
            attempts_per_endpoint=3,
            backoff_base_s=1.0,
            sleep=slept.append,
        )

    # One sleep between each of the 3 attempts except the last -> 2 sleeps,
    # exponential: 1.0, 2.0.
    assert slept == [1.0, 2.0]


def test_ensure_graph_logs_endpoint_failures_and_exhaustion(tmp_path, monkeypatch, caplog):
    monkeypatch.setattr(
        regions, "_download_region_graph",
        lambda _r: (_ for _ in ()).throw(
            requests.exceptions.ConnectionError("refused")
        ),
    )
    region = regions.region_for(_BBOX, "bike")
    with caplog.at_level("INFO", logger="plotlines.regions"):
        with pytest.raises(regions.OverpassUnavailable):
            regions.ensure_graph(
                region, tmp_path,
                endpoints=("https://a.example/api", "https://b.example/api"),
                sleep=lambda _s: None,
            )
    assert "cache=miss" in caplog.text
    assert "https://a.example/api attempt=1" in caplog.text
    assert "EXHAUSTED all 2 endpoints" in caplog.text


def test_ensure_graph_restores_global_overpass_settings_after_failover(
    tmp_path, monkeypatch,
):
    original_url = ox.settings.overpass_url
    original_rate_limit = ox.settings.overpass_rate_limit

    monkeypatch.setattr(
        regions, "_download_region_graph",
        lambda _r: (_ for _ in ()).throw(
            requests.exceptions.ConnectionError("refused")
        ),
    )

    region = regions.region_for(_BBOX, "bike")
    with pytest.raises(regions.OverpassUnavailable):
        regions.ensure_graph(
            region, tmp_path,
            endpoints=("https://a.example/api", "https://b.example/api"),
            sleep=lambda _s: None,
        )

    assert ox.settings.overpass_url == original_url
    assert ox.settings.overpass_rate_limit == original_rate_limit


# --- issue #232: an error HTTP status is a transient endpoint failure --------
#
# osmnx raises `ResponseStatusCodeError` when a mirror answers with an error
# status and a body it cannot parse as JSON — an HTML `502 Bad Gateway` from a
# reverse proxy, say. That class subclasses `ValueError`, *not*
# `requests.exceptions.RequestException`, so before #232 it escaped
# `ensure_graph`'s per-endpoint `except` completely: no retry, no failover to
# the next endpoint, no `OverpassUnavailable`, and the raw exception repr
# surfaced in the client as the `routing` capability's reason.


def _status_error(host: str = "mirror.example", status: str = "502 Bad Gateway"):
    return ox._errors.ResponseStatusCodeError(f"{host!r} responded: {status} ")


def test_ensure_graph_fails_over_when_an_endpoint_returns_an_error_status(
    tmp_path, monkeypatch,
):
    seen: list[str] = []

    def flaky_download(_region):
        seen.append(ox.settings.overpass_url)
        if ox.settings.overpass_url == "https://a.example/api":
            raise _status_error("a.example")
        return _fake_graph()

    monkeypatch.setattr(regions, "_download_region_graph", flaky_download)

    region = regions.region_for(_BBOX, "bike")
    path = regions.ensure_graph(
        region, tmp_path,
        endpoints=("https://a.example/api", "https://b.example/api"),
        sleep=lambda _s: None,
    )

    assert path.exists()
    # 2 attempts on the 502-ing endpoint, then the healthy one — identical to
    # the ConnectionError path. Before #232 this list was ["https://a.example/api"]
    # and the call raised ResponseStatusCodeError.
    assert seen == ["https://a.example/api", "https://a.example/api",
                    "https://b.example/api"]


def test_ensure_graph_raises_overpass_unavailable_when_every_endpoint_errors_status(
    tmp_path, monkeypatch,
):
    monkeypatch.setattr(
        regions, "_download_region_graph",
        lambda _r: (_ for _ in ()).throw(_status_error()),
    )

    region = regions.region_for(_BBOX, "bike")
    with pytest.raises(regions.OverpassUnavailable) as excinfo:
        regions.ensure_graph(
            region, tmp_path,
            endpoints=("https://a.example/api", "https://b.example/api"),
            sleep=lambda _s: None,
        )

    # The #229 contract holds for a status failure too: a finished sentence,
    # never an exception repr leaking to the client.
    assert "map-data service" in str(excinfo.value)
    assert not region.graph_path(tmp_path).exists()


def test_ensure_graph_does_not_retry_an_empty_overpass_response(tmp_path, monkeypatch):
    """`InsufficientResponseError` is a true answer about the bbox (no routable
    ways there), not an outage — it must propagate on the first attempt rather
    than being retried across every endpoint and reported as "couldn't reach
    the map-data service"."""
    attempts: list[str] = []

    def empty_response(_region):
        attempts.append(ox.settings.overpass_url)
        raise ox._errors.InsufficientResponseError("no elements in response")

    monkeypatch.setattr(regions, "_download_region_graph", empty_response)

    region = regions.region_for(_BBOX, "bike")
    with pytest.raises(ox._errors.InsufficientResponseError):
        regions.ensure_graph(
            region, tmp_path,
            endpoints=("https://a.example/api", "https://b.example/api"),
            sleep=lambda _s: None,
        )

    assert attempts == ["https://a.example/api"]


# --- issue #232: a failover list must be distinct machines ------------------


def test_dedupe_endpoints_drops_an_alias_of_an_earlier_host():
    addresses = {
        "https://a.example/api": frozenset({"192.0.2.1"}),
        "https://alias.example/api": frozenset({"192.0.2.1"}),  # same machine
        "https://b.example/api": frozenset({"198.51.100.9"}),
    }
    kept = regions.dedupe_endpoints(
        tuple(addresses), resolve=addresses.__getitem__,
    )
    assert kept == ("https://a.example/api", "https://b.example/api")


def test_dedupe_endpoints_keeps_hosts_that_do_not_resolve():
    endpoints = ("https://a.example/api", "https://b.example/api")
    kept = regions.dedupe_endpoints(
        endpoints, resolve=lambda _e: frozenset(),
    )
    assert kept == endpoints  # unresolvable means unknown, never "duplicate"


def test_dedupe_endpoints_drops_a_repeated_hostname_without_resolving():
    kept = regions.dedupe_endpoints(
        ("https://a.example/api", "https://a.example/api/interpreter"),
        resolve=lambda _e: frozenset(),
    )
    assert kept == ("https://a.example/api",)


def test_default_overpass_endpoints_are_distinct_hosts():
    from urllib.parse import urlparse
    hosts = [urlparse(e).hostname for e in regions.DEFAULT_OVERPASS_ENDPOINTS]
    assert len(hosts) == len(set(hosts))


def test_ensure_graph_dedupes_endpoints_before_trying_them(tmp_path, monkeypatch):
    """The real #232 shape: two of the configured endpoints are names for one
    machine, so the second is not a failover at all."""
    monkeypatch.setattr(
        regions, "resolve_endpoint_addresses",
        lambda endpoint: frozenset({"192.0.2.1"}),  # everything is one host
    )
    tried: list[str] = []

    def always_502(_region):
        tried.append(ox.settings.overpass_url)
        raise _status_error()

    monkeypatch.setattr(regions, "_download_region_graph", always_502)

    region = regions.region_for(_BBOX, "bike")
    with pytest.raises(regions.OverpassUnavailable):
        regions.ensure_graph(
            region, tmp_path,
            endpoints=("https://a.example/api", "https://alias.example/api"),
            sleep=lambda _s: None,
        )

    assert set(tried) == {"https://a.example/api"}  # the alias is never tried


# --- issue #244: a concurrent candidate fetch does not inherit a failover hop -
#
# `ensure_graph` drives the process-global `ox.settings.overpass_url` and
# `overpass_rate_limit` per failover attempt. `/regions` and `/candidates` are
# both sync `def` FastAPI endpoints, so the framework runs them on threadpool
# siblings concurrently — and before #244 a candidate fetch that landed during
# a failing build inherited the failover endpoint *and* `overpass_rate_limit =
# False`, becoming impolite on an upstream nobody chose for it (addendum G1).
# `OSM_SETTINGS_LOCK`, held via `overpass_settings`, serialises the two.


def test_candidate_fetch_does_not_inherit_a_concurrent_failover_hop(tmp_path, monkeypatch):
    """Run a failing region build and a candidate fetch on two threads, the
    way FastAPI's threadpool would. The candidate call must observe the
    *default* Overpass endpoint and rate-limit posture, never the build's
    failover hop.

    Regression: fails against the pre-#244 code — with `ensure_graph` mutating
    `ox.settings` in the open and `OsmLayerProvider.fetch` calling
    `features_from_bbox` with no lock, the candidate thread reads
    `secondary.example` / `False` mid-failover and returns near-instantly.
    """
    from plotlines_core.curation.providers import BBox, OsmLayerProvider

    default_url = ox.settings.overpass_url
    default_rate_limit = ox.settings.overpass_rate_limit
    assert default_url not in (
        "https://primary.example/api", "https://secondary.example/api")

    build_running = threading.Event()
    dirtied: list[tuple[str, object]] = []

    def slow_failing_download(_region):
        # `ensure_graph` has already pointed the globals at this hop.
        dirtied.append((ox.settings.overpass_url, ox.settings.overpass_rate_limit))
        build_running.set()
        time.sleep(0.3)  # hold the dirty globals across the candidate's window
        raise requests.exceptions.ConnectionError("connection refused")

    monkeypatch.setattr(regions, "_download_region_graph", slow_failing_download)

    observed: dict[str, object] = {}

    def fake_features_from_bbox(*_args, **_kwargs):
        import geopandas as gpd

        observed["url"] = ox.settings.overpass_url
        observed["rate_limit"] = ox.settings.overpass_rate_limit
        return gpd.GeoDataFrame({"geometry": []})

    monkeypatch.setattr(ox, "features_from_bbox", fake_features_from_bbox)

    region = regions.region_for(_BBOX, "bike")
    build_error: list[BaseException] = []

    def run_build():
        try:
            regions.ensure_graph(
                region, tmp_path,
                endpoints=("https://primary.example/api",
                           "https://secondary.example/api"),
                attempts_per_endpoint=1,
                sleep=lambda _s: None,
            )
        except regions.OverpassUnavailable as exc:
            build_error.append(exc)

    build_thread = threading.Thread(target=run_build)
    build_thread.start()
    assert build_running.wait(timeout=5), "region build never started"

    started = time.monotonic()
    OsmLayerProvider().fetch(BBox(0.0, 0.0, 0.01, 0.01), {"historic"})
    fetch_elapsed = time.monotonic() - started

    build_thread.join(timeout=5)
    assert not build_thread.is_alive()
    assert build_error, "region build did not raise OverpassUnavailable"

    # The build did mutate the globals — otherwise this test proves nothing.
    assert dirtied[0][0] == "https://primary.example/api"
    assert any(rl is False for _u, rl in dirtied)  # the failover hop turned it off

    # ...and the candidate fetch, forced to wait on the lock, saw only the
    # restored defaults.
    assert observed["url"] == default_url
    assert observed["rate_limit"] == default_rate_limit
    assert fetch_elapsed >= 0.2  # it blocked on the build, it did not race it


def test_overpass_settings_restores_globals_on_exit_and_on_error():
    """`overpass_settings` puts `overpass_url` / `overpass_rate_limit` back to
    their entry values whether the block returns or raises, and `url=None` /
    `rate_limit=None` leave that setting untouched."""
    from plotlines_core.osm_identity import overpass_settings

    original_url = ox.settings.overpass_url
    original_rate_limit = ox.settings.overpass_rate_limit

    with overpass_settings(url="https://scratch.example/api", rate_limit=False):
        assert ox.settings.overpass_url == "https://scratch.example/api"
        assert ox.settings.overpass_rate_limit is False
    assert ox.settings.overpass_url == original_url
    assert ox.settings.overpass_rate_limit == original_rate_limit

    with pytest.raises(RuntimeError):
        with overpass_settings(url="https://scratch.example/api", rate_limit=False):
            raise RuntimeError("boom")
    assert ox.settings.overpass_url == original_url
    assert ox.settings.overpass_rate_limit == original_rate_limit

    with overpass_settings():  # no args -> pure mutual exclusion
        assert ox.settings.overpass_url == original_url
        assert ox.settings.overpass_rate_limit == original_rate_limit


def test_overpass_settings_serialises_two_threads():
    """Two `overpass_settings` blocks never overlap: the second thread's entry
    snapshot is taken only after the first has restored, so it never captures
    the first block's mutated `overpass_url`."""
    from plotlines_core.osm_identity import overpass_settings

    seen_by_second: list[str] = []
    first_in = threading.Event()

    def first():
        with overpass_settings(url="https://first.example/api"):
            first_in.set()
            time.sleep(0.3)

    def second():
        first_in.wait(timeout=5)
        with overpass_settings():
            seen_by_second.append(ox.settings.overpass_url)

    t1 = threading.Thread(target=first)
    t2 = threading.Thread(target=second)
    t1.start()
    t2.start()
    t1.join(timeout=5)
    t2.join(timeout=5)

    assert seen_by_second == [ox.settings.overpass_url]
    assert seen_by_second != ["https://first.example/api"]
