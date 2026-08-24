"""Layer defaults by (travel mode x day type) — PRD FR97.

"Layer defaults are data, not code" is FR97's own wording. The rule table
lives in `config/layer_defaults.json`; this module only resolves it. Editing
what's live by default is a config change, never a change to this file.
"""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Mapping

_CONFIG_PATH = Path(__file__).parent / "config" / "layer_defaults.json"

_FALLBACK_KEY = "_default"


@lru_cache(maxsize=1)
def _default_config() -> Mapping[str, Mapping[str, list[str]]]:
    raw = json.loads(_CONFIG_PATH.read_text())
    return {k: v for k, v in raw.items() if not k.startswith("_comment")}


def resolve_default_layers(
    mode: str,
    day_type: str,
    config: Mapping[str, Mapping[str, list[str]]] | None = None,
) -> set[str]:
    """The live layer set for a (travel mode, day type) pair.

    Falls back to the config's `_default` entry for a mode this config has
    no row for, and again to an empty set for a day type neither the mode
    nor `_default` names, rather than raising — an unrecognized day type
    should read as "nothing is live yet by default," not a crash the Author
    sees as a bug.
    """
    cfg = config if config is not None else _default_config()
    by_mode = cfg.get(mode) or cfg.get(_FALLBACK_KEY) or {}
    layers = by_mode.get(day_type)
    if layers is None:
        layers = cfg.get(_FALLBACK_KEY, {}).get(day_type, [])
    return set(layers)
