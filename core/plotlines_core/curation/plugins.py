"""Plugin layer discovery — PRD FR100 (story N5), ARCH §14.2, SPIKE-H §7.

A plugin data layer ships as an **ordinary installable Python package**,
discovered via an `importlib.metadata` entry point — never a URL the app
downloads and imports itself (runtime dynamic-code-fetch is a P7 and
supply-chain problem the moment it exists; installing a package is a
decision a human or a deployment pipeline makes once, auditable like any
other dependency).

A plugin package declares, in its own `pyproject.toml`::

    [project.entry-points."plotlines.layer_providers"]
    revwar_battlefields = "revwar_plugin:BattlefieldLayerProvider"

Each entry point resolves to something `LayerProvider`-shaped (structural —
no base class to import). `discover_layer_providers` loads each, and a
plugin that raises on load is reported rather than allowed to take the
process down with it — the same discipline the registry applies to a layer
that fails at fetch.
"""

from __future__ import annotations

from importlib import metadata
from typing import Iterator

ENTRY_POINT_GROUP = "plotlines.layer_providers"


def _load_entry_points(group: str):
    eps = metadata.entry_points()
    # `entry_points()` return shape changed across Python versions; both the
    # 3.10+ SelectableGroups API and the legacy dict are handled.
    try:
        return list(eps.select(group=group))
    except AttributeError:  # pragma: no cover — Python < 3.10
        return list(eps.get(group, []))


def discover_layer_providers(
    group: str = ENTRY_POINT_GROUP,
) -> list[tuple[str, object, str]]:
    """`(layer_name, provider, version)` for every installed plugin layer.

    `layer_name` is the entry-point name (the id the layer is offered under
    in the catalog and `/health`). `version` is the distribution version of
    the package that provided it, surfaced through `/health` so a stale
    plugin is visible rather than silently different (SPIKE-H §7). An entry
    point that fails to load yields a provider whose `load_state()` reports
    `failed:<reason>` so the registry records it like any other bad layer.
    """
    out: list[tuple[str, object, str]] = []
    for ep in _load_entry_points(group):
        version = _distribution_version(ep)
        try:
            provider = ep.load()
        except Exception as exc:  # noqa: BLE001 — a broken plugin is a failed layer, not a crash
            out.append((ep.name, _BrokenPluginProvider(ep.name, exc), version))
            continue
        # An entry point may point at a class or at a factory; accept either.
        if isinstance(provider, type):
            try:
                provider = provider()
            except Exception as exc:  # noqa: BLE001
                out.append((ep.name, _BrokenPluginProvider(ep.name, exc), version))
                continue
        out.append((ep.name, provider, version))
    return out


def _distribution_version(ep) -> str:
    dist = getattr(ep, "dist", None)
    if dist is not None and getattr(dist, "version", None):
        return str(dist.version)
    return ""


class _BrokenPluginProvider:
    """Stands in for a plugin whose entry point could not be loaded, so the
    failure is a per-layer `failed:` state in the picker rather than an
    import error that never reaches the Author."""

    def __init__(self, name: str, exc: BaseException) -> None:
        self._name = name
        self._reason = f"{type(exc).__name__}: {exc}"

    @property
    def licence(self):
        from .providers import LayerLicence

        return LayerLicence()  # unsatisfiable — never queried

    @property
    def taxonomy(self):
        return ()

    def fetch_candidates(self, bbox) -> list:  # pragma: no cover — never reached
        raise RuntimeError(f"plugin {self._name!r} failed to load: {self._reason}")

    def load_state(self):
        from .providers import FAILED, LayerLoadState

        return LayerLoadState(state=FAILED, reason=self._reason)
