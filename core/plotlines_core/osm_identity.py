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
