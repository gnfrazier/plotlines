"""OpenTopography key tiering and the free-tier legal constraint (PRD FR87,
ARCH §12 / A13 / D20; issue #148).

FR87 is a **licensing** requirement wearing a rate limit's clothes. Two clauses,
and only the first one looks like engineering:

1. OpenTopography's free non-academic API key is capped at **50 calls / 24 h**.
2. A **paid Enterprise key is required once elevation is integrated into
   commercial software** — Plotlines' core app remaining free is what keeps
   Phase-1 usage inside the free tier *legally*.

Clause 2 is the one that cannot be recovered from after the fact: exceeding a
rate limit gets a request refused, but shipping GEDTM30 inside paid software on
a free key is a licence breach that no later retry fixes. So both clauses are
enforced the same way — **refused, not warned** (the same posture as the tile
mirror's `HotlinkRefused`, `tiles.mirror`), and refused *before* the request is
made rather than after the provider notices.

What that buys, mechanically:

* :class:`OpenTopographyClient` authorises every call against the key's tier and
  the distribution posture. A free-tier key under
  :data:`DistributionPosture.COMMERCIAL` raises
  :class:`EnterpriseKeyRequired` — no request leaves the process, so a
  commercial build cannot silently spend free-tier calls.
* :class:`CallLedger` holds the rolling 24-hour window on disk next to the DEM
  cache, so the ceiling survives a sidecar restart. A per-process counter would
  enforce nothing: the cap is per key per day, and the sidecar is a
  short-lived, user-launched process (ARCH §7.3).
* The ceiling is survivable at all only because
  :class:`~plotlines_core.elevation.interface.LocalCacheSource` sits *ahead* of
  the provider in every phase (ARCH P7 — "fetch once, cache, never re-request
  what is held"). 50 calls/24 h is 50 *new bboxes*, not 50 route solves.

FR88 still holds over the top of this. Refusals surface as a fetch failure,
which :class:`~plotlines_core.elevation.interface.HttpElevationSource` reads as
a miss; the resolver then hands back a degraded all-`0.0` sampler. **A spent
budget or a licensing refusal degrades elevation — it never stops planning and
never reaches a solve.**

Nothing here logs the key. `OpenTopographyKey` redacts its own `repr`, and
`redacted_url` is the only URL form fit for a log line, because the token
travels as a query parameter (`API_Key=`) and a traceback that quotes the
request URL would otherwise leak it.
"""

from __future__ import annotations

import enum
import json
import logging
import os
import shutil
import tempfile
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable, Mapping
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from plotlines_core.elevation.interface import BBox, Fetcher, OPENTOPO_BASE_URL

logger = logging.getLogger("plotlines.elevation")

#: FR87's number. The free non-academic key's ceiling, in calls per 24 hours.
FREE_TIER_DAILY_CALL_CEILING = 50

#: The window the ceiling is measured over. Rolling, not calendar-day: a rolling
#: 24 h window is never *more* permissive than a midnight reset, so enforcing it
#: cannot overshoot the provider's own accounting whichever way OpenTopography
#: measures it. Being conservative is the correct error direction for a clause
#: whose failure mode is a licence breach.
RATE_WINDOW = timedelta(hours=24)

#: Where the ledger lives when the caller passes only a cache directory. Sits
#: beside the bbox-scoped DEMs it accounts for.
LEDGER_FILENAME = "opentopography_calls.json"

#: Environment variables the key is read from. `from_env` is the only place
#: these names appear, so a rename is one edit.
API_KEY_ENV = "PLOTLINES_OPENTOPOGRAPHY_API_KEY"
KEY_TIER_ENV = "PLOTLINES_OPENTOPOGRAPHY_KEY_TIER"

#: OpenTopography's terms — the document both clauses of FR87 come from.
OPENTOPO_TERMS_URL = "https://opentopography.org/usageterms"


class ElevationKeyError(RuntimeError):
    """Base for every refusal in this module, so a caller that only wants to
    degrade elevation catches one type."""


class MissingApiKey(ElevationKeyError):
    """No OpenTopography key is configured. Acquisition is off; the local cache
    and the shipped region tarball (FR90) still work."""


class EnterpriseKeyRequired(ElevationKeyError):
    """FR87 clause 2: the key's tier does not permit the current distribution
    posture. Buying an Enterprise key is the *only* remedy — this is not a
    retryable condition and must never be retried as one."""


class FreeTierExhausted(ElevationKeyError):
    """FR87 clause 1: the rolling 24 h ceiling for this key is spent. Retryable,
    but only after calls age out of the window."""


class KeyTier(enum.Enum):
    """OpenTopography key tiers Plotlines can hold.

    **The rule behind this list** (seed-set discipline, punch-list §0): a tier is
    admissible here only when *both* of its terms are stated in
    :data:`TIER_TERMS` — the daily call ceiling OpenTopography grants it, and
    whether it permits integration into software that is sold. A tier added
    without both is the §0 failure in its highest-consequence form, because the
    missing term defaults to the permissive reading and the breach is silent.
    FR87 names these two; a caller holding some other arrangement passes its own
    :class:`TierTerms` to :class:`OpenTopographyKey` rather than guessing which
    of these it resembles.
    """

    FREE_NON_ACADEMIC = "free-non-academic"
    ENTERPRISE = "enterprise"


@dataclass(frozen=True)
class TierTerms:
    """What a tier grants. Both fields are required — see :class:`KeyTier`.

    `daily_call_ceiling` of ``None`` means *no ceiling fixed by FR87*; the key's
    own contract governs, and Plotlines does not invent a number to enforce.
    """

    daily_call_ceiling: int | None
    permits_commercial: bool


TIER_TERMS: Mapping[KeyTier, TierTerms] = {
    KeyTier.FREE_NON_ACADEMIC: TierTerms(
        daily_call_ceiling=FREE_TIER_DAILY_CALL_CEILING, permits_commercial=False
    ),
    KeyTier.ENTERPRISE: TierTerms(daily_call_ceiling=None, permits_commercial=True),
}


class DistributionPosture(enum.Enum):
    """How the software holding this key is distributed.

    The distinction FR87 draws is *commercial integration*, not revenue in the
    abstract: `FREE_CORE_APP` is the posture in which the elevation-carrying
    application is free to use, which is the condition the free tier is granted
    under. Anything that puts elevation behind a payment — sold builds, a paid
    tier that unlocks elevation, a hosted plan whose price includes it — is
    `COMMERCIAL` and needs an Enterprise key first (ARCH A13: "a paid tier
    anywhere requires re-licensing elevation first").
    """

    FREE_CORE_APP = "free-core-app"
    COMMERCIAL = "commercial"


#: Phase 1's posture, stated once so it is a constant to change deliberately
#: rather than a default nobody revisits. ARCH §12.1 marks the Phase-1 direct
#: -to-provider path "EXPLICITLY DISPOSABLE"; this is the licensing half of the
#: same statement.
PHASE1_POSTURE = DistributionPosture.FREE_CORE_APP


def check_posture(terms: TierTerms, posture: DistributionPosture) -> None:
    """FR87 clause 2. Raise :class:`EnterpriseKeyRequired` if `terms` does not
    permit `posture`. Called before every request and safe to call anywhere
    else — it touches nothing."""
    if posture is DistributionPosture.COMMERCIAL and not terms.permits_commercial:
        raise EnterpriseKeyRequired(
            "this OpenTopography key does not permit commercial distribution: "
            "FR87 requires a paid Enterprise key once elevation is integrated "
            "into commercial software. Plotlines' core app remaining free is "
            f"what keeps free-tier use legal. See {OPENTOPO_TERMS_URL}."
        )


@dataclass(frozen=True)
class OpenTopographyKey:
    """An API key plus the tier it was issued under.

    `repr` is redacted: the token would otherwise reach any log line or
    traceback that prints the client, the resolver, or a dataclass holding it.
    """

    token: str
    tier: KeyTier = KeyTier.FREE_NON_ACADEMIC
    terms: TierTerms | None = None

    def __post_init__(self) -> None:
        if not self.token or not self.token.strip():
            raise MissingApiKey("OpenTopography API key is empty")

    @property
    def effective_terms(self) -> TierTerms:
        """The key's own terms if supplied, else its tier's."""
        return self.terms if self.terms is not None else TIER_TERMS[self.tier]

    def __repr__(self) -> str:  # pragma: no cover - exercised via str()
        return f"OpenTopographyKey(token='***', tier={self.tier.value!r})"

    __str__ = __repr__

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "OpenTopographyKey":
        """Read the key from the environment.

        Raises :class:`MissingApiKey` when unset — acquisition is opt-in, and a
        caller that wants "no key means no fetching" catches that rather than
        receiving a `None` it has to remember to check. An unrecognised tier is
        a hard error too: defaulting an unknown tier to the free one would
        silently claim non-commercial use.
        """
        env = os.environ if env is None else env
        token = (env.get(API_KEY_ENV) or "").strip()
        if not token:
            raise MissingApiKey(
                f"{API_KEY_ENV} is not set — OpenTopography acquisition is off. "
                "The local DEM cache and the shipped region tarball (FR90) are "
                "unaffected."
            )
        raw_tier = (env.get(KEY_TIER_ENV) or KeyTier.FREE_NON_ACADEMIC.value).strip()
        try:
            tier = KeyTier(raw_tier)
        except ValueError:
            known = ", ".join(t.value for t in KeyTier)
            raise ElevationKeyError(
                f"{KEY_TIER_ENV}={raw_tier!r} is not a known OpenTopography key "
                f"tier (known: {known})"
            ) from None
        return cls(token=token, tier=tier)


@dataclass
class CallLedger:
    """The rolling 24 h call window for one key, persisted as JSON.

    On disk so the ceiling survives a sidecar restart (ARCH §7.3 — the sidecar
    is spawned and killed with the client). Timestamps are stored as UTC ISO
    8601, the only stored form (ARCH D49); entries older than
    :data:`RATE_WINDOW` are pruned on every read and never written back.

    Single-writer: one sidecar owns one cache directory. Two Plotlines
    processes sharing a cache directory could each read 49 and both write, which
    is why `record` rewrites the whole file from the pruned list rather than
    appending — a lost update costs at most the concurrent calls, never a
    corrupt ledger.
    """

    path: Path
    ceiling: int | None = FREE_TIER_DAILY_CALL_CEILING
    _calls: list[datetime] = field(default_factory=list, init=False, repr=False)
    _loaded: bool = field(default=False, init=False, repr=False)

    def __post_init__(self) -> None:
        self.path = Path(self.path)

    # -- persistence ------------------------------------------------------- #

    def _load(self) -> None:
        if self._loaded:
            return
        self._loaded = True
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
            stamps = raw["calls"]
        except (OSError, ValueError, KeyError, TypeError):
            # A missing ledger is the normal first-run state. An unreadable or
            # malformed one is treated as empty rather than fatal: elevation
            # never stops planning (FR88), and the ceiling is re-earned from
            # now, which is the conservative direction on a fresh file.
            self._calls = []
            return
        self._calls = [t for t in (_parse_stamp(s) for s in stamps) if t is not None]

    def _save(self, calls: Iterable[datetime]) -> None:
        payload = {"calls": [c.isoformat() for c in calls]}
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload), encoding="utf-8")
        tmp.replace(self.path)

    # -- window ------------------------------------------------------------ #

    def _window(self, now: datetime) -> list[datetime]:
        self._load()
        cutoff = now - RATE_WINDOW
        self._calls = sorted(c for c in self._calls if c > cutoff)
        return self._calls

    def calls_in_window(self, now: datetime | None = None) -> int:
        """How many calls this key has spent in the last :data:`RATE_WINDOW`."""
        return len(self._window(_utcnow(now)))

    def remaining(self, now: datetime | None = None) -> int | None:
        """Calls left in the window, or ``None`` for an uncapped tier."""
        if self.ceiling is None:
            return None
        return max(0, self.ceiling - self.calls_in_window(now))

    def next_free_at(self, now: datetime | None = None) -> datetime | None:
        """When the oldest in-window call ages out — the earliest a refused
        caller could succeed. ``None`` when nothing is spent or uncapped."""
        if self.ceiling is None:
            return None
        window = self._window(_utcnow(now))
        if len(window) < self.ceiling:
            return None
        return window[len(window) - self.ceiling] + RATE_WINDOW

    def check(self, now: datetime | None = None) -> None:
        """FR87 clause 1. Raise :class:`FreeTierExhausted` when the ceiling is
        spent."""
        if self.ceiling is None:
            return
        now = _utcnow(now)
        spent = self.calls_in_window(now)
        if spent >= self.ceiling:
            free_at = self.next_free_at(now)
            raise FreeTierExhausted(
                f"OpenTopography free-tier ceiling reached: {spent}/{self.ceiling} "
                f"calls in the last 24 h (FR87). Next call available "
                f"{free_at.isoformat() if free_at else 'unknown'}. Cached DEMs "
                "are unaffected; uncached bboxes fall back to flat elevation."
            )

    def record(self, now: datetime | None = None) -> None:
        """Spend one call. Written before the request is issued — a call the
        provider counted but that failed in transit is still spent, and
        over-counting is the safe direction for a licensing ceiling."""
        now = _utcnow(now)
        window = self._window(now)
        window.append(now)
        self._save(window)


def _utcnow(now: datetime | None) -> datetime:
    if now is None:
        return datetime.now(timezone.utc)
    return now if now.tzinfo is not None else now.replace(tzinfo=timezone.utc)


def _parse_stamp(raw: object) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(str(raw))
    except (TypeError, ValueError):
        return None
    return parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=timezone.utc)


class OpenTopographyClient:
    """The one place an OpenTopography request is authorised and issued.

    `fetch` matches :data:`~plotlines_core.elevation.interface.Fetcher`, so
    :func:`~plotlines_core.elevation.interface.phase1_resolver` is wired by
    passing :meth:`as_fetcher` — the resolver, the sources and the cache stay
    byte-identical between phases (M3's invariant), and this class is the only
    thing that knows a key exists.
    """

    def __init__(
        self,
        key: OpenTopographyKey,
        ledger: CallLedger,
        *,
        posture: DistributionPosture = PHASE1_POSTURE,
        base_url: str = OPENTOPO_BASE_URL,
        opener: "urllib.request.OpenerDirector | None" = None,
        timeout_s: float = 120.0,
    ):
        self.key = key
        self.ledger = ledger
        self.posture = posture
        self.base_url = base_url
        self.timeout_s = timeout_s
        self._opener = opener
        # Clause 2 is a property of the build, not of a request: refuse at
        # construction so a commercial build cannot even hold a free-tier
        # client, let alone reach a call site that spends from it.
        check_posture(key.effective_terms, posture)

    # -- authorisation ------------------------------------------------------ #

    def authorize(self, now: datetime | None = None) -> None:
        """Both FR87 clauses, in the order they can fail. Raises
        :class:`EnterpriseKeyRequired` or :class:`FreeTierExhausted`."""
        check_posture(self.key.effective_terms, self.posture)
        self.ledger.check(now)

    @property
    def remaining_calls(self) -> int | None:
        """Calls left in the rolling window; ``None`` on an uncapped tier."""
        return self.ledger.remaining()

    # -- request shaping ---------------------------------------------------- #

    def request_url(self, bbox: BBox, *, base_url: str | None = None) -> str:
        """The GEDTM30 request URL for `bbox`, key included.

        **Never log this** — the token is a query parameter. Use
        :meth:`redacted_url`.
        """
        return _build_url(base_url or self.base_url, bbox, self.key.token)

    def redacted_url(self, bbox: BBox, *, base_url: str | None = None) -> str:
        """:meth:`request_url` with the key replaced — the loggable form."""
        return _build_url(base_url or self.base_url, bbox, "***")

    # -- the fetch ---------------------------------------------------------- #

    def fetch(self, base_url: str, bbox: BBox, dest: Path) -> Path:
        """Download the DEM covering `bbox` to `dest`.

        Signature matches :data:`~plotlines_core.elevation.interface.Fetcher`,
        so `HttpElevationSource` reads any refusal here as a cache miss and the
        resolver degrades rather than raising (FR88).
        """
        self.authorize()
        # Spent before the wire, not after: see `CallLedger.record`.
        self.ledger.record()
        url = _build_url(base_url, bbox, self.key.token)
        dest = Path(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        opener = self._opener or urllib.request.build_opener()
        logger.info(
            "elevation: fetching %s (remaining free-tier calls: %s)",
            self.redacted_url(bbox, base_url=base_url),
            self.remaining_calls,
        )
        with opener.open(url, timeout=self.timeout_s) as response:
            with tempfile.NamedTemporaryFile(
                dir=str(dest.parent), suffix=".part", delete=False
            ) as tmp:
                tmp_path = Path(tmp.name)
                shutil.copyfileobj(response, tmp)
        tmp_path.replace(dest)
        return dest

    def as_fetcher(self) -> Fetcher:
        """This client as the callable `phase1_resolver(fetch=...)` wants."""
        return self.fetch


def _build_url(base_url: str, bbox: BBox, token: str) -> str:
    """Merge the bbox and key into `base_url`'s query, preserving whatever it
    already carries (`demtype=GEDTM30` lives in
    :data:`~plotlines_core.elevation.interface.OPENTOPO_BASE_URL`)."""
    min_lon, min_lat, max_lon, max_lat = bbox
    parts = urlsplit(base_url)
    query = dict(parse_qsl(parts.query, keep_blank_values=True))
    query.update(
        {
            "south": f"{min_lat}",
            "north": f"{max_lat}",
            "west": f"{min_lon}",
            "east": f"{max_lon}",
            "outputFormat": "GTiff",
            "API_Key": token,
        }
    )
    return urlunsplit(
        (parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment)
    )


def client_from_env(
    cache_dir: str | Path,
    *,
    env: Mapping[str, str] | None = None,
    posture: DistributionPosture = PHASE1_POSTURE,
    base_url: str = OPENTOPO_BASE_URL,
) -> OpenTopographyClient:
    """Build a client from the environment with its ledger beside the DEM cache.

    Raises :class:`MissingApiKey` when no key is configured and
    :class:`EnterpriseKeyRequired` when the configured key cannot legally serve
    `posture` — both of which a caller handles by wiring
    :func:`~plotlines_core.elevation.interface.phase1_resolver` with no fetcher,
    leaving the local cache as the only source.
    """
    key = OpenTopographyKey.from_env(env)
    ledger = CallLedger(
        Path(cache_dir) / LEDGER_FILENAME,
        ceiling=key.effective_terms.daily_call_ceiling,
    )
    return OpenTopographyClient(key, ledger, posture=posture, base_url=base_url)
