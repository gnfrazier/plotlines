"""Per-layer registry over `LayerProvider`s — ARCH §8.3 (breaking B1), D45,
D48; PRD FR121/FR91 (story N2), FR100/FR101 (story N5).

This is the mechanism ARCH §8.3's `/health` example already prints and that
no shipped code produced: `capabilities.layers.per_layer` was the constant
`{layer: "ready" for layer in sorted(LAYERS)}` — true while every layer was
built-in and synchronous, but not a state machine, and with no seam at which
a plugin layer could report `loading` or `failed:licence_missing`.

Three things the constant could not do, and this does (validated in
SPIKE-D #159 and SPIKE-H #160):

1. **A layer's state is its own.** `pending` / `loading` / `ready` /
   `failed:<reason>` per layer, so a slow or remote plugin dataset shows as
   *loading* in the picker while the built-in layers are already usable, and
   one plugin layer failing never blocks the others or the workspace.
2. **A failed layer subtracts, it does not abort.** `fetch_candidates_all`
   returns the candidates from every layer that worked plus a per-layer
   error map — the shape `GET /candidates` needs so it can serve the layers
   it did get instead of 422-ing the whole request.
3. **Licence is checked at registration, not at fetch.** A plugin whose
   `licence.satisfiable` is false (ARCH §12.2/D45) is registered straight to
   `failed:licence_unsatisfiable` and never queried.

`capabilities.layers.ready` is **`any`, not `all`** (§8.3): an `all()` here
would let one slow plugin re-impose exactly the global flag B1 removed.
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field

from .notability import Candidate
from .providers import (
    FAILED,
    LOADING,
    PENDING,
    READY,
    BBox,
    LayerLoadState,
    LayerProvider,
)


@dataclass
class LayerEntry:
    """One layer, its provider, and its own readiness lifecycle."""

    layer: str
    provider: LayerProvider
    builtin: bool = False
    status: str = PENDING
    reason: str = ""
    progress: float | None = None
    version: str = ""
    started_at: float | None = None

    def state(self) -> str:
        """The string `/health.capabilities.layers.per_layer[layer]` carries —
        `failed:<reason>` for a failure so the reason is never lost."""
        if self.status == FAILED:
            return f"{FAILED}:{self.reason}" if self.reason else FAILED
        return self.status

    def detail(self) -> dict:
        """The longer form a picker needs: state, provenance, and — while
        loading — observed progress rather than a bare spinner (FR121). No
        fixed ETA: a constant estimate is wrong precisely when the Author is
        busiest, so this reports elapsed-derived progress only where the
        provider gave one."""
        out: dict = {"state": self.state(), "builtin": self.builtin}
        if self.version:
            out["version"] = self.version
        if self.status == LOADING:
            if self.progress is not None:
                out["progress"] = round(self.progress, 2)
            if self.started_at is not None:
                out["elapsed_s"] = round(time.monotonic() - self.started_at, 1)
        if self.status == FAILED and self.reason:
            out["reason"] = self.reason
        return out


class LayerRegistry:
    """Every layer the Curation Workspace can offer, built-in or plugin, each
    with its own lifecycle. Thread-safe: a plugin's warm-up runs off the
    request path, which is the whole point of N2.
    """

    #: A plugin whose `load_state()` still reports `loading` is re-polled on
    #: this cadence by a daemon thread until it settles or `_warmup_deadline_s`
    #: elapses. A `loading` that never resolves is the spinner N2 removes.
    _poll_interval_s = 0.25
    _warmup_deadline_s = 120.0

    def __init__(self) -> None:
        self._entries: dict[str, LayerEntry] = {}
        self._lock = threading.RLock()

    # ------------------------------------------------------------ registration

    def register_builtin(self, layer: str, provider: LayerProvider) -> None:
        """A built-in layer: synchronous, no warm-up, ready on arrival.
        Registered individually so `per_layer` is a real map, not a group
        that happens to have six keys."""
        with self._lock:
            self._entries[layer] = LayerEntry(
                layer, provider, builtin=True, status=READY,
            )

    def register_builtins(self, providers: dict[str, LayerProvider]) -> None:
        for layer, provider in providers.items():
            self.register_builtin(layer, provider)

    def register_plugin(self, layer: str, provider: LayerProvider, *,
                        version: str = "") -> None:
        """A plugin layer. The licence gate (D45/§12.2) runs *here*, before
        any query — a provider whose `licence.satisfiable` is false is
        registered `failed:licence_unsatisfiable` and never called. Then the
        provider's own `load_state()` decides `ready` / `loading` / `failed`;
        a `loading` layer is re-polled in the background until it settles.
        """
        with self._lock:
            entry = LayerEntry(layer, provider, builtin=False, version=version,
                               status=PENDING)
            self._entries[layer] = entry

        licence = getattr(provider, "licence", None)
        satisfiable = getattr(licence, "satisfiable", False)
        if not satisfiable:
            self._fail(layer, "licence_unsatisfiable")
            return

        with self._lock:
            entry.status = LOADING
            entry.reason = "loading dataset"
            entry.started_at = time.monotonic()

        try:
            state = provider.load_state()
        except Exception as exc:  # noqa: BLE001 — a broken load_state is a failed layer, not a crash
            self._fail(layer, f"{type(exc).__name__}: {exc}")
            return

        self._apply_load_state(layer, state)
        with self._lock:
            still_loading = self._entries[layer].status == LOADING
        if still_loading:
            threading.Thread(target=self._warm, args=(layer,), daemon=True).start()

    # --------------------------------------------------------------- internals

    def _apply_load_state(self, layer: str, state: LayerLoadState) -> None:
        with self._lock:
            entry = self._entries.get(layer)
            if entry is None:
                return
            if state.state == READY:
                entry.status = READY
                entry.reason = ""
                entry.progress = None
            elif state.state == FAILED:
                entry.status = FAILED
                entry.reason = state.reason or "load_state reported failed"
            else:
                entry.status = LOADING
                entry.reason = state.reason or "loading dataset"
                entry.progress = state.progress

    def _warm(self, layer: str) -> None:
        deadline = time.monotonic() + self._warmup_deadline_s
        with self._lock:
            entry = self._entries.get(layer)
        while entry is not None and time.monotonic() < deadline:
            time.sleep(self._poll_interval_s)
            try:
                state = entry.provider.load_state()
            except Exception as exc:  # noqa: BLE001
                self._fail(layer, f"{type(exc).__name__}: {exc}")
                return
            self._apply_load_state(layer, state)
            with self._lock:
                if self._entries.get(layer, entry).status != LOADING:
                    return
        self._fail(layer, "warmup_timed_out")

    def _fail(self, layer: str, reason: str) -> None:
        with self._lock:
            entry = self._entries.get(layer)
            if entry is not None:
                entry.status = FAILED
                entry.reason = reason
                entry.progress = None

    def mark_ready(self, layer: str) -> None:
        with self._lock:
            entry = self._entries.get(layer)
            if entry is not None:
                entry.status = READY
                entry.reason = ""
                entry.progress = None

    # -------------------------------------------------------------- readiness

    def has(self, layer: str) -> bool:
        with self._lock:
            return layer in self._entries

    def known_layers(self) -> list[str]:
        with self._lock:
            return sorted(self._entries)

    def provider(self, layer: str) -> LayerProvider | None:
        with self._lock:
            entry = self._entries.get(layer)
            return entry.provider if entry else None

    def per_layer(self) -> dict[str, str]:
        with self._lock:
            return {k: e.state() for k, e in sorted(self._entries.items())}

    def per_layer_detail(self) -> dict[str, dict]:
        with self._lock:
            return {k: e.detail() for k, e in sorted(self._entries.items())}

    def capability(self) -> dict:
        """`capabilities.layers`. `ready` is true once **any** layer is
        usable, not once all are (§8.3 — an `all()` reinstates the global
        flag B1 removed)."""
        per = self.per_layer()
        return {
            "ready": any(state == READY for state in per.values()),
            "per_layer": per,
        }

    def ready_layers(self) -> set[str]:
        with self._lock:
            return {k for k, e in self._entries.items() if e.status == READY}

    # ----------------------------------------------------------------- fetch

    def fetch_candidates_all(
        self, bbox: BBox, layers: set[str],
    ) -> tuple[list[Candidate], dict[str, str]]:
        """`(candidates, per_layer_error)` for the requested `layers`.

        A layer that is unknown, not ready, or whose `fetch_candidates`
        raises **subtracts** from the result and is named in the error map;
        it never aborts the request (N2's AC, and the exact inverse of the
        shipped `/candidates`'s single `try`). A raising provider is also
        marked `failed` so the picker reflects it on the next `/health`.
        """
        with self._lock:
            requested = sorted(layers)
            entries = {l: self._entries.get(l) for l in requested}

        candidates: list[Candidate] = []
        errors: dict[str, str] = {}
        for layer in requested:
            entry = entries[layer]
            if entry is None:
                errors[layer] = "unknown_layer"
                continue
            if entry.status != READY:
                errors[layer] = entry.state()
                continue
            try:
                candidates.extend(entry.provider.fetch_candidates(bbox))
            except Exception as exc:  # noqa: BLE001 — subtract the layer, keep the rest
                reason = f"{type(exc).__name__}: {exc}"
                errors[layer] = f"{FAILED}:{reason}"
                self._fail(layer, reason)
        candidates.sort(key=lambda c: c.salience, reverse=True)
        return candidates, errors


def build_default_registry(
    *, osm_engine=None, discover_plugins: bool = True,
) -> LayerRegistry:
    """A registry with the six built-in OSM layers registered, plus any
    plugin layer discovered via the `plotlines.layer_providers` entry point
    (story N5). `osm_engine` is injectable for tests; `discover_plugins` is
    off in tests that do not want the host environment's installed plugins.
    """
    from .providers import builtin_osm_providers

    registry = LayerRegistry()
    registry.register_builtins(builtin_osm_providers(osm_engine))
    if discover_plugins:
        from .plugins import discover_layer_providers

        for name, provider, version in discover_layer_providers():
            registry.register_plugin(name, provider, version=version)
    return registry
