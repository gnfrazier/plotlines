"""Deploy-tree wiring for the mirror-side clip — issue #262 (Phase 1.8 of
epic #264, §6.7). Companion to `test_mirror_deploy_config.py` (#256/#257):
same "guard the checked-in file against a regression that would only show
up live on the Pi" reasoning, scoped to what #262 added — the Caddy
`/clip*` route, the `mirror-clip` compose service, and
`Dockerfile.mirror-clip`'s no-GPL-binary posture (addendum L1).
"""

from __future__ import annotations

from pathlib import Path

_MIRROR_DIR = Path(__file__).resolve().parents[2] / "deploy" / "mirror"
_SERVICE_DIR = Path(__file__).resolve().parents[1]
_CADDYFILE = (_MIRROR_DIR / "Caddyfile").read_text()
_COMPOSE = (_MIRROR_DIR / "docker-compose.yml").read_text()
_DOCKERFILE = (_SERVICE_DIR / "Dockerfile.mirror-clip").read_text()


def _strip_comment_lines(text: str, *, prefix: str) -> str:
    # Both files' own header comments *name* the things to avoid (the
    # Caddyfile's directive-ordering explanation says "file_server"; the
    # Dockerfile's says "osmium-tool"/"--workers") — the same reason
    # test_mirror_deploy_config.py strips `##` lines before asserting on
    # the active config rather than the prose warning about it.
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith(prefix)
    )


_CADDYFILE_CONFIG = _strip_comment_lines(_CADDYFILE, prefix="##")
_COMPOSE_CONFIG = _strip_comment_lines(_COMPOSE, prefix="#")
_DOCKERFILE_CONFIG = _strip_comment_lines(_DOCKERFILE, prefix="#")


def test_caddyfile_proxies_clip_before_the_static_file_server() -> None:
    # reverse_proxy's own path matcher must run — and therefore be written
    # — ahead of the bare file_server catch-all, or a /clip request would
    # be served (or 404'd) as a static file lookup instead of reaching the
    # clip service.
    proxy_at = _CADDYFILE_CONFIG.index("reverse_proxy /clip*")
    file_server_at = _CADDYFILE_CONFIG.index("file_server")
    assert proxy_at < file_server_at


def test_caddyfile_clip_upstream_defaults_to_the_compose_service_name() -> None:
    assert "{$MIRROR_CLIP_UPSTREAM:mirror-clip:8095}" in _CADDYFILE


def test_docker_compose_defines_the_mirror_clip_service() -> None:
    assert "\n  mirror-clip:\n" in _COMPOSE_CONFIG
    assert "image: plotlines-mirror-clip" in _COMPOSE_CONFIG
    _, clip_block = _COMPOSE_CONFIG.split("\n  mirror-clip:\n", 1)
    assert "/srv/plotlines-mirror:ro" in clip_block


def test_mirror_clip_service_publishes_no_host_port() -> None:
    # Only Caddy's reverse_proxy should be able to reach this container
    # directly — #263's client-key/rate-limit gate (mirror_clip.py's
    # --client-key argparse help) is this service's own access control,
    # but it's still a second layer on top of "nothing else can dial in."
    _, clip_block = _COMPOSE_CONFIG.split("\n  mirror-clip:\n", 1)
    assert "ports:" not in clip_block


def test_dockerfile_installs_pyosmium_extra_never_the_gpl_cli() -> None:
    # Addendum L1: pyosmium (BSD-2-Clause) via the `mirror-clip` extra,
    # never `osmium-tool` (GPL-3.0) via apt or pip.
    assert "--extra mirror-clip" in _DOCKERFILE_CONFIG
    assert "osmium-tool" not in _DOCKERFILE_CONFIG
    assert "apt-get" not in _DOCKERFILE_CONFIG


def test_dockerfile_runs_a_single_worker() -> None:
    assert "--workers" not in _DOCKERFILE_CONFIG
