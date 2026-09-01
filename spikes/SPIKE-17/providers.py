"""Two real `EdgeDataProvider` implementations, against the **shipped** core
Protocol — `plotlines_core.providers.EdgeDataProvider`, unchanged (PR #225,
issue #147). If either of these needed a core edit to work, ARCH §14.4 says
the extension point is wrong, and that is the finding rather than the fix.

Both annotate under an `advisory:` namespace and touch nothing else. That is
two constraints at once:

- **P6** — a plugin extends, never modifies. Nothing here writes `highway`,
  `access`, `bicycle`, `surface`, `maxspeed`, `lanes` or `length`, the keys
  `routing/access.py` and `scoring/profile.py` actually consume. `run_spike.py`
  asserts it on the real annotated graph rather than trusting this sentence.
- **Advisory, not constraint** — a work zone surfaces and warns; it never
  excludes an edge. Mode-legality (FR128) is the constraint category and it
  lives in core. An advisory promoted to a constraint takes a judgement away
  from the Author, and a DOT feed is exactly the tempting place to do it.

Every annotation carries `advisory:observed_at` and `advisory:expires_at`,
because an annotation without an age is indistinguishable from a fresh one and
"no contrary signal found" must never read as "confirmed clear" (FR14).
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from plotlines_core.curation.providers import BBox, LayerLicence
from plotlines_core.providers import EdgeDataProvider  # noqa: F401 — conformance

import http_cache
import matching
import normalize

#: How long an annotation from a feed stays usable when the feed itself does
#: not say. Justified from measurement in RESULTS §4, not chosen here.
DEFAULT_TTL = timedelta(minutes=15)


class _FeedEdgeProvider:
    """Shared plumbing for a feed-shaped edge source: fetch a document, adapt
    it to `RoadEvent`s, match, annotate.

    The `licence`, `load_state()` and `stats` members below are **not in
    ARCH §14.2's `EdgeDataProvider`** — the Protocol is one method,
    `annotate_edges(graph, bbox) -> graph`. They are here because writing a
    real provider without them turned out to be impossible; see RESULTS §2.
    """

    source_id = "unset"
    url = ""
    licence = LayerLicence()

    def __init__(self, *, ttl: timedelta = DEFAULT_TTL, force: bool = False) -> None:
        self.ttl = ttl
        self.force = force
        self.stats: matching.MatchStats | None = None
        self.document: dict | None = None
        self.events: list[normalize.RoadEvent] = []
        self._error = ""

    # -- source-specific -------------------------------------------------
    def adapt(self, doc: dict) -> list[normalize.RoadEvent]:  # pragma: no cover
        raise NotImplementedError

    def declared_licence(self, doc: dict) -> LayerLicence:  # pragma: no cover
        return self.licence

    # -- the contract ----------------------------------------------------
    def fetch(self) -> None:
        try:
            self.document = http_cache.cached_get(self.source_id, self.url,
                                                  force=self.force)
            self.events = self.adapt(self.document)
            self.licence = self.declared_licence(self.document)
        except Exception as exc:  # noqa: BLE001 — a bad feed is a failed source
            self._error = f"{type(exc).__name__}: {exc}"

    def load_state(self) -> dict:
        if self._error:
            return {"state": "failed", "reason": self._error}
        if self.document is None:
            return {"state": "pending"}
        return {"state": "ready"}

    def annotate_edges(self, graph, bbox: BBox):
        """ARCH §14.2's one method. Returns the same graph, extended."""
        if self.document is None:
            self.fetch()
        if self._error:
            return graph

        index = matching.EdgeIndex(graph)
        now = datetime.now(timezone.utc)
        active = [e for e in self.events if e.active_at(now)]
        hits, stats = matching.match_events(graph, index, active)
        self.stats = stats

        for (u, v, k), events in hits.items():
            worst = min(events, key=lambda e: normalize.IMPACT_ORDER.index(e.impact)
                        if e.impact in normalize.IMPACT_ORDER else 99)
            data = graph.edges[u, v, k]
            data["advisory:source"] = self.source_id
            data["advisory:kind"] = worst.kind
            data["advisory:impact"] = worst.impact
            data["advisory:event_id"] = worst.id
            data["advisory:event_count"] = len(events)
            data["advisory:observed_at"] = (worst.observed_at or now).isoformat()
            # Two clocks, deliberately not collapsed into one — see RESULTS §4.
            data["advisory:stale_after"] = (now + self.ttl).isoformat()
            data["advisory:event_ends_at"] = worst.ends_at.isoformat() if worst.ends_at else ""
            data["advisory:licence"] = self.licence.id
        return graph


class WzdxEdgeProvider(_FeedEdgeProvider):
    """Any WZDx publisher. Constructed with a URL and an id — there is no
    per-publisher code in this class, which is the claim RESULTS §3 tests by
    running two unrelated state DOTs through it unchanged."""

    def __init__(self, source_id: str, url: str, **kwargs) -> None:
        super().__init__(**kwargs)
        self.source_id = source_id
        self.url = url

    def adapt(self, doc: dict) -> list[normalize.RoadEvent]:
        return normalize.wzdx_events(doc, self.source_id)

    def declared_licence(self, doc: dict) -> LayerLicence:
        licence_id = normalize.wzdx_licence_id(doc)
        publisher = str((doc.get("feed_info") or {}).get("publisher") or "").strip()
        if not licence_id:
            # Nothing declared. Not guessed at — the registry refuses it.
            return LayerLicence(note="feed_info carries no `license` field")
        return LayerLicence(
            id=licence_id,
            attribution=f"Work zone data: {publisher or self.source_id}",
            terms_url=licence_id if licence_id.startswith("http") else "",
            note="declared by the feed's own feed_info.license",
        )


class NwsAlertEdgeProvider(_FeedEdgeProvider):
    """NWS active alerts as an edge advisory. Deliberately the awkward one:
    no road identity, severity instead of lane impact, and geometry that is
    frequently absent and only reachable by following `affectedZones` — one
    HTTP request per zone."""

    def __init__(self, source_id: str, url: str, **kwargs) -> None:
        super().__init__(**kwargs)
        self.source_id = source_id
        self.url = url

    def adapt(self, doc: dict) -> list[normalize.RoadEvent]:
        return normalize.nws_events(doc, self.source_id)

    def declared_licence(self, doc: dict) -> LayerLicence:
        # api.weather.gov returns no licence field of any kind. US federal
        # works are public domain, but that is the integrator asserting it —
        # recorded as such, exactly as `OSM_LICENCE` records its own assertion.
        return LayerLicence(
            id="US-Gov-Public-Domain",
            attribution="Weather alerts: NOAA / National Weather Service",
            terms_url="https://www.weather.gov/disclaimer",
            note="asserted by the integrator; api.weather.gov returns no licence field",
        )
