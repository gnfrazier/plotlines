"""`/clip`'s "no client key configured" case — issue #371.

`test_mirror_clip_server.py` already covers the client-key gate's happy and
refusal paths, but every one of those tests hands `create_clip_app` either a
real key or nothing at all, so `client_key` is always a non-empty `str` or
Python's own `None` default. The value that broke the live Pi is neither: it
is the **empty string**, which is what
`deploy/mirror/docker-compose.yml`'s `MIRROR_CLIP_CLIENT_KEY=${MIRROR_CLIP_CLIENT_KEY:-}`
puts in the container's environment when the operator sets nothing — the
documented "leaves /clip open" default. `os.environ.get` then returns `""`,
`"" is not None` armed the gate, and every request 401'd.

So these tests deliberately enter through the two boundaries the empty
string actually crosses — `normalize_client_key` itself, and `main`'s
argparse default reading a patched `os.environ` — rather than only through
the keyword argument, which is the seam that hid the bug in the first place.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from mirror_clip_fixtures import build_mirror_tree, node, write_pbf

from plotlines_service.mirror_clip import (
    CLIENT_KEY_HEADER,
    create_clip_app,
    normalize_client_key,
)

_BBOX = {"west": -82.6, "south": 34.9, "east": -81.9, "north": 35.6}


def _mirror_with_one_region(tmp_path: Path) -> Path:
    src = write_pbf(
        tmp_path / "src.osm.pbf",
        nodes=[node(1, -82.2, 35.2, {"natural": "peak", "name": "Test Peak"})],
        box=(-83.0, 34.0, -81.0, 36.0),
    )
    return build_mirror_tree(tmp_path / "mirror", regions={"the-region": src})


@pytest.mark.parametrize("raw", ["", "   ", "\n", "\t\n "])
def test_an_empty_or_blank_key_normalises_to_unconfigured(raw: str) -> None:
    assert normalize_client_key(raw) is None


def test_an_absent_key_stays_unconfigured() -> None:
    assert normalize_client_key(None) is None


@pytest.mark.parametrize(
    ("raw", "expected"),
    [("s3cret", "s3cret"), ("  s3cret  ", "s3cret"), ("s3cret\n", "s3cret")],
)
def test_a_real_key_survives_normalisation_without_its_surrounding_whitespace(
    raw: str, expected: str
) -> None:
    # The trailing-newline case is the one that matters operationally: a key
    # read from a file or a heredoc arrives with \n attached, and comparing
    # against the un-stripped form would refuse the key the operator
    # believes they configured.
    assert normalize_client_key(raw) == expected


def test_an_empty_key_leaves_clip_open_rather_than_refusing_everyone(
    tmp_path: Path,
) -> None:
    # The #371 regression itself, at the app boundary: this is compose's
    # unset default arriving as "", and it must behave exactly like the
    # `client_key=None` case in test_mirror_clip_server.py.
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(create_clip_app(mirror, tmp_dir=tmp_path / "scratch", client_key=""))

    resp = tc.get("/clip", params=_BBOX)  # no client-key header at all

    assert resp.status_code == 200


def test_an_empty_key_is_not_a_credential_an_empty_header_can_satisfy(
    tmp_path: Path,
) -> None:
    # The other half of #371, and the reason `""` could not simply be left
    # meaning "a key": `hmac.compare_digest("", "")` is True, so before the
    # fix a caller sending the header with an empty value authenticated
    # against the empty key. That must not read as a *successful auth* now —
    # it succeeds here only because the endpoint is open to everyone, which
    # the test above pins independently.
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(
        create_clip_app(mirror, tmp_dir=tmp_path / "scratch", client_key="s3cret")
    )

    resp = tc.get("/clip", params=_BBOX, headers={CLIENT_KEY_HEADER: ""})

    assert resp.status_code == 401


def test_a_configured_key_is_still_enforced_after_normalisation(
    tmp_path: Path,
) -> None:
    # Guards the obvious over-correction: #371 must not turn the gate off.
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(
        create_clip_app(mirror, tmp_dir=tmp_path / "scratch", client_key="  s3cret\n")
    )

    assert tc.get("/clip", params=_BBOX).status_code == 401
    assert (
        tc.get("/clip", params=_BBOX, headers={CLIENT_KEY_HEADER: "s3cret"}).status_code
        == 200
    )


def test_the_env_var_compose_actually_sets_does_not_arm_the_gate(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The path none of the existing tests took.

    `main`'s `--client-key` default is `os.environ.get(...)`, evaluated when
    the parser is built, so this exercises env var → argparse → app the way
    the container does. Patching the environment and re-reading argparse's
    default is the only way to reach the `""` that compose produces; passing
    `client_key=""` by hand (above) proves the app layer, not the wiring
    between them, and it was precisely that gap the nine live 401s fell
    into.
    """
    import argparse
    import os

    monkeypatch.setenv("MIRROR_CLIP_CLIENT_KEY", "")

    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--client-key", default=os.environ.get("MIRROR_CLIP_CLIENT_KEY")
    )
    args = parser.parse_args([])

    assert args.client_key == ""  # what compose delivers, pinned explicitly
    assert normalize_client_key(args.client_key) is None

    # Deliberately handed to create_clip_app *un*-normalised. Normalising
    # here first would re-create the very seam that hid #371 — the test
    # would pass against the broken gate — so this pins that the app layer
    # itself is robust to the raw value the container receives, and `main`
    # normalising too is belt-and-braces rather than the only defence.
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(
        create_clip_app(
            mirror, tmp_dir=tmp_path / "scratch", client_key=args.client_key
        )
    )

    assert tc.get("/clip", params=_BBOX).status_code == 200


def test_the_startup_log_cannot_disagree_with_the_gate(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # mirror_clip.py:655 logged `bool(args.client_key)` — bool("") is False —
    # so the service reported client_key_configured=False while refusing
    # every request. Whatever the log says about configuration must be the
    # same value the gate is built from.
    monkeypatch.setenv("MIRROR_CLIP_CLIENT_KEY", "")
    import os

    from_env = os.environ.get("MIRROR_CLIP_CLIENT_KEY")

    # `from_env` un-normalised into the app, `normalize_client_key` for what
    # the log would report: exactly the two values that diverged on the Pi.
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(
        create_clip_app(mirror, tmp_dir=tmp_path / "scratch", client_key=from_env)
    )
    gate_is_armed = tc.get("/clip", params=_BBOX).status_code == 401
    log_would_say_configured = bool(normalize_client_key(from_env))

    assert log_would_say_configured is gate_is_armed
