"""`plotlines-sidecar`'s argument contract and its refusals.

#235 B3. `plotlines_service/__main__.py` shipped at 0% coverage. Most of it is
uvicorn wiring, but it also holds guards that exist nowhere else — above all
ARCH §7.1's trust boundary:

    if args.mode == "sidecar" and args.host != "127.0.0.1": return 2

`create_app` has no equivalent check, so those three lines are the only thing
standing between the sidecar and a routable interface. They are also ordinary
unit-testable code: `parse_args` and `main` both take `argv`, and every refusal
returns before uvicorn is constructed.

`main` is only ever driven here down paths that return before `server.run()`.
The one test that reaches the server stubs it, because starting uvicorn is
integration territory and `test_health.py` already covers the app itself.
"""

from __future__ import annotations

import pytest

from plotlines_service import __main__ as entry
from plotlines_service.version import VERSION


def _args(*argv: str):
    return entry.parse_args(list(argv))


# ── the spawn contract (ARCH §7.3) ───────────────────────────────────────


def test_the_documented_spawn_line_parses():
    """The invocation M12's `sidecar_manager` actually builds."""
    args = _args("--port=52111", "--host=127.0.0.1", "--mode=sidecar",
                 "--cache-dir=/tmp/plotlines")

    assert args.port == 52111
    assert args.host == "127.0.0.1"
    assert args.mode == "sidecar"
    assert str(args.cache_dir) == "/tmp/plotlines"


def test_the_defaults_are_the_sidecar_posture():
    """Loopback, sidecar mode, OS-assigned port — the safe shape when the client
    passes nothing but a cache dir."""
    args = _args("--cache-dir=/tmp/plotlines")

    assert args.host == "127.0.0.1"
    assert args.mode == "sidecar"
    assert args.port == 0
    assert args.allow_unmirrored_tiles is False
    assert args.web_domain is None
    assert args.log_level == "info"


def test_a_cache_dir_is_required_for_a_real_run():
    """Without one the sidecar has nowhere to put per-region graph and tile
    caches, so this fails at parse rather than half-starting."""
    with pytest.raises(SystemExit):
        _args("--port=52111")


def test_version_is_the_one_call_that_needs_no_cache_dir():
    """"The client runs `--version` to perform the A8 version check *before* it
    has spawned anything or chosen a cache dir." """
    assert _args("--version").version is True


def test_an_unknown_mode_is_refused_at_parse():
    with pytest.raises(SystemExit):
        _args("--mode=public", "--cache-dir=/tmp/plotlines")


def test_an_unknown_log_level_is_refused_at_parse():
    with pytest.raises(SystemExit):
        _args("--log-level=chatty", "--cache-dir=/tmp/plotlines")


# ── `--version` short-circuits everything ────────────────────────────────


def test_version_prints_the_stamp_and_exits_zero(capsys):
    """This is half of M12's paired-version check: the client compares this
    string against its own before it trusts the binary it just spawned."""
    assert entry.main(["--version"]) == 0
    assert capsys.readouterr().out.strip() == VERSION


def test_version_does_not_build_an_app_or_touch_the_disk(monkeypatch, capsys):
    """It runs before a cache dir has been chosen, so it must not need one."""
    def fail(*_a, **_k):
        raise AssertionError("--version must not construct the app")

    monkeypatch.setattr(entry, "create_app", fail)
    monkeypatch.setattr(entry, "configure_logging", fail)

    assert entry.main(["--version"]) == 0
    capsys.readouterr()


# ── ARCH §7.1 — sidecar mode binds loopback only ─────────────────────────


@pytest.mark.parametrize("host", [
    "0.0.0.0", "::", "192.168.1.10", "localhost", "10.0.0.5", "0.0.0.0.",
])
def test_sidecar_mode_refuses_any_host_but_loopback(host, tmp_path, capsys):
    """The trust boundary, and the only place it is enforced. `localhost` is
    refused too: it resolves per-machine and can carry `::` or a hosts-file
    entry, so the literal is the contract.
    """
    code = entry.main([f"--host={host}", "--mode=sidecar", f"--cache-dir={tmp_path}"])

    assert code == 2
    assert "loopback only" in capsys.readouterr().err


def test_the_refusal_happens_before_anything_is_built(monkeypatch, tmp_path, capsys):
    """A refused launch must not have created an app, opened a log file, or
    bound a socket first."""
    def fail(*_a, **_k):
        raise AssertionError("refused launch reached the app")

    monkeypatch.setattr(entry, "create_app", fail)
    monkeypatch.setattr(entry, "configure_logging", fail)

    assert entry.main([f"--host=0.0.0.0", "--mode=sidecar",
                       f"--cache-dir={tmp_path}"]) == 2
    capsys.readouterr()


def test_loopback_is_accepted(monkeypatch, tmp_path):
    """The other half of the guard — it must not refuse the shipped path."""
    monkeypatch.setattr(entry, "create_app", lambda **_k: object())
    monkeypatch.setattr(entry, "configure_logging", lambda *_a: None)
    started = {}

    class _Server:
        def __init__(self, config):
            started["config"] = config

        def run(self):
            started["ran"] = True

    monkeypatch.setattr(entry.uvicorn, "Config",
                        lambda app, **kwargs: {"app": app, **kwargs})
    monkeypatch.setattr(entry.uvicorn, "Server", _Server)

    assert entry.main([f"--cache-dir={tmp_path}", "--host=127.0.0.1",
                       "--port=52111"]) == 0
    assert started["ran"] is True
    assert started["config"]["host"] == "127.0.0.1"
    assert started["config"]["port"] == 52111


def test_hosted_mode_may_bind_a_non_loopback_host(monkeypatch, tmp_path):
    """The guard is scoped to sidecar mode — a hosted deployment binds where its
    platform tells it to."""
    monkeypatch.setattr(entry, "create_app", lambda **_k: object())
    monkeypatch.setattr(entry, "configure_logging", lambda *_a: None)
    monkeypatch.setattr(entry.uvicorn, "Config", lambda app, **kwargs: kwargs)
    monkeypatch.setattr(entry.uvicorn, "Server",
                        lambda config: type("S", (), {"run": lambda self: None})())

    assert entry.main([f"--cache-dir={tmp_path}", "--mode=hosted",
                       "--host=0.0.0.0", "--web-domain=plotlines.app"]) == 0


# ── M4 — hosted mode requires a same-site parent domain ──────────────────


def test_hosted_mode_without_a_web_domain_is_refused(tmp_path, capsys):
    """ARCH §10.3 / story M4. `create_app` refuses this too (covered by
    `test_web_auth_samesite.py`); this is the earlier, cheaper refusal that
    keeps the process from starting at all."""
    code = entry.main(["--mode=hosted", f"--cache-dir={tmp_path}"])

    assert code == 2
    assert "--web-domain" in capsys.readouterr().err


def test_a_public_suffix_domain_is_refused_with_the_apps_own_reason(monkeypatch,
                                                                    tmp_path, capsys):
    """`create_app` raises `ValueError` for `*.onrender.com`-shaped hosts; the
    entrypoint turns that into an exit code and a line on stderr rather than a
    traceback."""
    def refuse(**_kwargs):
        raise ValueError("onrender.com is a public suffix")

    monkeypatch.setattr(entry, "create_app", refuse)
    monkeypatch.setattr(entry, "configure_logging", lambda *_a: None)

    code = entry.main(["--mode=hosted", "--web-domain=onrender.com",
                       f"--cache-dir={tmp_path}"])

    assert code == 2
    err = capsys.readouterr().err
    assert err.startswith("refusing:")
    assert "public suffix" in err


# ── logging destination (issue #232) ─────────────────────────────────────


def test_the_log_defaults_to_the_cache_dirs_own_tree(monkeypatch, tmp_path):
    """"the same app-support tree the client already knows" — so a support
    request can name one path."""
    seen = {}
    monkeypatch.setattr(entry, "configure_logging",
                        lambda target, level: seen.update(target=target, level=level))
    monkeypatch.setattr(entry, "create_app", lambda **_k: object())
    monkeypatch.setattr(entry.uvicorn, "Config", lambda app, **kwargs: kwargs)
    monkeypatch.setattr(entry.uvicorn, "Server",
                        lambda config: type("S", (), {"run": lambda self: None})())

    entry.main([f"--cache-dir={tmp_path}"])

    assert seen["target"] == entry.default_log_file(tmp_path)
    assert seen["level"] == "info"


def test_a_dash_means_stderr_only(monkeypatch, tmp_path):
    """A frozen sidecar run from a terminal should be able to opt out of the
    rotating file without inventing a path to discard."""
    seen = {}
    monkeypatch.setattr(entry, "configure_logging",
                        lambda target, level: seen.update(target=target))
    monkeypatch.setattr(entry, "create_app", lambda **_k: object())
    monkeypatch.setattr(entry.uvicorn, "Config", lambda app, **kwargs: kwargs)
    monkeypatch.setattr(entry.uvicorn, "Server",
                        lambda config: type("S", (), {"run": lambda self: None})())

    entry.main([f"--cache-dir={tmp_path}", "--log-file=-"])

    assert seen["target"] is None


def test_an_explicit_log_file_wins_over_the_default(monkeypatch, tmp_path):
    seen = {}
    monkeypatch.setattr(entry, "configure_logging",
                        lambda target, level: seen.update(target=target))
    monkeypatch.setattr(entry, "create_app", lambda **_k: object())
    monkeypatch.setattr(entry.uvicorn, "Config", lambda app, **kwargs: kwargs)
    monkeypatch.setattr(entry.uvicorn, "Server",
                        lambda config: type("S", (), {"run": lambda self: None})())

    entry.main([f"--cache-dir={tmp_path}", f"--log-file={tmp_path / 'x.log'}"])

    assert str(seen["target"]) == str(tmp_path / "x.log")


def test_the_log_level_drives_uvicorn_too(monkeypatch, tmp_path):
    """One flag, both loggers — otherwise a `--log-level=debug` support run
    still hides the request that failed."""
    monkeypatch.setattr(entry, "configure_logging", lambda *_a: None)
    monkeypatch.setattr(entry, "create_app", lambda **_k: object())
    config = {}
    monkeypatch.setattr(entry.uvicorn, "Config",
                        lambda app, **kwargs: config.update(kwargs) or kwargs)
    monkeypatch.setattr(entry.uvicorn, "Server",
                        lambda cfg: type("S", (), {"run": lambda self: None})())

    entry.main([f"--cache-dir={tmp_path}", "--log-level=debug"])

    assert config["log_level"] == "debug"
    assert config["access_log"] is False


# ── the tile-source refusal (FR92/FR95) is passed through, not re-decided ──


def test_the_tile_flags_reach_create_app_unchanged(monkeypatch, tmp_path):
    """`tiles.mirror` owns the hotlink-refusal policy; the entrypoint's job is
    only to hand it what the operator asked for."""
    seen = {}
    monkeypatch.setattr(entry, "configure_logging", lambda *_a: None)
    monkeypatch.setattr(entry, "create_app",
                        lambda **kwargs: seen.update(kwargs) or object())
    monkeypatch.setattr(entry.uvicorn, "Config", lambda app, **kwargs: kwargs)
    monkeypatch.setattr(entry.uvicorn, "Server",
                        lambda config: type("S", (), {"run": lambda self: None})())

    entry.main([f"--cache-dir={tmp_path}",
                "--tiles-upstream=https://example.invalid/a.pmtiles",
                "--allow-unmirrored-tiles"])

    assert seen["tiles_upstream"] == "https://example.invalid/a.pmtiles"
    assert seen["allow_unmirrored_tiles"] is True
    assert seen["mode"] == "sidecar"


# ── graceful stop (ARCH §7.3) ────────────────────────────────────────────


def test_sigterm_asks_the_server_to_exit_rather_than_killing_it(monkeypatch, tmp_path):
    """"SIGTERM → graceful shutdown". uvicorn installs its own handler; this one
    is explicit so a frozen binary behaves the same as a source run."""
    import signal as signal_mod

    monkeypatch.setattr(entry, "configure_logging", lambda *_a: None)
    monkeypatch.setattr(entry, "create_app", lambda **_k: object())

    class _Server:
        def __init__(self, _config):
            self.should_exit = False

        def run(self):
            pass

    server_holder = {}

    def _make_server(config):
        server_holder["server"] = _Server(config)
        return server_holder["server"]

    monkeypatch.setattr(entry.uvicorn, "Config", lambda app, **kwargs: kwargs)
    monkeypatch.setattr(entry.uvicorn, "Server", _make_server)

    handlers = {}
    monkeypatch.setattr(signal_mod, "signal",
                        lambda sig, handler: handlers.__setitem__(sig, handler))

    entry.main([f"--cache-dir={tmp_path}"])

    assert signal_mod.SIGTERM in handlers
    handlers[signal_mod.SIGTERM](signal_mod.SIGTERM, None)
    assert server_holder["server"].should_exit is True
