"""L7 (issue #270) — `Provenance` has a producer now.

Before this, `grep` found zero `Provenance(` construction sites in
`core/plotlines_core/` outside test fixtures, while the client already read
it (`reveal_view.dart`'s `attributionForTrip()`). These tests pin the
producer half: `graph.regions.overpass_source_pin` (Phase 1's honest pin
value) and `trips.provenance.build_provenance` (the attribution list,
derived from the loaded layer set rather than hardcoded).
"""

from __future__ import annotations

from plotlines_core.curation.registry import LayerRegistry
from plotlines_core.graph.regions import GRAPH_ATTRIBUTION, overpass_source_pin
from plotlines_core.trips.payload import Attribution, Provenance
from plotlines_core.trips.provenance import build_provenance


class _FakeOsmEngine:
    licence = "ODbL"

    def fetch(self, bbox, layers):
        return []


def _registry() -> LayerRegistry:
    from plotlines_core.curation.providers import builtin_osm_providers

    reg = LayerRegistry()
    reg.register_builtins(builtin_osm_providers(_FakeOsmEngine()))
    return reg


# --- graph.regions.overpass_source_pin --------------------------------------


def test_overpass_source_pin_names_the_transport_and_the_fetch_timestamp():
    # Addendum L7 item 3: honest today means transport + fetch date, never a
    # placeholder and never a mirror build id (that's Phase 3, #277).
    assert (overpass_source_pin("2026-09-01T00:00:00Z")
            == "overpass:2026-09-01T00:00:00Z")


def test_overpass_source_pin_is_a_pure_formatter():
    # No clock of its own — the same input always gives the same pin, so the
    # caller's clock read is the only one that matters.
    assert (overpass_source_pin("2026-01-01T00:00:00Z")
            == overpass_source_pin("2026-01-01T00:00:00Z"))


# --- trips.provenance.build_provenance --------------------------------------


def test_build_provenance_populates_every_declared_field():
    provenance = build_provenance(
        _registry(), app_version="1.2.3", sidecar_version="1.2.3",
        fetched_at="2026-09-01T00:00:00Z",
    )
    assert isinstance(provenance, Provenance)
    assert provenance.produced_by == "plotlines-core 1.2.3"
    assert provenance.app_version == "1.2.3"
    assert provenance.sidecar_version == "1.2.3"
    assert provenance.osm_source == "overpass:2026-09-01T00:00:00Z"
    assert provenance.attribution


def test_build_provenance_defaults_produced_by_from_the_app_version():
    provenance = build_provenance(
        _registry(), app_version="9.9.9", fetched_at="2026-09-01T00:00:00Z")
    assert provenance.produced_by == "plotlines-core 9.9.9"


def test_build_provenance_honours_an_explicit_produced_by():
    provenance = build_provenance(
        _registry(), app_version="9.9.9", produced_by="hosted-worker 4",
        fetched_at="2026-09-01T00:00:00Z")
    assert provenance.produced_by == "hosted-worker 4"


def test_build_provenance_sidecar_only_desktop():
    # Hosted mode has no sidecar (mirrors `/about`'s own `sidecar_version`
    # convention).
    provenance = build_provenance(
        _registry(), app_version="1.0.0", fetched_at="2026-09-01T00:00:00Z")
    assert provenance.sidecar_version is None


def test_build_provenance_attribution_is_derived_not_hardcoded():
    """The attribution list is `web.about.about_attributions`'s own output,
    reshaped into `Attribution` — not a fixed list this module invented. The
    routing graph's credit (issue #269) is the concrete payoff: it now
    travels with the trip rather than living only on the About screen."""
    provenance = build_provenance(
        _registry(), app_version="1.0.0", fetched_at="2026-09-01T00:00:00Z")
    by_source = {a.source: a for a in provenance.attribution}

    assert "graph" in by_source
    assert by_source["graph"].credit == GRAPH_ATTRIBUTION
    assert by_source["graph"].licence == "ODbL-1.0"
    assert "elevation" in by_source
    assert "basemap" in by_source

    for a in provenance.attribution:
        assert isinstance(a, Attribution)
        assert a.credit.strip()


def test_build_provenance_attribution_round_trips_through_to_dict():
    provenance = build_provenance(
        _registry(), app_version="1.0.0", sidecar_version="1.0.0",
        fetched_at="2026-09-01T00:00:00Z")
    emitted = provenance.to_dict()
    assert emitted["osm_source"] == "overpass:2026-09-01T00:00:00Z"
    assert emitted["attribution"]
    for line in emitted["attribution"]:
        assert set(line) == {"source", "licence", "credit", "url"}
