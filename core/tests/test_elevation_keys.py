"""FR87 (issue #148) — OpenTopography key tiering and the free-tier legal
constraint.

Two clauses, enforced as refusals rather than warnings:

* the free non-academic key is capped at **50 calls / 24 h**, counted in a
  rolling window that survives a process restart;
* a **paid Enterprise key is required once elevation is integrated into
  commercial software** — a free-tier key under a commercial posture cannot
  even be constructed, let alone spent.

And the seam that keeps both compatible with FR88: a refusal is a fetch
failure, which the resolver reads as a miss and answers with a degraded
all-`0.0` sampler. Elevation degrades; planning never stops.
"""

from __future__ import annotations

import io
import json
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from plotlines_core.elevation.interface import OPENTOPO_BASE_URL, phase1_resolver
from plotlines_core.elevation.keys import (
    API_KEY_ENV,
    FREE_TIER_DAILY_CALL_CEILING,
    KEY_TIER_ENV,
    LEDGER_FILENAME,
    RATE_WINDOW,
    TIER_TERMS,
    CallLedger,
    DistributionPosture,
    ElevationKeyError,
    EnterpriseKeyRequired,
    FreeTierExhausted,
    KeyTier,
    MissingApiKey,
    OpenTopographyClient,
    OpenTopographyKey,
    PHASE1_POSTURE,
    TierTerms,
    check_posture,
    client_from_env,
)

_BBOX = (-82.7, 35.4, -82.3, 35.8)
_T0 = datetime(2026, 8, 30, 12, 0, tzinfo=timezone.utc)


def _free_key() -> OpenTopographyKey:
    return OpenTopographyKey(token="secret-token", tier=KeyTier.FREE_NON_ACADEMIC)


def _enterprise_key() -> OpenTopographyKey:
    return OpenTopographyKey(token="secret-token", tier=KeyTier.ENTERPRISE)


def _ledger(tmp_path: Path, key: OpenTopographyKey) -> CallLedger:
    return CallLedger(
        tmp_path / LEDGER_FILENAME, ceiling=key.effective_terms.daily_call_ceiling
    )


class _StubOpener:
    """Stands in for `urllib.request.build_opener()`. Records the URL it was
    handed so a test can assert the key travelled, without a network call."""

    def __init__(self, body: bytes = b"GTiff-bytes", error: Exception | None = None):
        self.body = body
        self.error = error
        self.urls: list[str] = []

    @contextmanager
    def open(self, url, timeout=None):  # noqa: A003 - mirrors urllib's name
        self.urls.append(url)
        if self.error is not None:
            raise self.error
        yield io.BytesIO(self.body)


# --------------------------------------------------------------------------- #
# Clause 1 — the 50 calls / 24 h ceiling                                       #
# --------------------------------------------------------------------------- #


def test_free_tier_terms_are_fr87s_numbers():
    terms = TIER_TERMS[KeyTier.FREE_NON_ACADEMIC]
    assert FREE_TIER_DAILY_CALL_CEILING == 50
    assert terms.daily_call_ceiling == 50
    assert terms.permits_commercial is False
    assert RATE_WINDOW == timedelta(hours=24)


def test_fiftieth_call_is_allowed_and_the_fifty_first_is_refused(tmp_path):
    ledger = _ledger(tmp_path, _free_key())
    for i in range(FREE_TIER_DAILY_CALL_CEILING):
        ledger.check(_T0 + timedelta(minutes=i))
        ledger.record(_T0 + timedelta(minutes=i))
    assert ledger.calls_in_window(_T0 + timedelta(hours=1)) == 50
    assert ledger.remaining(_T0 + timedelta(hours=1)) == 0

    with pytest.raises(FreeTierExhausted) as exc:
        ledger.check(_T0 + timedelta(hours=1))
    assert "50/50" in str(exc.value)


def test_the_window_rolls_so_calls_age_out_after_24h(tmp_path):
    ledger = _ledger(tmp_path, _free_key())
    for i in range(FREE_TIER_DAILY_CALL_CEILING):
        ledger.record(_T0 + timedelta(minutes=i))

    # One second before the first call ages out: still refused.
    just_before = _T0 + RATE_WINDOW - timedelta(seconds=1)
    with pytest.raises(FreeTierExhausted):
        ledger.check(just_before)

    # One second after: exactly one call has aged out, so exactly one is free.
    just_after = _T0 + RATE_WINDOW + timedelta(seconds=1)
    ledger.check(just_after)
    assert ledger.remaining(just_after) == 1


def test_next_free_at_is_when_the_oldest_in_window_call_expires(tmp_path):
    ledger = _ledger(tmp_path, _free_key())
    assert ledger.next_free_at(_T0) is None  # nothing spent
    for i in range(FREE_TIER_DAILY_CALL_CEILING):
        ledger.record(_T0 + timedelta(minutes=i))
    assert ledger.next_free_at(_T0 + timedelta(hours=1)) == _T0 + RATE_WINDOW


def test_the_ceiling_survives_a_process_restart(tmp_path):
    """A per-process counter would enforce nothing — the sidecar is spawned and
    killed with the client (ARCH §7.3)."""
    path = tmp_path / LEDGER_FILENAME
    first = CallLedger(path, ceiling=FREE_TIER_DAILY_CALL_CEILING)
    for i in range(FREE_TIER_DAILY_CALL_CEILING):
        first.record(_T0 + timedelta(minutes=i))

    reopened = CallLedger(path, ceiling=FREE_TIER_DAILY_CALL_CEILING)
    assert reopened.calls_in_window(_T0 + timedelta(hours=1)) == 50
    with pytest.raises(FreeTierExhausted):
        reopened.check(_T0 + timedelta(hours=1))


def test_ledger_stores_iso8601_utc_and_prunes_on_write(tmp_path):
    """ISO 8601 is the sole stored form (ARCH D49); aged-out calls are never
    written back."""
    path = tmp_path / LEDGER_FILENAME
    ledger = CallLedger(path, ceiling=FREE_TIER_DAILY_CALL_CEILING)
    ledger.record(_T0)
    ledger.record(_T0 + RATE_WINDOW + timedelta(hours=1))

    stamps = json.loads(path.read_text())["calls"]
    assert stamps == [(_T0 + RATE_WINDOW + timedelta(hours=1)).isoformat()]
    assert datetime.fromisoformat(stamps[0]).tzinfo is not None


def test_an_unreadable_ledger_is_treated_as_empty_not_fatal(tmp_path):
    """FR88: elevation never stops planning. A corrupt ledger re-earns the
    ceiling from now, which is the conservative direction on a fresh file."""
    path = tmp_path / LEDGER_FILENAME
    path.write_text("{ not json")
    ledger = CallLedger(path, ceiling=FREE_TIER_DAILY_CALL_CEILING)
    assert ledger.calls_in_window(_T0) == 0
    ledger.check(_T0)


def test_naive_timestamps_are_read_as_utc(tmp_path):
    path = tmp_path / LEDGER_FILENAME
    path.write_text(json.dumps({"calls": [_T0.replace(tzinfo=None).isoformat()]}))
    ledger = CallLedger(path, ceiling=FREE_TIER_DAILY_CALL_CEILING)
    assert ledger.calls_in_window(_T0 + timedelta(hours=1)) == 1


def test_an_uncapped_tier_has_no_ceiling_to_spend(tmp_path):
    ledger = _ledger(tmp_path, _enterprise_key())
    assert ledger.ceiling is None
    for i in range(FREE_TIER_DAILY_CALL_CEILING + 5):
        ledger.record(_T0 + timedelta(minutes=i))
    ledger.check(_T0 + timedelta(hours=1))
    assert ledger.remaining(_T0 + timedelta(hours=1)) is None
    assert ledger.next_free_at(_T0 + timedelta(hours=1)) is None


# --------------------------------------------------------------------------- #
# Clause 2 — commercial integration needs an Enterprise key                    #
# --------------------------------------------------------------------------- #


def test_free_tier_permits_the_free_core_app_posture():
    check_posture(TIER_TERMS[KeyTier.FREE_NON_ACADEMIC], DistributionPosture.FREE_CORE_APP)
    assert PHASE1_POSTURE is DistributionPosture.FREE_CORE_APP


def test_free_tier_under_a_commercial_posture_is_refused():
    with pytest.raises(EnterpriseKeyRequired) as exc:
        check_posture(
            TIER_TERMS[KeyTier.FREE_NON_ACADEMIC], DistributionPosture.COMMERCIAL
        )
    assert "Enterprise" in str(exc.value)


def test_enterprise_tier_permits_commercial():
    check_posture(TIER_TERMS[KeyTier.ENTERPRISE], DistributionPosture.COMMERCIAL)
    assert TIER_TERMS[KeyTier.ENTERPRISE].permits_commercial is True


def test_a_commercial_build_cannot_even_construct_a_free_tier_client(tmp_path):
    """Refused at construction, not at call time — a commercial build must not
    be able to hold a client it could spend from."""
    key = _free_key()
    with pytest.raises(EnterpriseKeyRequired):
        OpenTopographyClient(
            key, _ledger(tmp_path, key), posture=DistributionPosture.COMMERCIAL
        )


def test_a_commercial_build_with_an_enterprise_key_is_fine(tmp_path):
    key = _enterprise_key()
    client = OpenTopographyClient(
        key, _ledger(tmp_path, key), posture=DistributionPosture.COMMERCIAL
    )
    client.authorize()
    assert client.remaining_calls is None


def test_a_caller_may_supply_its_own_terms_rather_than_guess_a_tier(tmp_path):
    """The tier list is a seed set; a caller holding some other arrangement
    states both terms instead of picking the nearest-looking enum member."""
    key = OpenTopographyKey(
        token="t",
        tier=KeyTier.FREE_NON_ACADEMIC,
        terms=TierTerms(daily_call_ceiling=2000, permits_commercial=True),
    )
    client = OpenTopographyClient(
        key, _ledger(tmp_path, key), posture=DistributionPosture.COMMERCIAL
    )
    assert client.remaining_calls == 2000


# --------------------------------------------------------------------------- #
# The key itself                                                               #
# --------------------------------------------------------------------------- #


def test_the_key_never_appears_in_its_own_repr():
    key = _free_key()
    assert "secret-token" not in repr(key)
    assert "secret-token" not in str(key)
    assert "free-non-academic" in repr(key)


def test_an_empty_key_is_refused():
    with pytest.raises(MissingApiKey):
        OpenTopographyKey(token="   ")


def test_from_env_reads_key_and_tier():
    key = OpenTopographyKey.from_env(
        {API_KEY_ENV: " abc ", KEY_TIER_ENV: "enterprise"}
    )
    assert key.token == "abc"
    assert key.tier is KeyTier.ENTERPRISE


def test_from_env_defaults_to_the_free_tier():
    assert OpenTopographyKey.from_env({API_KEY_ENV: "abc"}).tier is KeyTier.FREE_NON_ACADEMIC


def test_from_env_without_a_key_raises_missing_not_a_silent_none():
    with pytest.raises(MissingApiKey):
        OpenTopographyKey.from_env({})


def test_an_unknown_tier_is_an_error_not_a_free_tier_default():
    """Defaulting an unrecognised tier to the free one would silently claim
    non-commercial use."""
    with pytest.raises(ElevationKeyError):
        OpenTopographyKey.from_env({API_KEY_ENV: "abc", KEY_TIER_ENV: "academic"})


def test_client_from_env_puts_the_ledger_beside_the_dem_cache(tmp_path):
    client = client_from_env(tmp_path, env={API_KEY_ENV: "abc"})
    assert client.ledger.path == tmp_path / LEDGER_FILENAME
    assert client.ledger.ceiling == FREE_TIER_DAILY_CALL_CEILING
    assert client.posture is PHASE1_POSTURE


# --------------------------------------------------------------------------- #
# Request shaping                                                              #
# --------------------------------------------------------------------------- #


def test_request_url_carries_the_bbox_the_key_and_the_pinned_demtype(tmp_path):
    key = _free_key()
    client = OpenTopographyClient(key, _ledger(tmp_path, key))
    url = client.request_url(_BBOX)
    assert "demtype=GEDTM30" in url  # D20's single source survives the merge
    assert "API_Key=secret-token" in url
    assert "west=-82.7" in url and "east=-82.3" in url
    assert "south=35.4" in url and "north=35.8" in url
    assert "outputFormat=GTiff" in url


def test_redacted_url_is_the_loggable_form(tmp_path):
    key = _free_key()
    client = OpenTopographyClient(key, _ledger(tmp_path, key))
    redacted = client.redacted_url(_BBOX)
    assert "secret-token" not in redacted
    assert "API_Key=%2A%2A%2A" in redacted or "API_Key=***" in redacted


def test_base_url_is_the_one_provider(tmp_path):
    key = _free_key()
    client = OpenTopographyClient(key, _ledger(tmp_path, key))
    assert client.base_url == OPENTOPO_BASE_URL


# --------------------------------------------------------------------------- #
# The fetch                                                                    #
# --------------------------------------------------------------------------- #


def test_fetch_writes_the_dem_and_spends_one_call(tmp_path):
    key = _free_key()
    ledger = _ledger(tmp_path, key)
    opener = _StubOpener()
    client = OpenTopographyClient(key, ledger, opener=opener)

    dest = tmp_path / "dem" / "out.tif"
    written = client.fetch(client.base_url, _BBOX, dest)

    assert written == dest
    assert dest.read_bytes() == b"GTiff-bytes"
    assert ledger.calls_in_window() == 1
    assert "API_Key=secret-token" in opener.urls[0]
    assert not list(dest.parent.glob("*.part"))


def test_a_failed_download_still_spends_the_call(tmp_path):
    """Over-counting is the safe direction for a licensing ceiling: a call the
    provider counted but that failed in transit is spent."""
    key = _free_key()
    ledger = _ledger(tmp_path, key)
    client = OpenTopographyClient(
        key, ledger, opener=_StubOpener(error=OSError("connection reset"))
    )
    with pytest.raises(OSError):
        client.fetch(client.base_url, _BBOX, tmp_path / "out.tif")
    assert ledger.calls_in_window() == 1


def test_an_exhausted_budget_refuses_before_the_wire(tmp_path):
    key = _free_key()
    ledger = _ledger(tmp_path, key)
    for i in range(FREE_TIER_DAILY_CALL_CEILING):
        ledger.record()
    opener = _StubOpener()
    client = OpenTopographyClient(key, ledger, opener=opener)

    with pytest.raises(FreeTierExhausted):
        client.fetch(client.base_url, _BBOX, tmp_path / "out.tif")
    assert opener.urls == []  # no request left the process
    assert ledger.calls_in_window() == 50  # and the refusal spent nothing


# --------------------------------------------------------------------------- #
# The seam: FR87 refusals degrade elevation, they never stop planning (FR88)   #
# --------------------------------------------------------------------------- #


def test_as_fetcher_wires_into_phase1_and_the_cache_absorbs_repeat_bboxes(tmp_path):
    """50 calls/24 h is 50 *new bboxes*, not 50 solves — LocalCacheSource sits
    ahead of the provider in every phase (ARCH P7)."""
    key = _free_key()
    ledger = _ledger(tmp_path, key)
    opener = _StubOpener()
    client = OpenTopographyClient(key, ledger, opener=opener)
    resolver = phase1_resolver(tmp_path / "dem", fetch=client.as_fetcher())

    first = resolver.resolve(_BBOX)
    assert first.source == "direct-provider"
    second = resolver.resolve(_BBOX)
    assert second.source == "local-cache"

    assert len(opener.urls) == 1
    assert ledger.calls_in_window() == 1
    assert ledger.remaining() == 49


def test_an_exhausted_budget_degrades_the_sampler_instead_of_raising(tmp_path):
    """The refusal reaches `HttpElevationSource` as a fetch failure, which is a
    miss; `sampler_for` then hands back a degraded all-`0.0` sampler."""
    key = _free_key()
    ledger = _ledger(tmp_path, key)
    for _ in range(FREE_TIER_DAILY_CALL_CEILING):
        ledger.record()
    client = OpenTopographyClient(key, ledger, opener=_StubOpener())
    resolver = phase1_resolver(tmp_path / "dem", fetch=client.as_fetcher())

    sampler = resolver.sampler_for(_BBOX)
    assert sampler.degraded
    assert list(sampler.sample([(35.5, -82.5)])) == [0.0]
