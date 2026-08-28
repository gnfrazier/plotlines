"""A per-layer readiness registry — the mechanism ARCH §8.3's `/health` example
already prints and no code produces. Issue #159 point 3.

§8.3's response body shows this, verbatim:

    "layers": {"ready": true,
               "per_layer": {"osm_historic": "ready",
                             "plugin_battlefields": "loading",
                             "plugin_manors": "failed:licence_missing"}}

The shipped `create_app` emits `{layer: "ready" for layer in sorted(LAYERS)}` —
a constant. Every value is `"ready"` because every layer is built-in and
synchronous, so today the constant is *true*; it is simply not a state
machine, and there is no seam at which a plugin layer could ever report
anything else. `OsmLayerProvider` is likewise a single provider covering all
six built-in layers in one Overpass call, so "which layer failed" is not a
question it can answer.

This is what the shape looks like when it is a state machine. It is
deliberately a spike artifact rather than a patch to `core/`: N2 is the story
that builds this, and what SPIKE-D owes it is a demonstrated shape and the two
findings that fall out of building it (see RESULTS §4).

The three things this does that the constant cannot:

1. **A layer's state is its own.** `loading`, `ready`, `failed:<reason>` per
   layer, driven by the provider that backs it, so a slow remote plugin
   dataset does not hold the workspace shut.
2. **A failed layer subtracts, it does not abort.** `fetch` returns the
   features from every layer that worked plus a per-layer error map. The
   shipped `GET /candidates` wraps one provider call in one `try` and raises
   422 for the whole request, so one bad layer takes the other five with it —
   exactly the failure N2's AC forbids.
3. **Licence is checked at registration, not at fetch.** ARCH §12.2/D45 says
   a provider declares a licence; a plugin with none never reaches a query,
   and reports `failed:licence_missing` from the moment it is registered
   rather than failing on the Author's first extraction.
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field

from plotlines_core.curation.notability import RawFeature
from plotlines_core.curation.providers import BBox, LayerProvider

PENDING, LOADING, READY, FAILED = "pending", "loading", "ready", "failed"


@dataclass
class LayerEntry:
    """One layer, its provider, and its own readiness."""

    layer: str
    provider: LayerProvider
    builtin: bool = False
    status: str = PENDING
    reason: str = ""
    started_at: float | None = None
    estimated_s: float = 0.0

    def state(self) -> str:
        """The string `/health.capabilities.layers.per_layer[layer]` carries."""
        if self.status == FAILED:
            return f"{FAILED}:{self.reason}"
        return self.status

    def detail(self) -> dict:
        """The longer form a picker needs: state plus, while loading, an
        honest progress estimate (FR121's "never a bare spinner")."""
        out: dict = {"state": self.state(), "builtin": self.builtin}
        if self.status == LOADING and self.started_at is not None and self.estimated_s > 0:
            elapsed = time.perf_counter() - self.started_at
            out["progress"] = round(min(0.95, elapsed / self.estimated_s), 2)
            out["eta_s"] = round(max(self.estimated_s - elapsed, 1.0), 1)
        if self.status == FAILED:
            out["reason"] = self.reason
        return out


class LayerRegistry:
    """Every layer the workspace can offer, built-in or plugin, with its own
    lifecycle. Thread-safe because a plugin's warm-up runs off the request
    path — the whole point of N2."""

    def __init__(self) -> None:
        self._entries: dict[str, LayerEntry] = {}
        self._lock = threading.Lock()

    # ------------------------------------------------------------ registration

    def register_builtin(self, layers: set[str], provider: LayerProvider) -> None:
        """The six OSM layers: one provider, no warm-up, ready on arrival.
        Registered individually anyway so `per_layer` is a real map rather
        than a group that happens to have six keys."""
        with self._lock:
            for layer in layers:
                self._entries[layer] = LayerEntry(layer, provider, builtin=True,
                                                  status=READY)

    def register_plugin(self, layer: str, provider: LayerProvider, *,
                        warmup_s: float = 0.0, estimated_s: float = 0.0) -> None:
        """A plugin layer. Licence is enforced here (ARCH §12.2/D45): a
        provider with no declared licence is registered `failed` and never
        queried, so the Author sees why in the picker instead of discovering
        it when extraction returns nothing."""
        licence = getattr(provider, "licence", None)
        with self._lock:
            entry = LayerEntry(layer, provider, builtin=False,
                               estimated_s=estimated_s or warmup_s)
            self._entries[layer] = entry

        if not licence:
            self.fail(layer, "licence_missing")
            return

        entry.status = LOADING
        entry.reason = "loading dataset"
        entry.started_at = time.perf_counter()

        def warm() -> None:
            try:
                if warmup_s:
                    time.sleep(warmup_s)
                warmup = getattr(provider, "warm_up", None)
                if warmup is not None:
                    warmup()
            except Exception as exc:  # noqa: BLE001 — a failed layer is a state
                self.fail(layer, f"{type(exc).__name__}: {exc}")
                return
            with self._lock:
                entry.status = READY
                entry.reason = ""

        threading.Thread(target=warm, daemon=True).start()

    def fail(self, layer: str, reason: str) -> None:
        with self._lock:
            entry = self._entries.get(layer)
            if entry is not None:
                entry.status = FAILED
                entry.reason = reason

    # ------------------------------------------------------------- readiness

    def per_layer(self) -> dict[str, str]:
        with self._lock:
            return {k: e.state() for k, e in sorted(self._entries.items())}

    def per_layer_detail(self) -> dict[str, dict]:
        with self._lock:
            return {k: e.detail() for k, e in sorted(self._entries.items())}

    def capability(self) -> dict:
        """`capabilities.layers`. `ready` is true once **any** layer is usable,
        not once all are — N2's rule is that a loading plugin never gates the
        workspace, and an `all()` here would reinstate exactly the global flag
        B1 removed."""
        per = self.per_layer()
        return {
            "ready": any(state == READY for state in per.values()),
            "per_layer": per,
        }

    def ready_layers(self) -> set[str]:
        with self._lock:
            return {k for k, e in self._entries.items() if e.status == READY}

    # ----------------------------------------------------------------- fetch

    def fetch(self, bbox: BBox, layers: set[str]) -> tuple[list[RawFeature], dict[str, str]]:
        """Extract `layers`, skipping any that is not ready and continuing past
        any that raises. Returns `(features, per_layer_error)`.

        The return type is the finding: a caller cannot honour N2 while its
        provider returns a bare list, because "which layers did I actually
        get?" has nowhere to live and the only available signal is an
        exception that takes the whole request with it.
        """
        with self._lock:
            entries = [self._entries[l] for l in sorted(layers) if l in self._entries]
        errors: dict[str, str] = {}
        by_provider: dict[int, tuple[LayerProvider, set[str]]] = {}

        for entry in entries:
            if entry.status != READY:
                errors[entry.layer] = entry.state()
                continue
            key = id(entry.provider)
            provider, group = by_provider.setdefault(key, (entry.provider, set()))
            group.add(entry.layer)

        features: list[RawFeature] = []
        for provider, group in by_provider.values():
            try:
                features.extend(provider.fetch(bbox, group))
            except Exception as exc:  # noqa: BLE001 — subtract the layer, keep the rest
                for layer in group:
                    reason = f"{FAILED}:{type(exc).__name__}"
                    errors[layer] = reason
                    self.fail(layer, f"{type(exc).__name__}: {exc}")
        return features, errors


# ------------------------------------------------------- fake plugin providers


@dataclass
class StubPluginProvider:
    """A plugin `LayerProvider` (ARCH §14.2) whose only job is to be slow, to
    fail, or to return a fixed feature. Stands in for N5's real plugin
    datasets, which do not exist yet."""

    licence: str = "CC-BY-4.0"
    features: list[RawFeature] = field(default_factory=list)
    raise_on_fetch: Exception | None = None
    raise_on_warmup: Exception | None = None

    def warm_up(self) -> None:
        if self.raise_on_warmup is not None:
            raise self.raise_on_warmup

    def fetch(self, bbox: BBox, layers: set[str]) -> list[RawFeature]:
        if self.raise_on_fetch is not None:
            raise self.raise_on_fetch
        return [f for f in self.features if bbox.west <= f.coord[0] <= bbox.east
                and bbox.south <= f.coord[1] <= bbox.north]


@dataclass
class UnlicensedPluginProvider:
    """FR101 / ARCH D45 — a plugin that declares no licence. `licence` is
    empty rather than absent so it satisfies the `LayerProvider` protocol
    structurally and still fails the registration gate, which is the realistic
    shape of the mistake."""

    licence: str = ""

    def fetch(self, bbox: BBox, layers: set[str]) -> list[RawFeature]:  # pragma: no cover
        raise AssertionError("an unlicensed provider must never be queried")
