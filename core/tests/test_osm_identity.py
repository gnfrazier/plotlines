"""Issue #241 — Plotlines identifies itself to public OSM services.

Policy under test (review §5.1, §3.4; licensing addendum P2): every Overpass
and Nominatim request must go out under a `User-Agent`/referer that names
Plotlines, a version, and a URL an operator can reach — never osmnx's stock
default, which points an operator investigating our load at an unrelated
maintainer's GitHub repo and leaves them no lever but an IP block (#232).
"""

from __future__ import annotations

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
