"""The one string Plotlines identifies itself with to public OSM services.

Phase 0.1 of the OSM acquisition plan (issue #241; review §5.1, §3.4;
licensing addendum P2). Every Overpass and Nominatim request osmnx makes
builds its outbound headers from `ox.settings.http_user_agent` and
`ox.settings.http_referer` (via `osmnx._http._get_http_headers`). Unset,
both inherit osmnx's own default — `OSMnx Python package
(https://github.com/gboeing/osmnx)` — so every request Plotlines makes to
donated infrastructure is attributed to an unrelated maintainer's library.
An operator investigating the load then has no way to reach us and no lever
but an IP-level block, which is what the dev machine got in #232;
`graph/regions.py` already records `overpass.openstreetmap.fr` answering
`403 "only available to white-listed usages"` to the library-generic UA
while serving `curl` fine.

This module is the contactable replacement: product name, build version, and
a URL an operator can actually open. It lives in `plotlines_core`, beside the
Overpass endpoint policy in `graph/regions.py`, because the core library is
what makes the requests — the service must not be the only thing that knows
the string.

`apply_osm_http_identity(version)` is called at every headless entrypoint
(the sidecar and hosted `create_app`, the `diagnose_region` CLI) with the
real build version, and once more at `graph/regions.py` import time with an
`unknown` version as a floor — so a bare `import plotlines_core.graph.regions`
never sends osmnx's default even before an entrypoint has run. One call
covers the routing-graph, candidate, and `/geocode` transports at once,
because all three read the same two settings.
"""

from __future__ import annotations

import threading
from contextlib import contextmanager
from typing import Iterator

PRODUCT_NAME = "Plotlines"

#: A URL an OSM service operator investigating Plotlines' traffic can open to
#: reach the project. Deliberately the public repository — it carries the
#: issue tracker and the contact paths — not a marketing page.
CONTACT_URL = "https://github.com/gnfrazier/plotlines"


def osm_user_agent(version: str | None = None) -> str:
    """The Plotlines UA/referer string: ``Plotlines/<version> (+<url>)``.

    `version` is `plotlines_service.version.VERSION` at a real entrypoint;
    `None` or an empty value falls back to `unknown` so the result is still
    non-default — being a *recognisable, contactable* client rather than
    being indistinguishable from an unattended osmnx script is the property
    every §10 / addendum P6 policy test asserts, and it must hold even if the
    version lookup ever fails.
    """
    return f"{PRODUCT_NAME}/{version or 'unknown'} (+{CONTACT_URL})"


#: The identity a bare library import falls back to (version unknown). Not a
#: substitute for `apply_osm_http_identity(VERSION)` at the entrypoint — just
#: a floor that is never osmnx's default.
DEFAULT_OSM_USER_AGENT = osm_user_agent()


def apply_osm_http_identity(version: str | None = None) -> str:
    """Point `ox.settings.http_user_agent` and `ox.settings.http_referer` at
    the Plotlines identity for `version`, and return the string set.

    Both Overpass (`osmnx._overpass`) and Nominatim (`osmnx._nominatim`)
    build their outbound headers from these two settings, so this single
    call covers the routing-graph, candidate, and `/geocode` transports.
    Idempotent; safe to call from more than one entrypoint.
    """
    import osmnx as ox

    ua = osm_user_agent(version)
    ox.settings.http_user_agent = ua
    ox.settings.http_referer = ua
    return ua


#: Serialises every stretch of plotlines-core code that makes an osmnx
#: Overpass call while driving the process-global `ox.settings.overpass_url` /
#: `ox.settings.overpass_rate_limit`.
#:
#: osmnx has no per-request override for either — `_overpass_request` and
#: `_get_overpass_pause` read them straight off the global `ox.settings` — and
#: they are shared by the routing-graph path (`graph/regions.py`) and the
#: candidate path (`curation/providers.py`). `/regions` and `/candidates` are
#: both sync `def` FastAPI endpoints, so the framework runs them on threadpool
#: siblings concurrently. Before issue #244 a `/candidates` call that landed
#: during a region build's Overpass failover inherited the failover endpoint
#: (and, pre-#245, `overpass_rate_limit = False`) — an upstream and an
#: impoliteness it never asked for (licensing addendum G1). This lock is the
#: "serialise OSM access behind one lock" option from that finding: hold it
#: around any such call so no two are ever in flight under different globals.
OSM_SETTINGS_LOCK = threading.Lock()


@contextmanager
def overpass_settings(
    *, url: str | None = None, rate_limit: bool | None = None,
) -> Iterator[None]:
    """Hold `OSM_SETTINGS_LOCK` for the block, optionally point osmnx's
    process-global `overpass_url` / `overpass_rate_limit` at `url` /
    `rate_limit` while it runs, and restore both to the values seen on entry
    on the way out — even if the block raises.

    `url=None` and `rate_limit=None` each mean "leave that setting untouched":
    under this exclusion the value on entry is always whatever the previous
    holder restored, i.e. the configured default. The candidate path calls
    this with no arguments purely for the mutual exclusion — it always wants
    the default endpoint and the default politeness posture. The routing-graph
    failover loop passes a `url` per hop and no `rate_limit` — since issue
    #245 it keeps the configured pause in force for every attempt and relies
    on a pre-flight connect probe, not on disabling the pause, to keep
    failover fast (`graph/regions.py`). The `rate_limit` argument stays for a
    caller that genuinely needs to override the pause for the length of a
    block.

    Not reentrant: `OSM_SETTINGS_LOCK` is a plain `Lock` and nothing in
    plotlines-core nests one `overpass_settings` block inside another.
    """
    import osmnx as ox

    with OSM_SETTINGS_LOCK:
        saved_url = ox.settings.overpass_url
        saved_rate_limit = ox.settings.overpass_rate_limit
        try:
            if url is not None:
                ox.settings.overpass_url = url
            if rate_limit is not None:
                ox.settings.overpass_rate_limit = rate_limit
            yield
        finally:
            ox.settings.overpass_url = saved_url
            ox.settings.overpass_rate_limit = saved_rate_limit
