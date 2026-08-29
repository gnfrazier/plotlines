"""SPIKE-13 — the bar, declared before any email is sent.

Magic-link-only auth has no password fallback (ARCH D9). The question this spike
answers is not "does email mostly work" — it is "does it work well enough that a
user's *only* way into their account can depend on it". That is a higher bar than
marketing email, and it has to be written down before the numbers arrive, or the
run will just be graded against whatever it produced (the SPIKE-C / SPIKE-21
discipline: the threshold is a pre-registration, not a posthoc fit).

Three bands, and the middle one is the one that matters, because it is the one the
"Done when" clause names: *"or the gap is documented so the auth approach can add a
fallback before Web ships."*

    STAKE     — inbox delivery is good enough to be the sole path. Ship K1 as the
                PRD writes it: magic link is the only auth *and* the only recovery.
    FALLBACK  — delivery is good on the median and ragged in the tail / on one
                host. Ship K1, but with a documented backup: in-product re-send
                with backoff, a support-issued link, and a link TTL long enough to
                outlast greylisting. This is the branch this spike lands on.
    BLOCK     — a major consumer host drops or spam-files login mail often enough
                that no fallback short of "add a password" rescues it. Web does not
                ship on magic-link-only.

Every figure is measured per host and rolled up. A great overall number with Yahoo
at 60% inbox is a BLOCK, not a STAKE — the rollup can never launder one bad host,
because a user does not get to pick their mail provider when they sign up.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class Band(str, Enum):
    STAKE = "stake"
    FALLBACK = "fallback"
    BLOCK = "block"


# The major consumer mail hosts a US/EU launch has to clear. A login that only
# works for Gmail is not a login. Corporate Google Workspace / M365 tenants are
# tracked separately (they have their own inbound filtering) but are not launch
# gates — an org admin can allowlist a sender; a consumer cannot.
MAJOR_CONSUMER_HOSTS = (
    "gmail",       # Google consumer
    "microsoft",   # outlook.com / hotmail.com / live.com — one filter behind all three
    "yahoo",       # Yahoo / AOL — one filter since 2017
    "icloud",      # Apple — me.com / mac.com
    "proton",      # Proton Mail
    "fastmail",    # Fastmail — small share, but its users are exactly Plotlines' users
)


@dataclass(frozen=True)
class BandCriteria:
    """A band's numeric gate. All conditions must hold for the band to be met."""

    min_inbox_rate: float          # fraction landing in the inbox (NOT spam, NOT missing)
    max_spam_rate: float           # fraction landing in the spam/junk folder
    max_missing_rate: float        # fraction never observed within the wait window
    max_p50_seconds: float         # median time from send to inbox arrival
    max_p95_seconds: float         # tail time from send to inbox arrival
    # Applied to the per-host figures, not just the rollup:
    min_per_host_inbox_rate: float
    max_per_host_spam_rate: float


# --- the pre-registered numbers -------------------------------------------------
#
# Rationale for each, so a later reader can argue with the number and not just the
# verdict:
#
#  inbox rate 99% / 97%  — a magic link that fails 1 in 100 sends is a support
#      ticket per 100 logins; 1 in 33 is a broken product. SES/Postmark publish
#      transactional inbox rates in the 99%+ range on a warmed domain, so 99% is
#      not aspirational.
#  spam rate 1% / 3%     — spam placement is worse than a bounce: no error is
#      surfaced, the user just waits. Kept tight.
#  time p50 10s / p95 30s (STAKE) — the user is sitting on the "check your email"
#      screen. Anything past ~30s and they assume it failed and re-request, which
#      is why FALLBACK still needs the re-send to be idempotent.
#  FALLBACK p95 90s      — tolerates one greylisting round-trip (a 60s deferral is
#      common) as long as the median is still fast.

STAKE_CRITERIA = BandCriteria(
    min_inbox_rate=0.99,
    max_spam_rate=0.01,
    max_missing_rate=0.005,
    max_p50_seconds=10.0,
    max_p95_seconds=30.0,
    min_per_host_inbox_rate=0.98,
    max_per_host_spam_rate=0.02,
)

FALLBACK_CRITERIA = BandCriteria(
    min_inbox_rate=0.97,
    max_spam_rate=0.03,
    max_missing_rate=0.02,
    max_p50_seconds=15.0,
    max_p95_seconds=90.0,
    min_per_host_inbox_rate=0.95,
    max_per_host_spam_rate=0.05,
)


@dataclass(frozen=True)
class HostResult:
    host: str
    inbox_rate: float
    spam_rate: float
    missing_rate: float


@dataclass(frozen=True)
class Rollup:
    inbox_rate: float
    spam_rate: float
    missing_rate: float
    p50_seconds: float
    p95_seconds: float
    per_host: tuple[HostResult, ...]


def _meets(c: BandCriteria, r: Rollup) -> bool:
    if not (
        r.inbox_rate >= c.min_inbox_rate
        and r.spam_rate <= c.max_spam_rate
        and r.missing_rate <= c.max_missing_rate
        and r.p50_seconds <= c.max_p50_seconds
        and r.p95_seconds <= c.max_p95_seconds
    ):
        return False
    # The rollup can never launder a single bad host.
    for h in r.per_host:
        if h.host not in MAJOR_CONSUMER_HOSTS:
            continue
        if h.inbox_rate < c.min_per_host_inbox_rate:
            return False
        if h.spam_rate > c.max_per_host_spam_rate:
            return False
    return True


def classify(r: Rollup) -> Band:
    """Grade a completed run against the pre-registered bands."""
    if _meets(STAKE_CRITERIA, r):
        return Band.STAKE
    if _meets(FALLBACK_CRITERIA, r):
        return Band.FALLBACK
    return Band.BLOCK


def unmet_reasons(c: BandCriteria, r: Rollup) -> list[str]:
    """Human-readable list of why `r` fails criteria `c` — for the writeup."""
    out: list[str] = []
    if r.inbox_rate < c.min_inbox_rate:
        out.append(f"overall inbox rate {r.inbox_rate:.1%} < {c.min_inbox_rate:.0%}")
    if r.spam_rate > c.max_spam_rate:
        out.append(f"overall spam rate {r.spam_rate:.1%} > {c.max_spam_rate:.0%}")
    if r.missing_rate > c.max_missing_rate:
        out.append(f"overall missing rate {r.missing_rate:.1%} > {c.max_missing_rate:.1%}")
    if r.p50_seconds > c.max_p50_seconds:
        out.append(f"p50 {r.p50_seconds:.0f}s > {c.max_p50_seconds:.0f}s")
    if r.p95_seconds > c.max_p95_seconds:
        out.append(f"p95 {r.p95_seconds:.0f}s > {c.max_p95_seconds:.0f}s")
    for h in r.per_host:
        if h.host not in MAJOR_CONSUMER_HOSTS:
            continue
        if h.inbox_rate < c.min_per_host_inbox_rate:
            out.append(
                f"{h.host} inbox rate {h.inbox_rate:.1%} < {c.min_per_host_inbox_rate:.0%}"
            )
        if h.spam_rate > c.max_per_host_spam_rate:
            out.append(
                f"{h.host} spam rate {h.spam_rate:.1%} > {c.max_per_host_spam_rate:.0%}"
            )
    return out
