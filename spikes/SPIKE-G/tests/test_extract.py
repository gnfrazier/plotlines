import extract
import pytest

REGIONS = ("avl", "lwr", "sgv")
EXPECTED_COUNT = {"avl": 715, "lwr": 72, "sgv": 1208}


@pytest.mark.parametrize("region", REGIONS)
def test_every_candidate_is_positioned(region):
    cands = extract.load_candidates(region)
    assert len(cands) == EXPECTED_COUNT[region]
    for c in cands:
        assert -90 <= c.lat <= 90
        assert -180 <= c.lon <= 180
        assert 0.0 <= c.salience <= 1.0


@pytest.mark.parametrize("region", REGIONS)
def test_candidates_fall_inside_region_bbox(region):
    # `out center` returns the centre of a feature's bounding box, which for a
    # large area straddling the query edge can sit just outside it — so allow a
    # loose margin, but require the vast majority to be comfortably inside.
    # A few candidates are long linear features (`historic=road`) whose
    # bbox-centre lands well outside the query extent; SPIKE-A still counts them.
    # Require the overwhelming majority to sit inside a tight margin.
    s, w, n, e = extract.region_bbox(region)
    cands = extract.load_candidates(region)
    inside = sum(
        1 for c in cands
        if s - 0.02 <= c.lat <= n + 0.02 and w - 0.02 <= c.lon <= e + 0.02
    )
    assert inside >= 0.98 * len(cands)


@pytest.mark.parametrize("region", REGIONS)
def test_some_area_anchors_have_real_rings(region):
    cands = extract.load_candidates(region)
    areas = [c for c in cands if c.is_area]
    assert areas, "FR108 needs at least one polygon anchor per region"
    assert any(len(c.ring) >= 3 for c in areas), "at least one reconstructed ring"


def test_missing_region_raises():
    with pytest.raises(FileNotFoundError):
        extract.load_candidates("nonexistent")
