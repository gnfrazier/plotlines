"""The About surface — stories K10 (issue #116) and K11 (issue #117).

K10: elevation's CC BY and the basemap's ODbL credit are shown together as
separate obligations, plus a line per loaded plugin layer, and a missing
credit is a build failure. K11: a plain-language privacy statement covering
the clauses FR138 names, reachable from the About surface.
"""

from __future__ import annotations

import pytest

from plotlines_core.curation.attribution import MissingAttributionError
from plotlines_core.curation.providers import BBox, LayerLicence, LayerLoadState, READY
from plotlines_core.curation.registry import LayerRegistry
from plotlines_core.elevation.region_asset import (
    ELEVATION_ATTRIBUTION,
    elevation_attribution,
)
from plotlines_core.web.about import (
    PRIVACY_STATEMENT,
    about_attributions,
    assert_about_attribution_complete,
    build_about_surface,
    privacy_statement,
)


class _FakeOsmEngine:
    licence = "ODbL"

    def fetch(self, bbox, layers):
        return []


class _Plugin:
    taxonomy = ()

    def __init__(self, licence: LayerLicence):
        self._licence = licence

    @property
    def licence(self):
        return self._licence

    def fetch_candidates(self, bbox: BBox):
        return []

    def load_state(self):
        return LayerLoadState(READY)


def _registry() -> LayerRegistry:
    from plotlines_core.curation.providers import builtin_osm_providers

    reg = LayerRegistry()
    reg.register_builtins(builtin_osm_providers(_FakeOsmEngine()))
    return reg


# --- K10: attribution -----------------------------------------------------


def test_elevation_and_basemap_are_shown_together_as_separate_obligations():
    lines = about_attributions(_registry())
    by_layer = {line["layer"]: line for line in lines}

    assert by_layer["elevation"]["licence"] == "CC-BY-4.0"
    assert by_layer["elevation"]["attribution"] == ELEVATION_ATTRIBUTION
    assert by_layer["basemap"]["licence"] == "ODbL-1.0"
    assert by_layer["basemap"]["attribution"] == "© OpenStreetMap contributors"

    # Separate obligations under different licences.
    assert by_layer["elevation"]["licence"] != by_layer["basemap"]["licence"]


def test_elevation_and_basemap_lead_the_list_before_plugin_credits():
    reg = _registry()
    reg.register_plugin("battlefields", _Plugin(
        LayerLicence(id="CC-BY-4.0", attribution="Revwar GIS Project")))
    layers = [line["layer"] for line in about_attributions(reg)]
    assert layers[:2] == ["elevation", "basemap"]
    assert "battlefields" in layers


def test_a_loaded_plugin_layer_credit_propagates_to_the_about_surface():
    reg = _registry()
    reg.register_plugin("battlefields", _Plugin(LayerLicence(
        id="CC-BY-4.0", attribution="Revwar GIS Project",
        terms_url="https://example.org/licence")))
    by_layer = {line["layer"]: line for line in about_attributions(reg)}
    assert by_layer["battlefields"]["attribution"] == "Revwar GIS Project"
    assert by_layer["battlefields"]["terms_url"] == "https://example.org/licence"


def test_elevation_attribution_helper_matches_the_line_on_the_surface():
    assert elevation_attribution() in about_attributions(_registry())


def test_release_gate_passes_when_every_credit_is_present():
    lines = assert_about_attribution_complete(_registry())
    layers = {line["layer"] for line in lines}
    assert {"elevation", "basemap"} <= layers


def test_release_gate_is_a_build_failure_when_a_plugin_credit_is_blank():
    reg = _registry()
    plugin = _Plugin(LayerLicence(id="X", attribution="present at gate"))
    reg.register_plugin("sneaky", plugin)
    plugin._licence = LayerLicence(id="X", attribution="   ")

    with pytest.raises(MissingAttributionError) as excinfo:
        assert_about_attribution_complete(reg)
    assert "sneaky" in str(excinfo.value)


def test_build_about_surface_reports_incomplete_rather_than_raising():
    reg = _registry()
    plugin = _Plugin(LayerLicence(id="X", attribution="present at gate"))
    reg.register_plugin("sneaky", plugin)
    plugin._licence = LayerLicence(id="X", attribution="   ")

    surface = build_about_surface(reg, app_version="1.2.3")
    assert surface.attribution_complete is False
    assert "sneaky" in surface.missing_attribution


def test_build_about_surface_carries_both_versions_on_desktop():
    surface = build_about_surface(
        _registry(), app_version="1.2.3", sidecar_version="1.2.3", mode="sidecar")
    d = surface.as_dict()
    assert d["app_version"] == "1.2.3"
    assert d["sidecar_version"] == "1.2.3"


def test_build_about_surface_omits_sidecar_version_when_there_is_none():
    surface = build_about_surface(_registry(), app_version="1.2.3", mode="hosted")
    assert "sidecar_version" not in surface.as_dict()


# --- K11: privacy statement ---------------------------------------------


def test_privacy_statement_covers_every_clause_fr138_names():
    ids = {point["id"] for point in privacy_statement()}
    assert ids == {
        "on_device",
        "to_server",
        "planning_requests",
        "reveal",
        "arrival_sharing",
        "author_notes",
        "guest_sessions",
    }


def test_privacy_statement_does_not_claim_planning_sends_nothing_anywhere():
    # Phase 0.12 / addendum P1 (issue #252): planning sends the drawn bbox to
    # Overpass and typed place names to Nominatim. No sentence may say
    # otherwise, in either direction.
    for point in PRIVACY_STATEMENT:
        body = point.body.lower()
        assert "nothing sent anywhere" not in body
        assert "nothing about your planning leaves this device" not in body


def test_privacy_statement_names_planning_requests_recipients_and_no_identity():
    body = next(p.body for p in PRIVACY_STATEMENT if p.id == "planning_requests")
    assert "Overpass" in body
    assert "Nominatim" in body
    assert "identity" in body.lower()


def test_privacy_statement_says_reveal_is_not_a_security_boundary():
    body = next(p.body for p in PRIVACY_STATEMENT if p.id == "reveal")
    assert "not a security boundary" in body


def test_privacy_statement_says_arrival_sharing_defaults_to_nothing_shared():
    body = next(p.body for p in PRIVACY_STATEMENT if p.id == "arrival_sharing")
    assert "defaults to nothing shared" in body
    # It shares that you reached a point — nothing more.
    assert "not your live location" in body.lower() or "not your route" in body.lower()


def test_privacy_statement_describes_author_notes_visibility_persistence_deletion():
    body = next(p.body for p in PRIVACY_STATEMENT if p.id == "author_notes")
    assert "visible only to the Author" in body
    assert "persist across trips" in body
    assert "deleted" in body


def test_privacy_statement_says_guest_sessions_leave_no_server_trace():
    body = next(p.body for p in PRIVACY_STATEMENT if p.id == "guest_sessions")
    assert "nothing" in body.lower() and "server" in body.lower()


def test_privacy_statement_is_on_the_assembled_about_surface():
    surface = build_about_surface(_registry(), app_version="1.2.3")
    assert surface.as_dict()["privacy"] == privacy_statement()


def test_privacy_statement_is_prose_not_boilerplate():
    # Not legal boilerplate: no defined-term capitalisation, no section
    # numbers, every point a couple of plain sentences.
    for point in PRIVACY_STATEMENT:
        assert point.body[0].isupper()
        assert point.body.endswith(".")
        assert "hereby" not in point.body.lower()
        assert "pursuant to" not in point.body.lower()
