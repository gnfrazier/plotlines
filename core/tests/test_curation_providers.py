"""Unit tests for `plotlines_core.curation.providers` (ARCH §14.2, D40).

Exercises the pure geometry-conversion helpers, never a live Overpass call —
`OsmLayerProvider.fetch` itself is a thin network wrapper around these, the
same split `graph/loader.py` uses to keep geometry math independently
testable from the disk/network read that feeds it.
"""

from shapely.geometry import Point, Polygon

from plotlines_core.curation.providers import feature_from_geometry, osm_tags_for


def test_osm_tags_for_wildcard_layer_asks_for_the_whole_key():
    tags = osm_tags_for({"historic"})
    assert tags["historic"] is True


def test_osm_tags_for_non_wildcard_layer_asks_for_specific_values():
    tags = osm_tags_for({"natural", "leisure"})
    assert "natural" in tags and "leisure" in tags
    assert "tree" in tags["natural"] or "peak" in tags["natural"] or "spring" in tags["natural"]
    assert tags["natural"] is not True


def test_osm_tags_for_excludes_layers_not_requested():
    tags = osm_tags_for({"natural"})
    assert "historic" not in tags and "amenity" not in tags


def test_osm_tags_for_empty_layer_set_is_empty():
    assert osm_tags_for(set()) == {}


def test_feature_from_geometry_point_has_no_area():
    feature = feature_from_geometry("n1", Point(-105.27, 40.02), {"natural": "peak"})
    assert feature is not None
    assert feature.coord == (-105.27, 40.02)
    assert feature.area_m2 is None


def test_feature_from_geometry_polygon_gets_an_approximate_area():
    # A roughly 200m x 200m square near Boulder, CO (~40N) in degrees.
    d = 0.0018
    poly = Polygon([(-105.27, 40.02), (-105.27 + d, 40.02),
                     (-105.27 + d, 40.02 + d), (-105.27, 40.02 + d)])
    feature = feature_from_geometry("w1", poly, {"leisure": "park", "name": "Test Park"})
    assert feature is not None
    assert feature.area_m2 is not None
    assert feature.area_m2 > 10_000  # order-of-magnitude sanity, not exact


def test_feature_from_geometry_none_is_dropped():
    assert feature_from_geometry("x", None, {}) is None


def test_feature_from_geometry_uses_centroid_for_polygon_coord():
    d = 0.002
    poly = Polygon([(0, 0), (d, 0), (d, d), (0, d)])
    feature = feature_from_geometry("w1", poly, {})
    assert feature is not None
    assert abs(feature.coord[0] - d / 2) < 1e-9
    assert abs(feature.coord[1] - d / 2) < 1e-9
