"""Unit tests for `plotlines_core.curation.defaults` (PRD FR97)."""

from plotlines_core.curation.defaults import resolve_default_layers


def test_riding_day_excludes_amenity_layer():
    layers = resolve_default_layers("cycling", "route")
    assert "amenity" not in layers


def test_rest_day_includes_amenity_layer():
    # FR97's AC, verbatim: "a sauna excluded from a riding day's sight layer,
    # included on a rest day's amenity layer". The sauna itself lives in the
    # taxonomy's 'amenity' layer (see taxonomy.py) — what varies here is
    # whether that layer is live at all for the day type.
    layers = resolve_default_layers("cycling", "rest")
    assert "amenity" in layers


def test_defaults_vary_by_travel_mode():
    cycling_route = resolve_default_layers("cycling", "route")
    paddling_route = resolve_default_layers("paddling", "route")
    assert cycling_route != paddling_route
    assert "historic" in cycling_route and "historic" not in paddling_route


def test_unknown_mode_falls_back_to_default():
    assert resolve_default_layers("unicycling", "route") == resolve_default_layers("_default", "route") \
        or resolve_default_layers("unicycling", "route") == {"sight", "historic", "natural"}


def test_unknown_day_type_yields_empty_set_rather_than_raising():
    assert resolve_default_layers("cycling", "meteor_shower") == set()


def test_defaults_are_config_not_code():
    # FR97: "Layer defaults are data, not code". A caller-supplied config
    # fully determines the result — nothing here hardcodes a rule.
    custom = {"cycling": {"route": ["man_made"]}}
    assert resolve_default_layers("cycling", "route", config=custom) == {"man_made"}
