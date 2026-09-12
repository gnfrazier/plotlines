"""The `/clip` channel's ODbL notice — issue #364, closing the one
definition-of-done bullet of epic #264 that #262/#263 left open:

    Every served payload carries its licence notice, and nothing is served
    whose terms are unverified.

The mirror's *static* payloads satisfy that through `COPYRIGHT.txt`, which
`build_tree.sh` installs and `test_mirror_deploy_config.py` asserts present.
`/clip` bypasses that entirely by design — `deploy/mirror/Caddyfile`'s
`reverse_proxy /clip*` matcher terminates the request before `file_server`
ever runs — so a consumer that only ever calls `/clip` receives an
OSM-derived database and never sees the notice. A clip is an *extraction*,
so its output is a Derivative Database under ODbL (§4.3), not a Produced
Work like the basemap archive.

These tests fail against the pre-#364 code, where the response carried five
`X-Plotlines-Clip-*` metadata headers and no licence of any kind.
"""

from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient

from mirror_clip_fixtures import build_mirror_tree, node, write_pbf

from plotlines_service.mirror_clip import (
    CLIP_ATTRIBUTION,
    CLIP_ATTRIBUTION_HEADER,
    CLIP_LICENCE_ID,
    CLIP_LICENCE_URL,
    CLIP_TERMS_URL,
    clip_licence_headers,
    create_clip_app,
)

_BBOX = {"west": -82.6, "south": 34.9, "east": -81.9, "north": 35.6}

_OSM_COPYRIGHT = (
    Path(__file__).resolve().parents[2] / "deploy" / "mirror" / "osm" / "COPYRIGHT.txt"
).read_text()


def _mirror_with_one_region(tmp_path: Path) -> Path:
    src = write_pbf(
        tmp_path / "src.osm.pbf",
        nodes=[node(1, -82.2, 35.2, {"natural": "peak", "name": "Test Peak"})],
        box=(-83.0, 34.0, -81.0, 36.0),
    )
    return build_mirror_tree(tmp_path / "mirror", regions={"the-region": src})


# --------------------------------------------------------------------------
# The notice reaches the caller
# --------------------------------------------------------------------------


def test_get_clip_carries_the_odbl_notice(tmp_path: Path) -> None:
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(create_clip_app(mirror, tmp_dir=tmp_path / "scratch"))

    resp = tc.get("/clip", params=_BBOX)

    assert resp.status_code == 200
    assert resp.headers["x-plotlines-data-licence"] == CLIP_LICENCE_ID
    assert resp.headers["x-plotlines-data-attribution"] == CLIP_ATTRIBUTION_HEADER
    assert resp.headers["x-plotlines-data-terms"] == CLIP_TERMS_URL


def test_post_clip_carries_the_same_notice_as_get(tmp_path: Path) -> None:
    # Two entry points, one obligation — the notice cannot be wired onto the
    # query-param route and missed on the JSON-body one.
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(create_clip_app(mirror, tmp_dir=tmp_path / "scratch"))

    get_resp = tc.get("/clip", params=_BBOX)
    post_resp = tc.post("/clip", json=_BBOX)

    for header in clip_licence_headers():
        assert post_resp.headers[header] == get_resp.headers[header]


def test_clip_carries_a_standard_rel_license_link(tmp_path: Path) -> None:
    # RFC 8288's registered relation, so an auditor or a generic HTTP tool
    # finds the licence without knowing the X-Plotlines-* convention exists.
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(create_clip_app(mirror, tmp_dir=tmp_path / "scratch"))

    resp = tc.get("/clip", params=_BBOX)

    assert resp.headers["link"] == f'<{CLIP_LICENCE_URL}>; rel="license"'


def test_every_notice_header_value_is_ascii(tmp_path: Path) -> None:
    # Regression for a defect in #364's own first cut, which put the
    # canonical "© OpenStreetMap contributors" straight into the header.
    # Starlette emits header values as latin-1, so U+00A9 goes out as the
    # bare byte 0xA9 — not valid UTF-8 — and a client decoding headers as
    # UTF-8 raises before it ever sees the body. Every clip became a hard
    # failure at the transport layer, which is a far worse outcome than the
    # missing notice this issue set out to fix. The invariant is the
    # character set, not the one glyph: assert it over every value so the
    # next reword (an em dash in a terms URL, a curly apostrophe) cannot
    # reintroduce it.
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(create_clip_app(mirror, tmp_dir=tmp_path / "scratch"))

    for name, value in clip_licence_headers().items():
        assert value.isascii(), f"{name} is not US-ASCII: {value!r}"

    # And prove it end to end — decoding the response headers at all is the
    # assertion; the pre-fix code raised UnicodeDecodeError right here.
    resp = tc.get("/clip", params=_BBOX)
    assert resp.headers["x-plotlines-data-attribution"] == CLIP_ATTRIBUTION_HEADER


def test_the_header_credit_is_the_canonical_one_transliterated(tmp_path: Path) -> None:
    # The ASCII header form and the typographic form `/health` and
    # COPYRIGHT.txt carry must stay the same credit — only the © differs.
    assert CLIP_ATTRIBUTION_HEADER == CLIP_ATTRIBUTION.replace("©", "(c)")


def test_the_notice_does_not_displace_the_clip_metadata_headers(tmp_path: Path) -> None:
    # #364 adds to the response; it must not shadow what #262 measured with.
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(create_clip_app(mirror, tmp_dir=tmp_path / "scratch"))

    resp = tc.get("/clip", params=_BBOX)

    assert int(resp.headers["x-plotlines-clip-output-bytes"]) == len(resp.content)
    assert resp.headers["x-plotlines-clip-source-regions"] == "the-region"
    assert "x-plotlines-clip-wall-time-ms" in resp.headers


# --------------------------------------------------------------------------
# The notice cannot drift from the tree's own COPYRIGHT.txt
# --------------------------------------------------------------------------


def test_licence_id_matches_the_osm_copyright_file() -> None:
    # osm/COPYRIGHT.txt spells the same licence "ODbL 1.0"; the header uses
    # the SPDX id. Assert the spelling that file actually contains rather
    # than the SPDX form, so this pins the two together without asserting a
    # string the file does not carry.
    assert "ODbL 1.0" in _OSM_COPYRIGHT
    assert CLIP_LICENCE_ID == "ODbL-1.0"


def test_attribution_matches_the_osm_copyright_file() -> None:
    assert CLIP_ATTRIBUTION in _OSM_COPYRIGHT


def test_terms_and_licence_urls_match_the_osm_copyright_file() -> None:
    # Both URLs the file names: the ODbL text itself, and OSM's copyright
    # page. A reword that drops either from the file should fail here rather
    # than leave the channel notice pointing somewhere the tree does not.
    assert CLIP_TERMS_URL in _OSM_COPYRIGHT
    assert CLIP_LICENCE_URL in _OSM_COPYRIGHT


# --------------------------------------------------------------------------
# /health states the obligation
# --------------------------------------------------------------------------


def test_health_reports_the_licence_of_what_it_serves(tmp_path: Path) -> None:
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(create_clip_app(mirror, tmp_dir=tmp_path / "scratch"))

    licence = tc.get("/health").json()["licence"]

    assert licence == {
        "licence": CLIP_LICENCE_ID,
        "attribution": CLIP_ATTRIBUTION,
        "terms_url": CLIP_TERMS_URL,
        "licence_url": CLIP_LICENCE_URL,
    }
