"""The layers the mirror's fill worker knows how to fill (ARCH D67) — the
one place `--fill-layers` names resolve. #517 ships the contract with no
layer; #518 (OSM), #519 (basemap) register theirs here."""

from __future__ import annotations

from pathlib import Path
from typing import Callable

from .mirror_fill import LayerFiller

#: layer name -> factory(root) -> LayerFiller
FILLER_FACTORIES: dict[str, Callable[[Path], LayerFiller]] = {}


def build_fillers(names: str, *, root: Path) -> list[LayerFiller]:
    wanted = [n.strip() for n in names.split(",") if n.strip()]
    unknown = [n for n in wanted if n not in FILLER_FACTORIES]
    if unknown:
        raise SystemExit(
            f"error: unknown fill layer(s) {unknown}; this build fills "
            f"{sorted(FILLER_FACTORIES)}")
    return [FILLER_FACTORIES[n](Path(root)) for n in wanted]


def _osm(root: Path) -> LayerFiller:
    from .mirror_fill_osm import OsmFiller

    return OsmFiller(root)


FILLER_FACTORIES["osm"] = _osm
