"""Pi5 QA/UAT elevation proxy deployment — issue #450, companion to #304
(which built `service/plotlines_service/elevation_proxy.py` but never its
deployment) and to `test_mirror_deploy_config.py`/
`test_mirror_clip_deploy_config.py` (#256/#257/#262): same "guard the
checked-in file against a regression that would only show up live on the
Pi" reasoning, scoped to `deploy/elevation/`. See `deploy/elevation/README.md`
for how this was also exercised end to end on the real Pi.
"""

from __future__ import annotations

from pathlib import Path

from plotlines_core.elevation.keys import API_KEY_ENV, KEY_TIER_ENV

_ELEVATION_DIR = Path(__file__).resolve().parents[2] / "deploy" / "elevation"
_CADDYFILE = (_ELEVATION_DIR / "Caddyfile").read_text()
_COMPOSE = (_ELEVATION_DIR / "docker-compose.yml").read_text()
_ENV_EXAMPLE = (_ELEVATION_DIR / ".env.example").read_text()


def _strip_comment_lines(text: str, *, prefix: str) -> str:
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith(prefix)
    )


_CADDYFILE_CONFIG = _strip_comment_lines(_CADDYFILE, prefix="##")
_COMPOSE_CONFIG = _strip_comment_lines(_COMPOSE, prefix="#")


def test_caddyfile_is_a_bare_port_address_never_a_public_hostname() -> None:
    # LAN-only, no public DNS record (issue #450's own acceptance
    # criteria) — a bare `:PORT` address has no domain name for Caddy to
    # attempt ACME against, unlike the mirror Caddyfile's `http://<host>`.
    assert ":{$ELEVATION_PORT:8090} {" in _CADDYFILE
    assert "http://" not in _CADDYFILE_CONFIG


def test_caddyfile_proxies_to_the_compose_service_name_on_the_dockerfiles_port() -> None:
    # service/Dockerfile.elevation-proxy's CMD binds --port 8090 by default;
    # a drift between that and what Caddy proxies to would 502 silently.
    assert "reverse_proxy elevation-proxy:8090" in _CADDYFILE_CONFIG


def test_caddyfile_logs_access() -> None:
    assert "log {" in _CADDYFILE
    assert "output file" in _CADDYFILE


def test_caddyfile_is_a_separate_site_block_from_the_mirror() -> None:
    # #304's own "Done when": separate hostname/port from tiles.plotlines.app
    # — the ToS/key-revocation risk profile differs from the mirror's ODbL
    # redistribution risk, so this must not inherit whatever #263 decides
    # about the mirror's reachability.
    assert "tiles.plotlines.app" not in _CADDYFILE
    assert "/clip" not in _CADDYFILE


def test_docker_compose_pins_the_caddy_image() -> None:
    assert "image: caddy:latest" not in _COMPOSE
    assert "image: caddy:" in _COMPOSE
    assert "/etc/caddy/Caddyfile:ro" in _COMPOSE


def test_docker_compose_defines_the_elevation_proxy_service() -> None:
    assert "\n  elevation-proxy:\n" in _COMPOSE_CONFIG
    assert "image: plotlines-elevation-proxy" in _COMPOSE_CONFIG


def test_elevation_proxy_service_publishes_no_host_port() -> None:
    # Only Caddy's reverse_proxy should be able to reach this container —
    # the proxy has no auth of its own (elevation_proxy.py's --host help).
    _, proxy_block = _COMPOSE_CONFIG.split("\n  elevation-proxy:\n", 1)
    assert "ports:" not in proxy_block


def test_elevation_proxy_cache_is_a_named_volume_not_an_srv_bind_mount() -> None:
    # Unlike the mirror's read-only /srv tree, nothing outside this
    # container ever reads the DEM cache directly.
    _, proxy_block = _COMPOSE_CONFIG.split("\n  elevation-proxy:\n", 1)
    assert "/srv/" not in proxy_block
    assert "elevation_cache:/data" in proxy_block


def test_docker_compose_requires_the_real_api_key_env_var() -> None:
    # ${VAR:?msg} fails `docker compose up` immediately with an honest
    # message if the key is unset, ahead of elevation_proxy.py's own
    # startup check. Reads the env var name from keys.py rather than a
    # literal, so a rename there can't silently desync this file.
    assert f"{API_KEY_ENV}=${{{API_KEY_ENV}:?" in _COMPOSE
    assert f"{KEY_TIER_ENV}=${{{KEY_TIER_ENV}:-free-non-academic}}" in _COMPOSE


def test_env_example_names_both_variables_with_blank_values() -> None:
    # Same committed-template-blank-value convention as service/.env.example
    # — the real value is never a literal anywhere in this repo.
    assert f"{API_KEY_ENV}=\n" in _ENV_EXAMPLE
    assert f"{KEY_TIER_ENV}=\n" in _ENV_EXAMPLE


def test_env_example_holds_no_real_looking_key_value() -> None:
    # A cheap guard against someone pasting a real key into the template
    # while editing it by hand — every value-bearing line must end at the
    # `=` with nothing after it.
    for line in _ENV_EXAMPLE.splitlines():
        if line.startswith(("PLOTLINES_OPENTOPOGRAPHY_API_KEY=", "PLOTLINES_OPENTOPOGRAPHY_KEY_TIER=")):
            assert line.endswith("="), f"non-blank template value: {line!r}"
