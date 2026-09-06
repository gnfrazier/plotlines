"""Phase 1.2 mirror tree and Caddy config — issue #256, companion to epic
#264, not #148. `deploy/mirror/` is deployed to the Pi5 mirror host; these
tests guard the checked-in `Caddyfile`, `docker-compose.yml`, and
`build_tree.sh` against regressions that would only show up live on the Pi
— see `deploy/mirror/README.md` for how this was also exercised end to end
against a real Caddy binary.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

from plotlines_core.tiles.mirror import MIRROR_HOST

_MIRROR_DIR = Path(__file__).resolve().parents[2] / "deploy" / "mirror"
_CADDYFILE = (_MIRROR_DIR / "Caddyfile").read_text()
_COMPOSE = (_MIRROR_DIR / "docker-compose.yml").read_text()
# The Caddyfile's own header comments explain the encode/http.server
# pitfalls by name — strip `##` lines so the checks below assert on the
# active config, not on the prose warning about what not to do.
_CADDYFILE_CONFIG = "\n".join(
    line for line in _CADDYFILE.splitlines() if not line.lstrip().startswith("##")
)


def test_caddyfile_uses_http_scheme_and_the_mirror_host() -> None:
    # §6.4: without the http:// prefix Caddy attempts ACME for a domain it
    # cannot validate and fails to start. The host must match the same
    # MIRROR_HOST core's classify_upstream matches on (§6.5), not a literal
    # that can drift from it.
    assert f"http://{MIRROR_HOST} {{" in _CADDYFILE


def test_caddyfile_never_compresses() -> None:
    # .pmtiles/.osm.pbf are already compressed; on-the-fly compression
    # breaks the byte-range semantics http_range_source needs.
    assert "encode" not in _CADDYFILE_CONFIG


def test_caddyfile_never_runs_as_a_bare_http_server() -> None:
    assert "http.server" not in _CADDYFILE_CONFIG


@pytest.mark.parametrize("path_prefix", ["/basemap/*", "/osm/*"])
def test_caddyfile_sets_immutable_cache_headers(path_prefix: str) -> None:
    assert f"header {path_prefix}" in _CADDYFILE
    assert 'Cache-Control "public, max-age=31536000, immutable"' in _CADDYFILE


def test_caddyfile_logs_access() -> None:
    assert "log {" in _CADDYFILE
    assert "output file" in _CADDYFILE


def test_caddyfile_root_and_log_default_to_the_production_paths() -> None:
    # {$VAR:default} lets a local run point at a scratch tree without
    # editing this file; an unset var must still resolve to exactly the
    # production path (§6.3) so the checked-in default is production-correct.
    assert "{$MIRROR_ROOT:/srv/plotlines-mirror}" in _CADDYFILE
    assert "{$MIRROR_LOG:/var/log/caddy/mirror.log}" in _CADDYFILE


def test_docker_compose_pins_the_caddy_image_and_mounts_read_only() -> None:
    assert "image: caddy:latest" not in _COMPOSE
    assert "image: caddy:" in _COMPOSE
    assert "/etc/caddy/Caddyfile:ro" in _COMPOSE
    assert "/srv/plotlines-mirror:ro" in _COMPOSE


def test_index_v1_json_is_never_mentioned_as_something_we_serve() -> None:
    # Finding L4: Geofabrik's index-v1.json licence is unverified as of this
    # issue (see deploy/mirror/README.md). Nothing here should reference it
    # as a served path.
    assert "index-v1.json" not in _CADDYFILE
    assert "index-v1.json" not in _COMPOSE


class TestBuildTree:
    """Exercises deploy/mirror/build_tree.sh against a scratch directory —
    never touches /srv."""

    def _run(self, root: Path) -> None:
        subprocess.run(
            [str(_MIRROR_DIR / "build_tree.sh"), str(root)],
            check=True,
            capture_output=True,
            text=True,
        )

    def test_scaffolds_the_section_6_3_layout(self, tmp_path: Path) -> None:
        root = tmp_path / "mirror"
        self._run(root)

        assert (root / "COPYRIGHT.txt").is_file()
        assert (root / "osm" / "COPYRIGHT.txt").is_file()
        assert (root / "basemap" / "protomaps").is_dir()
        assert (root / "osm" / "geofabrik").is_dir()
        assert (root / "MIRROR_STATE.json").is_file()

    def test_never_creates_index_v1_json(self, tmp_path: Path) -> None:
        root = tmp_path / "mirror"
        self._run(root)

        assert not list(root.rglob("index-v1.json"))

    def test_mirror_state_json_is_valid_and_documents_the_l4_decision(
        self, tmp_path: Path
    ) -> None:
        root = tmp_path / "mirror"
        self._run(root)

        state = json.loads((root / "MIRROR_STATE.json").read_text())
        assert "geofabrik" in state
        assert "basemap" in state

    def test_rerun_does_not_clobber_existing_mirror_state(self, tmp_path: Path) -> None:
        # MIRROR_STATE.json's real content belongs to the sync client
        # (#258/#260) and the basemap copy step (#257) — re-running the
        # scaffold (e.g. on a redeploy) must never wipe pull state.
        root = tmp_path / "mirror"
        self._run(root)

        real_state = {"schema_version": 1, "geofabrik": {"regions": {"nc": "2026-09-01"}}}
        (root / "MIRROR_STATE.json").write_text(json.dumps(real_state))

        self._run(root)

        assert json.loads((root / "MIRROR_STATE.json").read_text()) == real_state

    def test_rerun_refreshes_the_licence_files(self, tmp_path: Path) -> None:
        # The COPYRIGHT.txt files are Plotlines' own static content, unlike
        # MIRROR_STATE.json — a redeploy should pick up any wording fix.
        root = tmp_path / "mirror"
        self._run(root)
        (root / "COPYRIGHT.txt").write_text("stale")

        self._run(root)

        assert (root / "COPYRIGHT.txt").read_text() != "stale"

    def test_defaults_to_srv_plotlines_mirror(self) -> None:
        assert "ROOT=\"${1:-/srv/plotlines-mirror}\"" in (
            _MIRROR_DIR / "build_tree.sh"
        ).read_text()
