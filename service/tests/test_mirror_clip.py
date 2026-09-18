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

from mirror_clip_fixtures import build_mirror_tree, node, relation, way, write_pbf, write_poly

from plotlines_service.mirror_clip import (
    ClipResult,
    InvalidPoly,
    NoMirrorCoverage,
    clip_bbox,
    discover_region_extracts,
    parse_poly,
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

    def test_result_carries_the_mirror_s_pinned_date(self, tmp_path: Path) -> None:
        # Issue #274: the client-side extract fetch caches under this pin
        # and has no other way to learn it.
        src = write_pbf(
            tmp_path / "src.osm.pbf",
            nodes=[node(1, -82.2, 35.2)],
            box=_BBOX,
        )
        mirror = build_mirror_tree(
            tmp_path / "mirror", pinned_date="2026-08-01", regions={"r": src}
        )

        result = clip_bbox(_BBOX, root=mirror, dest=tmp_path / "out.osm.pbf")

        assert result.pin == "2026-08-01"

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


class TestTwoExtractMergeInversion:
    """Issue #376: `MergeInputReader` buffers every object from every input
    file in memory, so it must only ever run on small, already-clipped
    outputs — never on the raw region extracts, which is what OOM-killed
    the process on the Pi in ~9s. These tests pin the inversion itself
    (what `_merge_extracts` is actually called with), not just the output
    `TestTwoExtractSpan` already covers."""

    def test_merge_only_ever_sees_clipped_outputs_not_the_raw_extracts(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        import plotlines_service.mirror_clip as mc

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
            tmp_path / "mirror",
            regions={"west-region": west_region, "east-region": east_region},
        )
        raw_extract_paths = {
            (mirror / "osm" / "geofabrik" / "2026-09-01" / f"{name}.osm.pbf").resolve()
            for name in ("west-region", "east-region")
        }

        captured: dict[str, list[Path]] = {}
        original_merge = mc._merge_extracts

        def _spy(paths: list[Path], dest: Path) -> None:
            captured["paths"] = [p.resolve() for p in paths]
            captured["sizes"] = [p.stat().st_size for p in paths]
            original_merge(paths, dest)

        monkeypatch.setattr(mc, "_merge_extracts", _spy)

        mc.clip_bbox((-83.0, 35.0, -81.9, 35.5), root=mirror, dest=tmp_path / "out.osm.pbf")

        assert "paths" in captured, "the merge path must have run for a two-extract bbox"
        assert not raw_extract_paths & set(captured["paths"]), (
            "merge must never see a raw region extract path — that's the OOM"
        )
        # Each already-clipped partial is no larger than its raw source —
        # at real Geofabrik scale this is a multi-hundred-MB-to-few-MB drop.
        for merged_path, size in zip(captured["paths"], captured["sizes"]):
            assert size <= max(west_region.stat().st_size, east_region.stat().st_size)

    def test_a_header_only_over_selection_skips_the_merge_entirely(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The common WNC-style case: two extracts' header boxes both
        overlap the query bbox, but only one actually has a feature there.
        No merge is needed at all — just the one contributing clip."""
        import plotlines_service.mirror_clip as mc

        has_data = write_pbf(
            tmp_path / "has_data.osm.pbf",
            nodes=[node(1, -82.2, 35.2, {"natural": "peak"})],
            box=(-83.0, 35.0, -81.9, 35.5),
        )
        no_data_here = write_pbf(
            tmp_path / "no_data_here.osm.pbf",
            nodes=[node(9, -70.0, 40.0)],  # real feature, but outside the query bbox
            box=(-83.0, 35.0, -81.9, 35.5),  # declared coverage still overlaps
        )
        mirror = build_mirror_tree(
            tmp_path / "mirror",
            regions={"has-data": has_data, "no-data-here": no_data_here},
        )

        def _explode(paths: list[Path], dest: Path) -> None:
            raise AssertionError("merge must not run when only one extract contributed")

        monkeypatch.setattr(mc, "_merge_extracts", _explode)

        result = mc.clip_bbox(
            (-82.6, 34.9, -81.9, 35.6), root=mirror, dest=tmp_path / "out.osm.pbf"
        )

        out = _read_back(result.output_path)
        assert out["n"][1] == {"natural": "peak"}


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
        # Both RSS fields are None only on a platform with no `resource`
        # module (Windows) — this suite runs on Linux, so both are populated.
        assert result.service_peak_rss_kb is not None
        assert result.clip_rss_delta_kb is not None
        assert result.clip_rss_delta_kb >= 0


class TestRssFields:
    """Issue #374: `service_peak_rss_kb` is `ru_maxrss` under `RUSAGE_SELF`,
    a process-lifetime watermark that never decreases — every clip after the
    largest one reports that one's number. `clip_rss_delta_kb` is the
    honestly-imperfect per-clip alternative these tests exist to pin down:
    it is always `service_peak_rss_kb`'s delta since this clip started, so a
    clip that doesn't push the watermark any higher than an earlier, larger
    clip already did reports 0 — never that earlier clip's number."""

    def test_a_later_smaller_clip_does_not_inherit_an_earlier_larger_clips_delta(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        import plotlines_service.mirror_clip as mc

        src = write_pbf(
            tmp_path / "src.osm.pbf", nodes=[node(1, -82.2, 35.2)], box=_BBOX
        )
        mirror = build_mirror_tree(tmp_path / "mirror", regions={"r": src})

        # A monotonic ru_maxrss sequence: the first clip pushes the process
        # watermark from 1000 to 5000 (its own delta: 4000); the second
        # clip's own work never exceeds that watermark, so the real
        # `ru_maxrss` figure the OS would report stays flat at 5000 — the
        # exact "every request after the largest one" scenario #374 reports.
        readings = iter([1000, 5000, 5000, 5000])

        class _FakeRusage:
            def __init__(self, ru_maxrss: int) -> None:
                self.ru_maxrss = ru_maxrss

        monkeypatch.setattr(
            mc.resource, "getrusage", lambda who: _FakeRusage(next(readings))
        )

        first = mc.clip_bbox(_BBOX, root=mirror, dest=tmp_path / "out1.osm.pbf")
        second = mc.clip_bbox(_BBOX, root=mirror, dest=tmp_path / "out2.osm.pbf")

        assert first.service_peak_rss_kb == 5000
        assert first.clip_rss_delta_kb == 4000
        # The bug #374 reports: the process watermark is unchanged...
        assert second.service_peak_rss_kb == 5000
        # ...but the per-clip figure correctly shows this clip set no new
        # high, rather than silently repeating the first clip's 4000.
        assert second.clip_rss_delta_kb == 0


class TestParsePoly:
    def test_a_single_ring_parses_to_its_vertices(self) -> None:
        text = "fixture\nouter\n   -83.0   35.0\n   -82.0   35.0\n   -82.0   36.0\nEND\nEND\n"
        rings = parse_poly(text)
        assert rings == [[(-83.0, 35.0), (-82.0, 35.0), (-82.0, 36.0)]]

    def test_a_hole_ring_is_dropped_not_subtracted(self) -> None:
        # Dropping (rather than subtracting) a hole can only ever grow the
        # tested shape, never shrink it — the same "uncertain coverage is
        # kept, not excluded" direction as everything else in this module.
        text = (
            "fixture\n"
            "outer\n   -83.0   35.0\n   -81.0   35.0\n   -81.0   37.0\n   -83.0   37.0\nEND\n"
            "!hole\n   -82.5   35.5\n   -82.0   35.5\n   -82.0   36.0\nEND\n"
            "END\n"
        )
        rings = parse_poly(text)
        assert len(rings) == 1  # the hole ring never made it into the output

    def test_missing_outer_end_is_invalid(self) -> None:
        with pytest.raises(InvalidPoly):
            parse_poly("fixture\nouter\n   -83.0   35.0\nEND\n")  # no trailing file END

    def test_malformed_coordinate_line_is_invalid(self) -> None:
        with pytest.raises(InvalidPoly):
            parse_poly("fixture\nouter\n   not-a-number   35.0\nEND\nEND\n")


class TestClipOutputHeaderBox:
    """Defect found live on the Pi while taking #402's post-precut
    measurements: neither `osmium.BackReferenceWriter` (single-extract
    path) nor `_merge_extracts` (multi-extract path) declared a header box
    on `clip_bbox`'s output, so a `.osm.pbf` this mirror produced and later
    re-pinned as a source (`precut_region`, issue #375) had no header for
    `_header_box` to exclude on — every request against it fell back to
    'unknown coverage, keep' and paid a full scan before failing, even for
    a bbox nowhere near it. A real coverage-miss request against the live
    corridor precut took 100+ seconds instead of failing in milliseconds.
    Fixed by `_stamp_header_box`; these tests fail against the code before
    that function existed (`clip_bbox`'s output read back with an invalid
    header box)."""

    def test_clip_output_carries_a_valid_header_box(self, tmp_path: Path) -> None:
        src = write_pbf(
            tmp_path / "src.osm.pbf", nodes=[node(1, -82.2, 35.2)], box=_BBOX
        )
        mirror = build_mirror_tree(tmp_path / "mirror", regions={"r": src})

        result = clip_bbox(_BBOX, root=mirror, dest=tmp_path / "out.osm.pbf")

        reader = osmium.io.Reader(str(result.output_path))
        try:
            box = reader.header().box()
            assert box.valid()
            assert box.bottom_left.lon == pytest.approx(_BBOX[0])
            assert box.bottom_left.lat == pytest.approx(_BBOX[1])
            assert box.top_right.lon == pytest.approx(_BBOX[2])
            assert box.top_right.lat == pytest.approx(_BBOX[3])
        finally:
            reader.close()

    def test_a_re_pinned_clip_output_fast_excludes_an_unrelated_bbox(
        self, tmp_path: Path
    ) -> None:
        # Reproduces the real bug's shape: clip once (as precut_region
        # does), then treat that output as a freshly-pinned source extract
        # (as the next request against a precut mirror does) and confirm a
        # clearly-unrelated bbox is excluded by the header box alone —
        # never reaching a scan.
        src = write_pbf(
            tmp_path / "src.osm.pbf", nodes=[node(1, -82.2, 35.2)], box=_BBOX
        )
        source_mirror = build_mirror_tree(tmp_path / "source", regions={"r": src})
        precut = clip_bbox(_BBOX, root=source_mirror, dest=tmp_path / "precut.osm.pbf")

        re_pinned = build_mirror_tree(
            tmp_path / "re-pinned", regions={"precut-region": precut.output_path}
        )
        far_away_bbox = (10.0, 50.0, 11.0, 51.0)  # nowhere near _BBOX

        kept = select_covering_extracts(
            far_away_bbox, discover_region_extracts(re_pinned)
        )

        assert kept == []


class TestSelectCoveringExtractsWithPoly:
    """Issue #402, named but left unaddressed in #375: a state line runs
    diagonally, so a query bbox near it routinely sits inside both
    neighbours' *rectangular* header boxes even though only one of them
    actually reaches that point. These tests build two extracts whose
    header boxes both cover the query bbox but whose real `.poly`
    boundaries do not both — `west-region`'s boundary is a diamond that
    excludes the query bbox's corner even though its header box (a
    superset rectangle, exactly what Geofabrik publishes) includes it."""

    def _mirror_with_two_overlapping_header_boxes(self, tmp_path: Path) -> Path:
        # Both header boxes are the same generous rectangle; only their
        # `.poly` boundaries (added per-test, at the extracts' *mirrored*
        # paths — build_mirror_tree copies fixtures to a new filename under
        # osm/geofabrik/<pinned_date>/, so a `.poly` written next to the
        # source file would never be found there) differ.
        shared_box = (-83.0, 35.0, -81.5, 36.0)
        west = write_pbf(
            tmp_path / "west.osm.pbf", nodes=[node(1, -82.9, 35.9)], box=shared_box
        )
        east = write_pbf(
            tmp_path / "east.osm.pbf", nodes=[node(2, -81.6, 35.1)], box=shared_box
        )
        return build_mirror_tree(
            tmp_path / "mirror", regions={"west-region": west, "east-region": east}
        )

    @staticmethod
    def _mirrored_path(mirror: Path, region: str) -> Path:
        extracts = {e.region: e.path for e in discover_region_extracts(mirror)}
        return extracts[region]

    def test_a_query_bbox_outside_one_extracts_real_boundary_excludes_it(
        self, tmp_path: Path
    ) -> None:
        mirror = self._mirror_with_two_overlapping_header_boxes(tmp_path)
        # west-region's real boundary is a small square in the NW corner of
        # its (generous) header box — nowhere near the query bbox below.
        write_poly(
            self._mirrored_path(mirror, "west-region"),
            [[(-83.0, 35.8), (-82.8, 35.8), (-82.8, 36.0), (-83.0, 36.0)]],
        )
        # east-region's real boundary is a small square that *does* cover
        # the query bbox.
        write_poly(
            self._mirrored_path(mirror, "east-region"),
            [[(-81.7, 35.05), (-81.55, 35.05), (-81.55, 35.15), (-81.7, 35.15)]],
        )
        query_bbox = (-81.65, 35.08, -81.6, 35.12)

        kept = select_covering_extracts(query_bbox, discover_region_extracts(mirror))

        assert [e.region for e in kept] == ["east-region"]

    def test_an_extract_with_no_poly_file_falls_back_to_the_header_box(
        self, tmp_path: Path
    ) -> None:
        # Neither extract has a `.poly` on disk — same as every pin before
        # this feature existed. Both stay in, exactly as before.
        mirror = self._mirror_with_two_overlapping_header_boxes(tmp_path)
        query_bbox = (-82.0, 35.4, -81.9, 35.5)

        kept = select_covering_extracts(query_bbox, discover_region_extracts(mirror))

        assert {e.region for e in kept} == {"west-region", "east-region"}

    def test_a_poly_file_that_fails_to_parse_falls_back_to_the_header_box(
        self, tmp_path: Path
    ) -> None:
        mirror = self._mirror_with_two_overlapping_header_boxes(tmp_path)
        west_path = self._mirrored_path(mirror, "west-region")
        name = west_path.name[: -len(".osm.pbf")]
        (west_path.with_name(name + ".poly")).write_text("not a poly file at all")
        query_bbox = (-82.0, 35.4, -81.9, 35.5)

        kept = select_covering_extracts(query_bbox, discover_region_extracts(mirror))

        assert "west-region" in {e.region for e in kept}


class TestClipCache:
    """Issue #402: the clip cache #262 deliberately excluded ("this
    service re-clips on every request and caches nothing"), now opt-in via
    `cache_dir`. `cache_dir=None` (the default) must reproduce the
    original always-recompute behaviour exactly — every other test in this
    file exercises that path and stays unchanged."""

    def test_a_second_identical_request_is_served_from_cache(self, tmp_path: Path) -> None:
        src = write_pbf(
            tmp_path / "src.osm.pbf",
            nodes=[node(1, -82.2, 35.2, {"amenity": "cafe"})],
            box=_BBOX,
        )
        mirror = build_mirror_tree(tmp_path / "mirror", regions={"r": src})
        cache_dir = tmp_path / "cache"

        first = clip_bbox(
            _BBOX, root=mirror, dest=tmp_path / "out1.osm.pbf", cache_dir=cache_dir
        )
        second = clip_bbox(
            _BBOX, root=mirror, dest=tmp_path / "out2.osm.pbf", cache_dir=cache_dir
        )

        assert first.cache_hit is False
        assert second.cache_hit is True
        assert second.source_regions == first.source_regions
        assert second.pin == first.pin
        assert second.output_path.read_bytes() == first.output_path.read_bytes()

    def test_without_cache_dir_behaviour_is_unchanged(self, tmp_path: Path) -> None:
        src = write_pbf(
            tmp_path / "src.osm.pbf", nodes=[node(1, -82.2, 35.2)], box=_BBOX
        )
        mirror = build_mirror_tree(tmp_path / "mirror", regions={"r": src})

        result = clip_bbox(_BBOX, root=mirror, dest=tmp_path / "out.osm.pbf")

        assert result.cache_hit is False

    def test_a_re_pin_invalidates_the_old_pins_cache_entry(self, tmp_path: Path) -> None:
        src = write_pbf(
            tmp_path / "src.osm.pbf", nodes=[node(1, -82.2, 35.2)], box=_BBOX
        )
        cache_dir = tmp_path / "cache"

        old_mirror = build_mirror_tree(
            tmp_path / "old", pinned_date="2026-08-01", regions={"r": src}
        )
        clip_bbox(_BBOX, root=old_mirror, dest=tmp_path / "out1.osm.pbf", cache_dir=cache_dir)

        new_mirror = build_mirror_tree(
            tmp_path / "new", pinned_date="2026-09-01", regions={"r": src}
        )
        second = clip_bbox(
            _BBOX, root=new_mirror, dest=tmp_path / "out2.osm.pbf", cache_dir=cache_dir
        )

        # A fresh pin has never been cached, regardless of what an older
        # pin's cache holds for the identical bbox.
        assert second.cache_hit is False
        assert second.pin == "2026-09-01"

    def test_corrupted_cache_metadata_degrades_to_a_miss_not_a_failure(
        self, tmp_path: Path
    ) -> None:
        src = write_pbf(
            tmp_path / "src.osm.pbf", nodes=[node(1, -82.2, 35.2)], box=_BBOX
        )
        mirror = build_mirror_tree(tmp_path / "mirror", regions={"r": src})
        cache_dir = tmp_path / "cache"

        first = clip_bbox(
            _BBOX, root=mirror, dest=tmp_path / "out1.osm.pbf", cache_dir=cache_dir
        )
        for meta_path in cache_dir.glob("*/*.json"):
            meta_path.write_text("{not valid json")

        second = clip_bbox(
            _BBOX, root=mirror, dest=tmp_path / "out2.osm.pbf", cache_dir=cache_dir
        )

        assert second.cache_hit is False
        assert second.output_path.read_bytes() == first.output_path.read_bytes()

    def test_eviction_drops_the_oldest_entry_once_over_budget(self, tmp_path: Path) -> None:
        # Exercises `_evict_cache` directly against hand-built cache
        # entries of known size and age — a real fixture clip's output is
        # only a few hundred bytes, too small to pick a `cache_max_bytes`
        # that reliably fits one entry but not two without pinning this
        # test to that incidental size.
        import os as _os

        import plotlines_service.mirror_clip as mc

        cache_dir = tmp_path / "cache" / "2026-09-01"
        cache_dir.mkdir(parents=True)
        old_entry = cache_dir / "old.pbf"
        new_entry = cache_dir / "new.pbf"
        old_entry.write_bytes(b"x" * 100)
        new_entry.write_bytes(b"x" * 100)
        old_entry.with_suffix(".json").write_text('{"source_regions": []}')
        new_entry.with_suffix(".json").write_text('{"source_regions": []}')
        now = _os.stat(old_entry).st_mtime
        _os.utime(old_entry, (now - 10, now - 10))
        _os.utime(new_entry, (now, now))

        mc._evict_cache(tmp_path / "cache", max_bytes=150)

        remaining = {p.name for p in (tmp_path / "cache").glob("*/*.pbf")}
        assert remaining == {"new.pbf"}, "the older entry must be evicted first"
        # Its sidecar metadata goes with it — no orphaned .json left behind.
        assert not old_entry.with_suffix(".json").exists()


class TestLocationIndexStrategy:
    """Issue #402 (`BackReferenceWriter` memory): SPIKE-I measured
    switching `apply_file`'s location index from the default `flex_mem`
    to a disk-backed `sparse_file_array` dropping `complete_ways` peak RSS
    from 2,842 MB to 1,770 MB on a real extract, with identical output —
    real, available, and not the whole fix (see `_select_and_write`'s
    docstring for what it doesn't solve)."""

    def test_apply_file_is_called_with_a_disk_backed_sparse_index(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        import osmium

        import plotlines_service.mirror_clip as mc

        src = write_pbf(
            tmp_path / "src.osm.pbf", nodes=[node(1, -82.2, 35.2)], box=_BBOX
        )
        mirror = build_mirror_tree(tmp_path / "mirror", regions={"r": src})
        scratch = tmp_path / "scratch"
        scratch.mkdir()

        captured: dict[str, str] = {}
        original = osmium.SimpleHandler.apply_file

        def _spy(self, filename, locations=False, idx="flex_mem", filters=None):
            captured["idx"] = idx
            kwargs = {"locations": locations, "idx": idx}
            if filters is not None:
                kwargs["filters"] = filters
            return original(self, filename, **kwargs)

        monkeypatch.setattr(osmium.SimpleHandler, "apply_file", _spy)

        mc.clip_bbox(_BBOX, root=mirror, dest=tmp_path / "out.osm.pbf", tmp_dir=scratch)

        assert captured["idx"].startswith("sparse_file_array,")
        index_path = Path(captured["idx"].split(",", 1)[1])
        assert index_path.parent == scratch
        # The backing file is scratch space, not left behind after the clip.
        assert not index_path.exists()
