"""The Plotlines-controlled Protomaps basemap mirror (FR92, FR95; story M11,
issue #139).

FR95: basemap tiles come from the **Protomaps Basemap** (OSM-derived) under
**ODbL** as a Produced Work, and **Plotlines mirrors the tile source rather
than hotlinking** a third-party host. This module names that mirror — one
canonical host, one pinned Protomaps build — and makes "mirror, not hotlink"
mechanical: `resolve_upstream` refuses an `http(s)://` tile upstream that is
not the Plotlines mirror unless a caller explicitly opts into an unmirrored
dev source (`--allow-unmirrored-tiles`).

It also carries the basemap's ODbL attribution (`basemap_attribution`) — a
**separate obligation** from elevation's CC BY (FR86), owed on the About
surface and anywhere a map is exported or printed. `service` merges this line
into `GET /attribution` alongside the dynamically-enumerated layer credits so
the obligation propagates from one source rather than a hardcoded list.

The committed home-region archive (`tiles_paths.default_home_region_archive`)
stays the shipped, offline-first default upstream (ARCH D41/D57 — no eager
download). The mirror is the sanctioned *remote* upstream a region build is
pointed at for a trip bbox outside that one shipped region.
"""

from __future__ import annotations

import enum
from pathlib import Path
from urllib.parse import urlsplit

#: The pinned upstream Protomaps Basemap build the mirror carries. The
#: renderer theme is generated against one build (ARCH A15/D24); bumping this
#: is a visual-regression event, not a silent version bump.
PROTOMAPS_BASEMAP_BUILD = "20250101"

#: Plotlines-controlled storage — *not* a third-party tile host. FR92 forbids
#: the client (and, by extension, the sidecar's own extractor) talking to a
#: third-party tile host directly.
MIRROR_HOST = "tiles.plotlines.app"

#: The mirrored planet PMTiles archive `extract_bbox` ranges into over HTTP,
#: the same archive an offline-bundle export reads (FR94 — one pipeline for
#: live requests and offline packages).
MIRROR_ARCHIVE_URL = (
    f"https://{MIRROR_HOST}/basemap/protomaps/{PROTOMAPS_BASEMAP_BUILD}/planet.pmtiles"
)

#: ODbL, as a Produced Work from OSM data (FR95). `terms_url` is the
#: OpenStreetMap copyright page, not Protomaps' — the obligation runs to
#: OpenStreetMap.
BASEMAP_LICENCE_ID = "ODbL-1.0"
BASEMAP_ATTRIBUTION = "© OpenStreetMap contributors"
BASEMAP_TERMS_URL = "https://www.openstreetmap.org/copyright"


class HotlinkRefused(ValueError):
    """A tile upstream pointed at a third-party host rather than the
    Plotlines mirror or a local archive. FR92/FR95: Plotlines mirrors the
    tile source; it never hotlinks."""


class UpstreamKind(enum.Enum):
    LOCAL = "local"      # a PMTiles archive on local disk
    MIRROR = "mirror"    # the Plotlines-controlled mirror
    FOREIGN = "foreign"  # some other http(s) host — refused unless opted in


def classify_upstream(source: str | Path) -> UpstreamKind:
    """Which of the three upstream categories `source` falls into. A `Path`,
    or a string with no `http(s)://` scheme, is `LOCAL`; the Plotlines mirror
    host is `MIRROR`; anything else reachable over HTTP is `FOREIGN`."""
    if isinstance(source, Path):
        return UpstreamKind.LOCAL
    text = str(source)
    if not text.startswith(("http://", "https://")):
        return UpstreamKind.LOCAL
    host = (urlsplit(text).hostname or "").lower()
    if host == MIRROR_HOST:
        return UpstreamKind.MIRROR
    return UpstreamKind.FOREIGN


def resolve_upstream(source: str | Path, *, allow_unmirrored: bool = False) -> str | Path:
    """Return `source` unchanged if it is a local archive or the Plotlines
    mirror. Raise `HotlinkRefused` for any other `http(s)://` host unless
    `allow_unmirrored` — a dev-only escape hatch surfaced as
    `--allow-unmirrored-tiles`, never the shipped path."""
    kind = classify_upstream(source)
    if kind is UpstreamKind.FOREIGN and not allow_unmirrored:
        host = (urlsplit(str(source)).hostname or str(source))
        raise HotlinkRefused(
            f"tile upstream {host!r} is not the Plotlines mirror "
            f"({MIRROR_HOST}): Plotlines mirrors the Protomaps basemap rather "
            f"than hotlinking a third-party tile host (FR92/FR95). Pass "
            f"allow_unmirrored=True (--allow-unmirrored-tiles) for a dev source."
        )
    return source


def basemap_attribution() -> dict:
    """The basemap's ODbL credit line, shaped like
    `curation.attribution.LayerAttribution.as_dict()` so `/attribution` can
    return it in the same list as the dynamically-enumerated layer credits."""
    return {
        "layer": "basemap",
        "licence": BASEMAP_LICENCE_ID,
        "attribution": BASEMAP_ATTRIBUTION,
        "builtin": True,
        "terms_url": BASEMAP_TERMS_URL,
    }
