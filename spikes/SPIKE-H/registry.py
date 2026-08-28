"""Per-layer registry against the reconciled `LayerProvider` (ARCH §14.2) —
issue #160 points 5 and 6. Adapts `spikes/SPIKE-D/plugin_layers.py:LayerRegistry`
(same state machine: `pending`/`loading`/`ready`/`failed:<reason>`, licence
enforced at registration not fetch, one layer's failure subtracts rather than
aborting) to providers that carry their own `licence`/`taxonomy`/`load_state`
instead of the bare-string-licence, six-layers-per-call shape SPIKE-D's
version wrapped. Still not a patch to `core/` — a second spike-local
prototype, same discipline as SPIKE-D's.
"""

from __future__ import annotations

import threading
from dataclasses import dataclass

import _paths  # noqa: F401

from contract import BBox, Candidate, FAILED, LayerProvider, LOADING, PENDING, READY


@dataclass
class RegistryEntry:
    layer: str
    provider: LayerProvider
    builtin: bool = False
    status: str = PENDING
    reason: str = ""

    def state(self) -> str:
        return f"{FAILED}:{self.reason}" if self.status == FAILED else self.status

    def detail(self) -> dict:
        out = {"state": self.state(), "builtin": self.builtin}
        if self.status == FAILED:
            out["reason"] = self.reason
        return out


class LayerRegistry:
    """Registration-time licence gate (D45, §12.2) + per-layer load state
    (D48, §8.3) against the real protocol. `fetch_candidates_all` merges
    every ready layer's `Candidate`s and never lets one provider's exception
    take the others down with it (N2's AC, and the exact inverse of the
    shipped `/candidates`'s single `try` SPIKE-D found)."""

    def __init__(self) -> None:
        self._entries: dict[str, RegistryEntry] = {}
        self._lock = threading.Lock()

    def register_builtin(self, layer: str, provider: LayerProvider) -> None:
        with self._lock:
            self._entries[layer] = RegistryEntry(layer, provider, builtin=True, status=READY)

    def register_plugin(self, layer: str, provider: LayerProvider) -> None:
        """D45: licence checked here, before any query — not the provider's
        own `load_state()`, which can honestly say `ready` while the layer
        is still refused. A provider whose `licence.satisfiable` is False is
        registered straight to `failed:licence_unsatisfiable` and is never
        called again."""
        licence = provider.licence
        with self._lock:
            entry = RegistryEntry(layer, provider, builtin=False)
            self._entries[layer] = entry

        if not licence.satisfiable:
            self.fail(layer, "licence_unsatisfiable")
            return

        entry.status = LOADING
        try:
            state = provider.load_state()
        except Exception as exc:  # noqa: BLE001 — a broken load_state is a failure, not a crash
            self.fail(layer, f"{type(exc).__name__}: {exc}")
            return

        with self._lock:
            if state.state == READY:
                entry.status = READY
            elif state.state == FAILED:
                entry.status = FAILED
                entry.reason = state.reason or "load_state reported failed"
            else:
                entry.status = LOADING
                entry.reason = state.reason

    def fail(self, layer: str, reason: str) -> None:
        with self._lock:
            entry = self._entries.get(layer)
            if entry is not None:
                entry.status = FAILED
                entry.reason = reason

    def mark_ready(self, layer: str) -> None:
        with self._lock:
            entry = self._entries.get(layer)
            if entry is not None:
                entry.status = READY
                entry.reason = ""

    def per_layer(self) -> dict[str, str]:
        with self._lock:
            return {k: e.state() for k, e in sorted(self._entries.items())}

    def per_layer_detail(self) -> dict[str, dict]:
        with self._lock:
            return {k: e.detail() for k, e in sorted(self._entries.items())}

    def capability(self) -> dict:
        per = self.per_layer()
        return {"ready": any(v == READY for v in per.values()), "per_layer": per}

    def fetch_candidates_all(self, bbox: BBox, layers: set[str]
                             ) -> tuple[list[Candidate], dict[str, str]]:
        """`(candidates, per_layer_error)` — a failed or not-ready layer
        subtracts from the result; it never aborts the request (N2's AC)."""
        with self._lock:
            entries = [self._entries[l] for l in sorted(layers) if l in self._entries]

        candidates: list[Candidate] = []
        errors: dict[str, str] = {}
        for entry in entries:
            if entry.status != READY:
                errors[entry.layer] = entry.state()
                continue
            try:
                candidates.extend(entry.provider.fetch_candidates(bbox))
            except Exception as exc:  # noqa: BLE001 — subtract the layer, keep the rest
                reason = f"{type(exc).__name__}: {exc}"
                errors[entry.layer] = f"{FAILED}:{reason}"
                self.fail(entry.layer, reason)
        return candidates, errors
