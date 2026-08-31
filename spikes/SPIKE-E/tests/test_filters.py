"""The filter reconstruction is the load-bearing claim of the routing half, so it is
tested against osmnx itself rather than against my reading of it."""

from __future__ import annotations

import pytest

import filters


def test_literals_match_installed_osmnx():
    """If an osmnx upgrade changes what `network_type="drive"` means, this fails
    rather than silently changing a published number."""
    overpass = pytest.importorskip("osmnx._overpass")
    assert filters.OSMNX_DRIVE == overpass._get_network_filter("drive")
    assert filters.OSMNX_DRIVE_SERVICE == overpass._get_network_filter("drive_service")


def test_drive_excludes_track_and_service():
    drive = filters.variant_predicate("drive")
    assert not drive({"highway": "track"})
    assert not drive({"highway": "service"})
    assert drive({"highway": "unclassified"})


def test_service_and_track_variants_restore_them():
    assert filters.variant_predicate("drive_service")({"highway": "service"})
    assert not filters.variant_predicate("drive_service")({"highway": "track"})
    assert filters.variant_predicate("drive_track")({"highway": "track"})


def test_access_private_only_survives_the_private_variant():
    tags = {"highway": "unclassified", "access": "private"}
    assert not filters.variant_predicate("drive")(tags)
    assert not filters.variant_predicate("drive_track")(tags)
    assert filters.variant_predicate("drive_track_private")(tags)


def test_a_way_with_no_highway_tag_is_never_admitted():
    for variant in filters.VARIANTS:
        assert not filters.variant_predicate(variant)({"surface": "gravel"})


def test_list_valued_tags_are_read_whole():
    """Way merging leaves lists behind, and reading only the first element admits an
    edge that is half `motor_vehicle=no` — `routing/access.py` learned this on the
    cycling side (`_values`)."""
    drive = filters.variant_predicate("drive")
    assert not drive({"highway": "unclassified", "motor_vehicle": ["yes", "no"]})
    assert drive({"highway": "unclassified", "motor_vehicle": ["yes", "designated"]})


def test_exclusion_is_an_unanchored_regex_like_overpass():
    """`["motor_vehicle"!~"no"]` is a substring match, not equality. The
    reconstruction keeps the real behaviour rather than the intended one."""
    assert not filters.variant_predicate("drive")(
        {"highway": "unclassified", "motor_vehicle": "nope"})


def test_service_value_exclusions_differ_between_the_two_osmnx_variants():
    driveway = {"highway": "service", "service": "driveway"}
    parking = {"highway": "service", "service": "parking_aisle"}
    assert not filters.variant_predicate("drive_service")(parking)
    # `drive_service` admits driveways; `drive` drops every service road first.
    assert filters.variant_predicate("drive_service")(driveway)
    assert not filters.variant_predicate("drive")(driveway)
