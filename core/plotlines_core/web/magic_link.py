"""Magic-link auth primitive — story K1 (issue #107), PRD FR57, ARCH D9.

Passwordless sign-in and the **only** credential path. There is deliberately no
password and no SMS-OTP method on this module: `SUPPORTS_PASSWORD` and
`SUPPORTS_SMS_OTP` are `False` and there is nothing to call. Local/sidecar
planning never reaches this code at all — `plotlines-service` registers no
``/auth/*`` route in sidecar mode (ARCH §7.1) — so FR57's "local planning works
immediately; only account-scoped surfaces wait on sign-in" holds by structure,
not by a guard here.

SPIKE-13 (2026-08-29) reshaped what K1 has to provide. Magic-link email on a
warmed custom domain sits at the STAKE/FALLBACK boundary, not at STAKE, so
magic-link-*only* is not safe as the sole way in and out of an account. This
module therefore ships the fallback the spike specified:

  * **Re-send with a visible cooldown.** :meth:`MagicLinkAuthenticator.request`
    for an address that already has a live, unconsumed link inside the cooldown
    window raises :class:`ResendCooldownError` carrying ``retry_after`` for the
    UI to render. Past the cooldown a re-send issues a fresh link and the prior
    link stays valid until it expires or is consumed, so a re-request never
    strands the user between two links (SPIKE-13 "keep both valid within the
    TTL").
  * **Link TTL >= 15 min** (:data:`MIN_LINK_TTL`), enforced as a floor: a
    shorter ``link_ttl`` on the policy is raised to the floor so a greylisting
    deferral (commonly 1-15 min on first contact between two domains) cannot
    expire the link before it arrives.
  * **Support-issued recovery link.** ``request(..., issued_by_support="...")``
    is the identity-checked manual path that replaces "reset your password": it
    bypasses the cooldown, records who issued it, and takes its own (longer)
    TTL.
  * **Delivery-telemetry fields.** Every :class:`IssuedLink` carries a
    non-secret ``token_id`` and ``requested_at`` so the provider-side
    (Postmark) delivered / bounced / spam-complaint webhook can be reconciled
    against an issue. The provider adapter itself is wired at the Web leg.

Tokens are opaque, high-entropy (``secrets.token_urlsafe``) and **only their
SHA-256 hash is stored** — the same shape as the M4 session-cookie seam: the
plaintext exists once, in the email, and never at rest. Consumption is
single-use and idempotent within :data:`IDEMPOTENCY_WINDOW` — a double click on
the link returns the same identity rather than an error, but a stale link
presented later is rejected.

This module is pure data + plain Python (P1: no fastapi). It holds issued links
in memory; a hosted deployment substitutes a shared store with the same method
shape.
"""

from __future__ import annotations

import hashlib
import secrets
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field, replace
from datetime import datetime, timedelta, timezone

__all__ = [
    "SUPPORTS_PASSWORD",
    "SUPPORTS_SMS_OTP",
    "MIN_LINK_TTL",
    "DEFAULT_LINK_TTL",
    "DEFAULT_SUPPORT_LINK_TTL",
    "DEFAULT_RESEND_COOLDOWN",
    "IDEMPOTENCY_WINDOW",
    "TOKEN_BYTES",
    "MagicLinkError",
    "InvalidEmailError",
    "ResendCooldownError",
    "InvalidTokenError",
    "TokenExpiredError",
    "TokenAlreadyUsedError",
    "MagicLinkPolicy",
    "IssuedLink",
    "Identity",
    "MagicLinkAuthenticator",
    "normalize_email",
]

# FR57 / K1 acceptance criteria, made assertable: magic link is the only auth
# and there is no password / no SMS OTP. These are not switches — nothing in the
# module reads them — they exist so a test (and a reader) can pin the guarantee.
SUPPORTS_PASSWORD = False
SUPPORTS_SMS_OTP = False

#: SPIKE-13: link TTL floor. A greylisting deferral on first contact between two
#: mail domains is commonly 1-15 min; a link that expires inside that window is
#: unusable through no fault of the user.
MIN_LINK_TTL = timedelta(minutes=15)

DEFAULT_LINK_TTL = timedelta(minutes=30)
DEFAULT_SUPPORT_LINK_TTL = timedelta(hours=24)
DEFAULT_RESEND_COOLDOWN = timedelta(seconds=60)

#: A link click that reaches the verify path twice (mail-client prefetch, a
#: double tap, a browser retry) inside this window returns the same identity
#: rather than "already used".
IDEMPOTENCY_WINDOW = timedelta(minutes=5)

#: Bytes of entropy for ``secrets.token_urlsafe``; the urlsafe encoding yields a
#: longer string. 32 bytes = 256 bits.
TOKEN_BYTES = 32


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def normalize_email(raw: str) -> str:
    """Lower-case and trim an address for use as the account key.

    Intentionally minimal — this is a store key, not an RFC 5322 validator. It
    rejects only the obviously unusable (empty, no ``@``, whitespace inside, or
    an empty local/domain part) so a typo does not silently create a distinct
    account that no link can ever reach.
    """
    email = raw.strip().lower()
    if not email or any(ch.isspace() for ch in email):
        raise InvalidEmailError(raw)
    local, sep, domain = email.partition("@")
    if not sep or not local or not domain or "." not in domain:
        raise InvalidEmailError(raw)
    return email


class MagicLinkError(Exception):
    """Base for every failure this module raises."""


class InvalidEmailError(MagicLinkError):
    def __init__(self, value: str) -> None:
        super().__init__(f"not a usable email address: {value!r}")
        self.value = value


class ResendCooldownError(MagicLinkError):
    """A re-send was requested before the cooldown elapsed.

    ``retry_after`` is what the UI renders as the visible cooldown.
    """

    def __init__(self, email: str, retry_after: timedelta) -> None:
        secs = max(0, round(retry_after.total_seconds()))
        super().__init__(f"resend available in {secs}s")
        self.email = email
        self.retry_after = retry_after


class InvalidTokenError(MagicLinkError):
    """The presented token matches no issued link (wrong, truncated, forged)."""


class TokenExpiredError(MagicLinkError):
    """The link was valid but its TTL has elapsed. Re-send to get a new one."""


class TokenAlreadyUsedError(MagicLinkError):
    """The link was already consumed, outside the idempotency window."""


@dataclass(frozen=True)
class MagicLinkPolicy:
    """Timing knobs for one authenticator. Plain data.

    ``link_ttl`` and ``support_link_ttl`` are clamped up to :data:`MIN_LINK_TTL`
    on construction — the floor is not negotiable (SPIKE-13). ``resend_cooldown``
    of zero disables the cooldown (useful in tests).

    **Frozen**, and that is load-bearing rather than stylistic. While this was a
    mutable dataclass the clamp in ``__post_init__`` was the only thing enforcing
    the floor, so a plain ``policy.link_ttl = timedelta(seconds=1)`` after
    construction walked straight past it and issued a link that a greylisting
    deferral would outlive — the exact failure the floor exists to prevent. Same
    shape as :class:`~plotlines_core.web.session.SessionCookiePolicy`, and for
    the same reason: a contract a call site can quietly opt out of is not a
    contract. Use :meth:`evolve` to derive a variant.
    """

    link_ttl: timedelta = DEFAULT_LINK_TTL
    support_link_ttl: timedelta = DEFAULT_SUPPORT_LINK_TTL
    resend_cooldown: timedelta = DEFAULT_RESEND_COOLDOWN
    idempotency_window: timedelta = IDEMPOTENCY_WINDOW
    token_bytes: int = TOKEN_BYTES

    def __post_init__(self) -> None:
        if self.token_bytes < 16:
            raise ValueError("token_bytes must be >= 16 (128 bits)")
        if self.resend_cooldown < timedelta(0):
            raise ValueError("resend_cooldown must not be negative")
        if self.idempotency_window < timedelta(0):
            raise ValueError("idempotency_window must not be negative")
        object.__setattr__(self, "link_ttl", max(self.link_ttl, MIN_LINK_TTL))
        object.__setattr__(
            self, "support_link_ttl", max(self.support_link_ttl, MIN_LINK_TTL)
        )

    def evolve(self, **changes) -> "MagicLinkPolicy":
        """A copy with ``changes`` applied — re-validated and re-clamped, which
        is the point: there is no way to reach an unclamped policy."""
        return replace(self, **changes)


@dataclass(frozen=True)
class IssuedLink:
    """The result of :meth:`MagicLinkAuthenticator.request`.

    ``token`` is the secret that goes in the email URL and is returned **only**
    here. ``token_id`` is a non-secret handle safe to log and to match against a
    delivery webhook.
    """

    token: str
    token_id: str
    email: str
    purpose: str  # "sign_in" | "support_recovery"
    requested_at: datetime
    expires_at: datetime
    issued_by_support: str | None = None

    @property
    def is_support_recovery(self) -> bool:
        return self.purpose == "support_recovery"


@dataclass(frozen=True)
class Identity:
    """The authenticated subject returned by :meth:`MagicLinkAuthenticator.consume`."""

    email: str
    token_id: str
    authenticated_at: datetime
    via_support_link: bool = False


@dataclass
class _Record:
    token_id: str
    email: str
    token_hash: str
    purpose: str
    requested_at: datetime
    expires_at: datetime
    issued_by_support: str | None
    consumed_at: datetime | None = None
    consumed_identity: Identity | None = None

    def is_live(self, now: datetime) -> bool:
        return self.consumed_at is None and now < self.expires_at

    def retain_until(self, window: timedelta) -> datetime:
        """When this record may be forgotten.

        One rule for consumed and unconsumed alike: the link's own expiry plus
        one idempotency window. Until then :meth:`MagicLinkAuthenticator.consume`
        can still answer *specifically* — "expired" or "already used" rather than
        the vaguer "no such link" — and after it, the record is gone for every
        caller at the same moment.

        Keying retention to the link's own clock is what makes the answer
        deterministic. It used to be keyed to ``consumed_at``, and purging only
        ran from :meth:`~MagicLinkAuthenticator.request`, so the error a user
        saw for re-clicking a dead link depended on whether some unrelated
        address had asked for a link in between.

        A consumed record's idempotency window always fits inside this, because
        ``consume`` refuses a token at or after its expiry — so
        ``consumed_at + window < expires_at + window``.
        """
        return self.expires_at + window


class MagicLinkAuthenticator:
    """Issues and verifies magic links. One instance per account store.

    Not thread-safe; a hosted deployment wraps a shared, locked store with the
    same two methods.
    """

    def __init__(
        self,
        policy: MagicLinkPolicy | None = None,
        *,
        now: Callable[[], datetime] = _utcnow,
    ) -> None:
        self.policy = policy or MagicLinkPolicy()
        self._now = now
        self._by_hash: dict[str, _Record] = {}
        self._by_email: dict[str, list[_Record]] = {}

    # -- issue -------------------------------------------------------------

    def request(
        self,
        email: str,
        *,
        now: datetime | None = None,
        issued_by_support: str | None = None,
    ) -> IssuedLink:
        """Issue a fresh link for ``email`` and return it (incl. the secret).

        A normal request inside the cooldown after a still-live, unconsumed link
        raises :class:`ResendCooldownError`. ``issued_by_support`` marks the
        identity-checked recovery path: it skips the cooldown, is recorded on
        the link, and uses ``support_link_ttl``.
        """
        now = now or self._now()
        key = normalize_email(email)
        self._purge(now)

        if issued_by_support is None:
            remaining = self._cooldown_remaining(key, now)
            if remaining > timedelta(0):
                raise ResendCooldownError(key, remaining)

        token = secrets.token_urlsafe(self.policy.token_bytes)
        purpose = "support_recovery" if issued_by_support is not None else "sign_in"
        ttl = (
            self.policy.support_link_ttl
            if issued_by_support is not None
            else self.policy.link_ttl
        )
        record = _Record(
            token_id=uuid.uuid4().hex,
            email=key,
            token_hash=_hash(token),
            purpose=purpose,
            requested_at=now,
            expires_at=now + ttl,
            issued_by_support=issued_by_support,
        )
        self._by_hash[record.token_hash] = record
        self._by_email.setdefault(key, []).append(record)

        return IssuedLink(
            token=token,
            token_id=record.token_id,
            email=key,
            purpose=purpose,
            requested_at=now,
            expires_at=record.expires_at,
            issued_by_support=issued_by_support,
        )

    # -- verify ----------------------------------------------------------

    def consume(self, token: str, *, now: datetime | None = None) -> Identity:
        """Verify a link and return the :class:`Identity` it authenticates.

        Single-use, with three answers on a well-defined timeline — all keyed to
        the link's own clock, never to what other callers happened to be doing
        (see :meth:`_Record.retain_until`):

        * within ``idempotency_window`` of the first consume — the same
          :class:`Identity` again, so a mail-client prefetch or a double tap does
          not read as a failure;
        * after that, up to ``expires_at + idempotency_window`` —
          :class:`TokenAlreadyUsedError`;
        * beyond retention, or for a token this authenticator never issued —
          :class:`InvalidTokenError`.

        An unconsumed link past its TTL raises :class:`TokenExpiredError` over
        the same retention window.
        """
        now = now or self._now()
        # Purge here as well as in `request`, so which error a stale link earns
        # is decided by that link's own clock and nothing else.
        self._purge(now)
        record = self._by_hash.get(_hash(token or ""))
        if record is None:
            raise InvalidTokenError("no such link")

        if record.consumed_at is not None:
            assert record.consumed_identity is not None
            if now - record.consumed_at <= self.policy.idempotency_window:
                return record.consumed_identity
            raise TokenAlreadyUsedError(record.token_id)

        if now >= record.expires_at:
            raise TokenExpiredError(record.token_id)

        identity = Identity(
            email=record.email,
            token_id=record.token_id,
            authenticated_at=now,
            via_support_link=record.issued_by_support is not None,
        )
        record.consumed_at = now
        record.consumed_identity = identity
        return identity

    # -- UI helpers -----------------------------------------------------

    def cooldown_remaining(self, email: str, *, now: datetime | None = None) -> timedelta:
        """How long until a plain re-send for ``email`` is allowed.

        ``timedelta(0)`` means "send now". Support-issued links ignore this.
        """
        now = now or self._now()
        return self._cooldown_remaining(normalize_email(email), now)

    def has_live_link(self, email: str, *, now: datetime | None = None) -> bool:
        """True if ``email`` has an unconsumed, unexpired link outstanding."""
        now = now or self._now()
        return any(
            r.is_live(now) for r in self._by_email.get(normalize_email(email), ())
        )

    # -- internals ----------------------------------------------------

    def _cooldown_remaining(self, key: str, now: datetime) -> timedelta:
        cooldown = self.policy.resend_cooldown
        if cooldown <= timedelta(0):
            return timedelta(0)
        live = [
            r
            for r in self._by_email.get(key, ())
            if r.is_live(now) and r.issued_by_support is None
        ]
        if not live:
            return timedelta(0)
        newest = max(r.requested_at for r in live)
        elapsed = now - newest
        return max(timedelta(0), cooldown - elapsed)

    def _purge(self, now: datetime) -> None:
        """Drop every record past its retention. Runs from both `request` and
        `consume`, so no caller's answer depends on another caller's timing."""
        window = self.policy.idempotency_window
        dead = [
            record for record in self._by_hash.values()
            if now >= record.retain_until(window)
        ]
        for record in dead:
            self._by_hash.pop(record.token_hash, None)
            bucket = self._by_email.get(record.email)
            if bucket is not None:
                bucket[:] = [r for r in bucket if r is not record]
                if not bucket:
                    self._by_email.pop(record.email, None)


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()
