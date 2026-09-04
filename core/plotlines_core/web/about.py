"""The About surface — stories K10 (issue #116) and K11 (issue #117).

Two obligations meet on one screen:

* **K10 / FR86, FR95, FR101.** Every licensed data source's attribution, shown
  together because they are separate obligations under different licences:
  elevation's **CC BY** (FR86), the basemap's ODbL ``© OpenStreetMap`` (FR95),
  the routing graph's own ODbL credit (issue #269 — built from the same OSM
  data, but a distinct obligation rather than a free ride under the
  basemap's line), and a credit line for **every loaded plugin layer** (FR101,
  story N5). Plus the running app version and, on desktop, the sidecar
  version that must match ``/health``. A loaded layer that would reach a
  display surface with no attribution is a **build failure** —
  :func:`assert_about_attribution_complete` is that release gate, wrapping
  :func:`plotlines_core.curation.attribution.assert_attribution_complete` and
  adding the three always-owed static obligations (elevation, basemap, graph)
  to it.

* **K11 / FR138.** A plain-language privacy statement, reachable from the About
  surface on every platform including the lightest (Web guest, the share-token
  reading view). It is **not legal boilerplate** — it says what is true,
  briefly, in the app's own voice: what lives on the device and what reaches
  the server; that reveal is a product guarantee against accidental spoiling
  and *not* a security boundary (FR64a); what arrival sharing does and does not
  do, and that it defaults to nothing shared (FR123); that an Author may keep
  private notes about Characters, visible only to that Author, persisting
  across trips and deletable on request (FR135/FR135a); and that guest sessions
  leave no server-side trace (K4).

Pure policy + plain data — no FastAPI import (P1). ``service`` renders
:func:`build_about_surface` at ``GET /about``; the Flutter client mirrors
:data:`PRIVACY_STATEMENT` in Dart so the lightest surfaces can show it with no
sidecar reachable.
"""

from __future__ import annotations

from dataclasses import dataclass

from plotlines_core.curation.attribution import (
    MissingAttributionError,
    assert_attribution_complete,
    attributions_for,
)
from plotlines_core.elevation.region_asset import elevation_attribution
from plotlines_core.graph.regions import graph_attribution
from plotlines_core.tiles.mirror import basemap_attribution


# --- K10: attribution --------------------------------------------------------

#: The obligations owed on every surface no matter which plugin layers are
#: loaded: the shipped home-region DEM (FR90) always owes CC BY, the basemap
#: always ships and owes ODbL, and the routing graph — built from the same
#: OSM data, one of the three capability gates that always starts (ARCH B1)
#: — owes its own ODbL credit rather than inheriting the basemap's by
#: accident (issue #269, addendum L6). Enumerated here so the build gate can
#: assert their presence independently of the dynamic per-layer set.
_STATIC_ATTRIBUTIONS = ("elevation", "basemap", "graph")


def about_attributions(registry) -> list[dict]:
    """Every credit line the About surface shows, as plain dicts shaped like
    :meth:`plotlines_core.curation.attribution.LayerAttribution.as_dict`.

    Order: elevation (CC BY, FR86), then basemap (ODbL, FR95), then the
    routing graph (ODbL, issue #269) — the three static obligations, shown
    together because each is a *separate* obligation even where two share a
    licence — then every ready layer's credit (FR101), built-ins before
    plugins, each alphabetical.
    """
    lines: list[dict] = [
        elevation_attribution(),
        basemap_attribution(),
        graph_attribution(),
    ]
    lines += [a.as_dict() for a in attributions_for(registry)]
    return lines


def assert_about_attribution_complete(registry) -> list[dict]:
    """The K10 release gate (FR86/FR95/FR101). Returns the credit lines that
    *will* be shown; raises
    :class:`plotlines_core.curation.attribution.MissingAttributionError` if any
    line — static obligation or loaded layer — would reach the surface with no
    attribution string. A build failure, not a render-time warning.
    """
    # The dynamic half: every loaded, in-use layer must carry a credit.
    assert_attribution_complete(registry)

    # The static half: elevation, basemap, and the routing graph always ship,
    # so their credit lines must always be non-empty. A drift here (a
    # constant emptied by a bad merge) is exactly the failure this gate
    # exists to catch.
    lines = about_attributions(registry)
    by_layer = {line["layer"]: line for line in lines}
    missing = [
        name
        for name in _STATIC_ATTRIBUTIONS
        if not by_layer.get(name, {}).get("attribution", "").strip()
    ]
    if missing:
        raise MissingAttributionError(
            "static attribution obligation with no credit line: "
            + ", ".join(missing)
        )
    return lines


# --- K11: privacy statement ------------------------------------------------


@dataclass(frozen=True)
class PrivacyPoint:
    """One titled paragraph of the privacy statement. Plain data so the same
    text can be rendered by the service, an export footer, or a test that
    pins each required point is present."""

    id: str
    title: str
    body: str

    def as_dict(self) -> dict:
        return {"id": self.id, "title": self.title, "body": self.body}


#: FR138, in the app's own voice — not legal boilerplate. Each point maps to a
#: clause the FR names verbatim; the ``id`` is the stable handle a test and the
#: Dart mirror key off.
PRIVACY_STATEMENT: tuple[PrivacyPoint, ...] = (
    PrivacyPoint(
        id="on_device",
        title="What stays on this device",
        body=(
            "Your trips, routes, notes, and the maps and elevation you have "
            "downloaded all live on this device. Planning works with nothing "
            "signed in."
        ),
    ),
    PrivacyPoint(
        id="to_server",
        title="What reaches the server",
        body=(
            "Only things that need other people: signing in, syncing your own "
            "trips between your devices, and sharing a trip or an arrival with "
            "someone you have chosen. Drawing an area or looking up a place is "
            "different — see the next point."
        ),
    ),
    # Phase 0.12 / addendum P1 (issue #252): today this names Overpass and
    # Nominatim because that is what actually runs. Phase 1 (#264) moves map
    # data to a Plotlines-operated mirror — revisit this wording, and its
    # recipient, when that migration lands.
    PrivacyPoint(
        id="planning_requests",
        title="What planning sends, even signed out",
        body=(
            "Drawing an area to plan in sends that area to Overpass, a "
            "volunteer-run map-data lookup — today hosted in Germany or "
            "Lithuania — so we can show you what is nearby. Typing a place "
            "to search for it sends that text to Nominatim, the "
            "OpenStreetMap Foundation's place-name lookup. Neither request "
            "carries your account, your name, or any other identity."
        ),
    ),
    PrivacyPoint(
        id="reveal",
        title="Reveal keeps surprises intact — it is not a lock",
        body=(
            "Hiding a plot point stops it from spoiling the story before you "
            "reach it. It is a guarantee against accidental spoiling, not a "
            "security boundary: do not use it to keep a determined reader out "
            "of data they already hold."
        ),
    ),
    PrivacyPoint(
        id="arrival_sharing",
        title="Arrival sharing is off until you turn it on",
        body=(
            "Sharing an arrival lets a specific person see that you reached a "
            "specific plot point. It shares nothing else — not your live "
            "location, not your route — and it defaults to nothing shared. You "
            "choose each field and each person, and you can stop at any time."
        ),
    ),
    PrivacyPoint(
        id="author_notes",
        title="An Author's private notes about a Character",
        body=(
            "An Author can keep private notes about the people on a trip. Those "
            "notes are visible only to the Author who wrote them, they persist "
            "across trips, and the person they are about can ask to have them "
            "deleted. They are the first thing Plotlines holds about a person "
            "recorded by someone else, which is why this statement spells it out."
        ),
    ),
    PrivacyPoint(
        id="guest_sessions",
        title="Guest sessions leave no trace",
        body=(
            "Using Plotlines on the web without an account leaves nothing "
            "behind on the server once the session ends."
        ),
    ),
)


def privacy_statement() -> list[dict]:
    """The privacy statement (FR138) as a list of ``{id, title, body}`` dicts,
    in reading order."""
    return [point.as_dict() for point in PRIVACY_STATEMENT]


# --- the assembled surface ------------------------------------------------


@dataclass(frozen=True)
class AboutSurface:
    """Everything the About screen shows, assembled once (K10 + K11)."""

    app_version: str
    sidecar_version: str | None
    mode: str
    attributions: list[dict]
    attribution_complete: bool
    missing_attribution: list[str]
    privacy: list[dict]

    def as_dict(self) -> dict:
        out = {
            "app_version": self.app_version,
            "mode": self.mode,
            "attributions": self.attributions,
            "attribution_complete": self.attribution_complete,
            "missing_attribution": list(self.missing_attribution),
            "privacy": self.privacy,
        }
        # The sidecar version is a desktop-only field — it matches `/health`
        # and only exists where a sidecar is actually running (K10).
        if self.sidecar_version is not None:
            out["sidecar_version"] = self.sidecar_version
        return out


def build_about_surface(
    registry,
    *,
    app_version: str,
    sidecar_version: str | None = None,
    mode: str = "sidecar",
) -> AboutSurface:
    """Assemble the About surface payload (K10 + K11).

    ``attribution_complete`` is the release-gate answer: ``False`` with
    ``missing_attribution`` naming the offenders is a build failure, surfaced
    here rather than raised so the endpoint can still answer and the build
    check (:func:`assert_about_attribution_complete`) is the thing that fails.
    """
    try:
        attributions = assert_about_attribution_complete(registry)
        complete, missing = True, []
    except MissingAttributionError as exc:
        attributions = about_attributions(registry)
        complete = False
        missing = str(exc).split(": ", 1)[-1].split(", ")
    return AboutSurface(
        app_version=app_version,
        sidecar_version=sidecar_version,
        mode=mode,
        attributions=attributions,
        attribution_complete=complete,
        missing_attribution=missing,
        privacy=privacy_statement(),
    )
