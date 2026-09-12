"""Mirror-side bbox clip — issue #262 (Phase 1.8 of epic #264;
docs/Plotlines_OSM_Acquisition_Review.md §6.7, addendum L1/Q1-C/2c).

Exercises `plotlines_service.mirror_clip`'s pyosmium-only clip logic against
real pyosmium behaviour (tiny synthetic `.osm.pbf` fixtures — never a real
Geofabrik download), not a mock of libosmium's semantics, since the whole
point of this story is the correctness surface a bbox clip owns (§11.7).
Each test below maps to one acceptance-criterion clause:

- the clip returns a clipped `.osm.pbf` from the pinned extracts;
- a way that only partly overlaps the bbox is written whole, never severed
  (the pyosmium-native equivalent of osmium-tool's `complete_ways`, per L1);
- a standalone tagged node (a POI candidate, not part of any way) survives;
- a relation is kept only when it actually references something selected;
- the bbox-spans-two-extracts case merges and deduplicates a shared border
  way rather than emitting it twice;
- a bbox outside every pinned extract's coverage — and a bbox that overlaps
  no real feature — both raise `NoMirrorCoverage`, never a stack trace;
- wall time, output size, and source regions are recorded on every clip.
"""

from __future__ import annotations

from pathlib import Path

import osmium
import pytest

from mirror_clip_fixtures import build_mirror_tree, node, relation, way, write_pbf

from plotlines_service.mirror_clip import (
    ClipResult,
    NoMirrorCoverage,
    clip_bbox,
    discover_region_extracts,
    select_covering_extracts,
    validate_bbox,
)

_BBOX = (-82.6, 34.9, -81.9, 35.6)  # west, south, east, north


def _read_back(path: Path) -> dict:
    ids: dict[str, dict] = {"n": {}, "w": {}, "r": {}}

    class _C(osmium.SimpleHandler):
        def node(self, n):
            ids["n"][n.id] = dict(n.tags)

        def way(self, w):
            ids["w"][w.id] = [nd.ref for nd in w.nodes]

        def relation(self, r):
            ids["r"][r.id] = [(m.type, m.ref) for m in r.members]

    osmium.apply(str(path), _C())
    return ids


class TestValidateBbox:
    def test_accepts_a_well_formed_bbox(self) -> None:
        validate_bbox((-82.6, 34.9, -81.9, 35.6))  # does not raise

    @pytest.mark.parametrize(
        "bbox",
        [
            (-82.0, 35.0, -83.0, 36.0),  # west >= east
            (-82.0, 36.0, -81.0, 35.0),  # south >= north
            (-200.0, 35.0, -81.0, 36.0),  # longitude out of range
            (-82.0, -95.0, -81.0, 36.0),  # latitude out of range
        ],
    )
    def test_rejects_malformed_bbox(self, bbox) -> None:
        with pytest.raises(ValueError):
            validate_bbox(bbox)


class TestDiscoverRegionExtracts:
    def test_no_state_file_means_no_extracts(self, tmp_path: Path) -> None:
        assert discover_region_extracts(tmp_path) == []

    def test_reads_pinned_date_and_regions_from_mirror_state(self, tmp_path: Path) -> None:
        src = write_pbf(
            tmp_path / "src.osm.pbf", nodes=[node(1, -82.0, 35.0)], box=_BBOX
        )
        build_mirror_tree(tmp_path / "mirror", regions={"north-carolina": src})

        extracts = discover_region_extracts(tmp_path / "mirror")

        assert [e.region for e in extracts] == ["north-carolina"]
        assert extracts[0].path.exists()


class TestSelectCoveringExtracts:
    def test_a_valid_header_box_outside_the_query_bbox_is_excluded(self, tmp_path: Path) -> None:
        far_away = write_pbf(
            tmp_path / "far.osm.pbf", nodes=[node(1, 10.0, 50.0)], box=(9.0, 49.0, 11.0, 51.0)
        )
        assert select_covering_extracts(_BBOX, discover_region_extracts(
            build_mirror_tree(tmp_path / "mirror", regions={"far-region": far_away})
        )) == []

    def test_an_extract_with_no_declared_header_box_is_kept_as_unknown_coverage(
        self, tmp_path: Path
    ) -> None:
        unknown = write_pbf(tmp_path / "unknown.osm.pbf", nodes=[node(1, -82.0, 35.0)], box=None)
        mirror = build_mirror_tree(tmp_path / "mirror", regions={"unlabelled": unknown})

        kept = select_covering_extracts(_BBOX, discover_region_extracts(mirror))

        assert [e.region for e in kept] == ["unlabelled"]


class TestCompleteWaysClip:
    def test_a_way_with_only_one_node_in_bbox_is_written_whole(self, tmp_path: Path) -> None:
        # Node 1 is inside the bbox; node 3 is far outside it. §11.7: a
        # correct clip keeps the way's full geometry rather than severing it
        # at the boundary.
        src = write_pbf(
            tmp_path / "src.osm.pbf",
            nodes=[
                node(1, -82.2, 35.2),
                node(2, -82.1, 35.3),
                node(3, -70.0, 40.0),  # well outside _BBOX
            ],
            ways=[way(10, [1, 2, 3], tags={"highway": "path"})],
            box=_BBOX,
        )
        mirror = build_mirror_tree(tmp_path / "mirror", regions={"r": src})
        dest = tmp_path / "out.osm.pbf"

        result = clip_bbox(_BBOX, root=mirror, dest=dest)

        out = _read_back(result.output_path)
        assert out["w"][10] == [1, 2, 3]
        assert set(out["n"]) == {1, 2, 3}  # node 3 pulled in whole, uncut

    def test_a_standalone_tagged_node_in_bbox_survives_with_its_tags(self, tmp_path: Path) -> None:
        src = write_pbf(
            tmp_path / "src.osm.pbf",
            nodes=[node(2, -82.2, 35.2, {"natural": "peak", "name": "Test Peak"})],
            box=_BBOX,
        )
        mirror = build_mirror_tree(tmp_path / "mirror", regions={"r": src})

        result = clip_bbox(_BBOX, root=mirror, dest=tmp_path / "out.osm.pbf")

        out = _read_back(result.output_path)
        assert out["n"][2] == {"natural": "peak", "name": "Test Peak"}

    def test_a_relation_referencing_an_included_way_is_kept_with_its_members(
        self, tmp_path: Path
    ) -> None:
        src = write_pbf(
            tmp_path / "src.osm.pbf",
            nodes=[node(1, -82.2, 35.2), node(2, -82.1, 35.3, {"natural": "peak"})],
            ways=[way(10, [1, 2], tags={"highway": "path"})],
            relations=[relation(100, [("w", 10, ""), ("n", 2, "label")], tags={"type": "route"})],
            box=_BBOX,
        )
        mirror = build_mirror_tree(tmp_path / "mirror", regions={"r": src})

        result = clip_bbox(_BBOX, root=mirror, dest=tmp_path / "out.osm.pbf")

        out = _read_back(result.output_path)
        assert out["r"][100] == [("w", 10), ("n", 2)]

    def test_a_relation_with_no_selected_members_is_dropped(self, tmp_path: Path) -> None:
        src = write_pbf(
            tmp_path / "src.osm.pbf",
            nodes=[
                node(1, -82.2, 35.2, {"natural": "peak"}),  # inside bbox, unrelated
                node(9, -70.0, 40.0),  # outside bbox, not part of any selected way
            ],
            relations=[relation(200, [("n", 9, "")], tags={"type": "route"})],
            box=_BBOX,
        )
        mirror = build_mirror_tree(tmp_path / "mirror", regions={"r": src})

        result = clip_bbox(_BBOX, root=mirror, dest=tmp_path / "out.osm.pbf")

        out = _read_back(result.output_path)
        assert 200 not in out["r"]
        assert 1 in out["n"]  # the unrelated in-bbox feature still made it through


class TestTwoExtractSpan:
    def test_bbox_spanning_two_extracts_merges_and_dedupes_the_shared_border_way(
        self, tmp_path: Path
    ) -> None:
        # A border way (id 10) is present, identical, in both region
        # extracts — exactly how Geofabrik's own clip keeps a boundary way
        # whole on each side. The merge must write it once, not twice.
        west_region = write_pbf(
            tmp_path / "west.osm.pbf",
            nodes=[node(1, -82.5, 35.2), node(2, -82.35, 35.25)],
            ways=[way(10, [1, 2], tags={"highway": "path"})],
            box=(-83.0, 35.0, -82.35, 35.5),
        )
        east_region = write_pbf(
            tmp_path / "east.osm.pbf",
            nodes=[
                node(1, -82.5, 35.2),
                node(2, -82.35, 35.25),
                node(3, -82.2, 35.3, {"amenity": "drinking_water"}),
            ],
            ways=[way(10, [1, 2], tags={"highway": "path"})],
            box=(-82.35, 35.0, -81.9, 35.5),
        )
        mirror = build_mirror_tree(
            tmp_path / "mirror", regions={"west-region": west_region, "east-region": east_region}
        )

        result = clip_bbox((-83.0, 35.0, -81.9, 35.5), root=mirror, dest=tmp_path / "out.osm.pbf")

        out = _read_back(result.output_path)
        assert list(out["w"]) == [10]  # written exactly once, not duplicated
        assert 3 in out["n"]  # the east-only node is still present
        assert set(result.source_regions) == {"west-region", "east-region"}


class TestNoMirrorCoverage:
    def test_no_pinned_extracts_at_all_raises_no_mirror_coverage(self, tmp_path: Path) -> None:
        (tmp_path / "mirror").mkdir()
        with pytest.raises(NoMirrorCoverage):
            clip_bbox(_BBOX, root=tmp_path / "mirror", dest=tmp_path / "out.osm.pbf")

    def test_bbox_outside_every_extracts_declared_coverage_raises(self, tmp_path: Path) -> None:
        far_away = write_pbf(
            tmp_path / "far.osm.pbf", nodes=[node(1, 10.0, 50.0)], box=(9.0, 49.0, 11.0, 51.0)
        )
        mirror = build_mirror_tree(tmp_path / "mirror", regions={"far-region": far_away})

        with pytest.raises(NoMirrorCoverage, match="no pinned extract covers"):
            clip_bbox(_BBOX, root=mirror, dest=tmp_path / "out.osm.pbf")

    def test_bbox_inside_declared_coverage_but_matching_no_feature_raises(
        self, tmp_path: Path
    ) -> None:
        # Header box covers a wide area but nothing in the file actually
        # falls inside the requested bbox — the "genuinely empty" fallback,
        # distinct from the header-box short-circuit above.
        sparse = write_pbf(
            tmp_path / "sparse.osm.pbf",
            nodes=[node(1, -70.0, 40.0)],  # real feature, but outside _BBOX
            box=(-90.0, 30.0, -70.0, 45.0),  # declared coverage DOES include _BBOX
        )
        mirror = build_mirror_tree(tmp_path / "mirror", regions={"sparse-region": sparse})

        with pytest.raises(NoMirrorCoverage, match="matched no feature"):
            clip_bbox(_BBOX, root=mirror, dest=tmp_path / "out.osm.pbf")

    def test_no_coverage_leaves_no_stray_output_file(self, tmp_path: Path) -> None:
        (tmp_path / "mirror").mkdir()
        dest = tmp_path / "out.osm.pbf"
        with pytest.raises(NoMirrorCoverage):
            clip_bbox(_BBOX, root=tmp_path / "mirror", dest=dest)
        assert not dest.exists()


class TestClipResultMetadata:
    def test_records_wall_time_output_bytes_and_source_regions(self, tmp_path: Path) -> None:
        src = write_pbf(
            tmp_path / "src.osm.pbf", nodes=[node(1, -82.2, 35.2, {"natural": "peak"})], box=_BBOX
        )
        mirror = build_mirror_tree(tmp_path / "mirror", regions={"the-region": src})
        dest = tmp_path / "out.osm.pbf"

        result = clip_bbox(_BBOX, root=mirror, dest=dest)

        assert isinstance(result, ClipResult)
        assert result.wall_time_s >= 0.0
        assert result.output_bytes == dest.stat().st_size > 0
        assert result.source_regions == ("the-region",)
        # peak_rss_kb is None only on a platform with no `resource` module
        # (Windows) — this suite runs on Linux, so it must be populated.
        assert result.peak_rss_kb is not None
