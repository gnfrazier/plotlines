"""Shared fixtures for the core suite."""

from __future__ import annotations

import pytest

from plotlines_core.graph import regions


@pytest.fixture
def public_overpass():
    """Opt one test into the public Overpass fallback (issue #284 refuses it
    by default). For tests of the Overpass transport's own mechanics, never
    a module-wide default: the refusal is what the rest of the suite runs
    under."""
    regions.allow_public_overpass(True)
    try:
        yield
    finally:
        regions.allow_public_overpass(False)
