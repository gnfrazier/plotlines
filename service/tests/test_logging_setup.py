"""Issue #232 — sidecar logging configuration."""

from __future__ import annotations

import logging
from pathlib import Path

import pytest

from plotlines_service.logging_setup import configure_logging, default_log_file


@pytest.fixture(autouse=True)
def _restore_root_logger():
    root = logging.getLogger()
    saved_handlers = root.handlers[:]
    saved_level = root.level
    yield
    root.handlers[:] = saved_handlers
    root.setLevel(saved_level)


def test_default_log_file_is_under_the_cache_dir():
    assert default_log_file(Path("/cache")) == Path("/cache/logs/sidecar.log")


def test_stderr_only_when_no_path():
    resolved = configure_logging(None, "info")
    assert resolved is None
    assert any(isinstance(h, logging.StreamHandler) for h in logging.getLogger().handlers)


def test_file_handler_creates_the_parent_dir(tmp_path):
    target = tmp_path / "logs" / "sidecar.log"
    resolved = configure_logging(target, "debug")
    assert resolved == target
    assert target.parent.is_dir()
    logging.getLogger("plotlines.sidecar").info("hello")
    assert target.exists()
    assert "hello" in target.read_text()


def test_level_is_applied(tmp_path):
    configure_logging(tmp_path / "s.log", "warning")
    assert logging.getLogger().level == logging.WARNING
