"""K1 / FR57 / ARCH D9 — the magic-link auth primitive.

Written against `web/magic_link.py` shipping at 0% coverage (#235 B2): 159
statements of credential handling that had never been executed, and which
turned out to carry two defects (A3, A4) that this file now pins.

The clock is injected everywhere rather than slept on — every timing rule here
is a policy decision, and a test that waits a real minute to check a one-minute
cooldown is a test nobody runs.
"""

from __future__ import annotations

from dataclasses import FrozenInstanceError
from datetime import datetime, timedelta, timezone

import pytest

from plotlines_core.web import magic_link as ml
from plotlines_core.web.magic_link import (
    DEFAULT_LINK_TTL,
    IDEMPOTENCY_WINDOW,
    MIN_LINK_TTL,
    Identity,
    InvalidEmailError,
    InvalidTokenError,
    MagicLinkAuthenticator,
    MagicLinkPolicy,
    ResendCooldownError,
    TokenAlreadyUsedError,
    TokenExpiredError,
    normalize_email,
)

T0 = datetime(2026, 9, 2, 12, 0, tzinfo=timezone.utc)


def _auth(**policy_kwargs) -> MagicLinkAuthenticator:
    return MagicLinkAuthenticator(MagicLinkPolicy(**policy_kwargs))


# ── FR57's headline: this is the only credential path ────────────────────


def test_there_is_no_password_and_no_sms_otp():
    """The K1 acceptance criterion, made assertable. Nothing in the module
    reads these — they exist so the guarantee has a test."""
    assert ml.SUPPORTS_PASSWORD is False
    assert ml.SUPPORTS_SMS_OTP is False

    # ... and there is nothing to call. The two flags above are the only names
    # in the module that mention either method; a `verify_password` or a
    # `send_otp` appearing here would mean FR57 had quietly grown a second
    # credential path.
    declared = {"SUPPORTS_PASSWORD", "SUPPORTS_SMS_OTP"}
    surface = [n for n in dir(ml) if not n.startswith("_")] + list(ml.__all__)
    assert not [n for n in surface
                if n not in declared and ("password" in n.lower() or "otp" in n.lower())]


# ── email normalisation ──────────────────────────────────────────────────


@pytest.mark.parametrize("raw,expected", [
    ("Author@Example.COM", "author@example.com"),
    ("  author@example.com  ", "author@example.com"),
    ("AUTHOR@EXAMPLE.CO.UK", "author@example.co.uk"),
])
def test_an_address_normalises_to_one_account_key(raw, expected):
    assert normalize_email(raw) == expected


@pytest.mark.parametrize("raw", [
    "", "   ", "no-at-sign", "@example.com", "author@", "author@localhost",
    "auth or@example.com", "author@exa mple.com",
])
def test_an_unusable_address_is_refused_rather_than_becoming_a_dead_account(raw):
    """"A typo must not silently create a distinct account that no link can
    ever reach" — so this rejects rather than accepting and stranding."""
    with pytest.raises(InvalidEmailError):
        normalize_email(raw)


def test_the_same_address_in_different_case_shares_one_cooldown():
    """Normalisation is the account key, so it has to be the cooldown key too —
    otherwise case is a trivial bypass."""
    auth = _auth(resend_cooldown=timedelta(seconds=60))
    auth.request("Author@Example.com", now=T0)

    with pytest.raises(ResendCooldownError):
        auth.request("author@EXAMPLE.com", now=T0 + timedelta(seconds=5))


# ── A3 — the SPIKE-13 TTL floor is not negotiable ────────────────────────


def test_a_short_link_ttl_is_raised_to_the_floor():
    """A greylisting deferral on first contact between two mail domains is
    commonly 1-15 min; a link that expires inside that window is unusable
    through no fault of the user."""
    assert MagicLinkPolicy(link_ttl=timedelta(seconds=1)).link_ttl == MIN_LINK_TTL
    assert MagicLinkPolicy(support_link_ttl=timedelta(minutes=2)).support_link_ttl == MIN_LINK_TTL


def test_a_generous_ttl_is_left_alone():
    """The floor is a floor, not a setting."""
    assert MagicLinkPolicy(link_ttl=timedelta(hours=2)).link_ttl == timedelta(hours=2)


def test_the_floor_cannot_be_written_around_after_construction():
    """#235 A3. While the policy was a mutable dataclass, the clamp in
    `__post_init__` was the only thing enforcing the floor, and a plain
    attribute write walked straight past it:

        p = MagicLinkPolicy(link_ttl=timedelta(seconds=1))   # clamped to 15m
        p.link_ttl = timedelta(seconds=1)                    # ... and unclamped

    Frozen closes it. This is the assertion, not the dataclass decorator.
    """
    policy = MagicLinkPolicy(link_ttl=timedelta(seconds=1))
    with pytest.raises(FrozenInstanceError):
        policy.link_ttl = timedelta(seconds=1)

    link = MagicLinkAuthenticator(policy).request("a@example.com", now=T0)
    assert link.expires_at - link.requested_at >= MIN_LINK_TTL


def test_evolve_re_clamps_rather_than_offering_a_back_door():
    """The supported way to derive a variant must not be the way around the
    floor."""
    evolved = MagicLinkPolicy().evolve(link_ttl=timedelta(seconds=1))
    assert evolved.link_ttl == MIN_LINK_TTL
    assert MagicLinkPolicy().evolve(resend_cooldown=timedelta(0)).resend_cooldown == timedelta(0)


@pytest.mark.parametrize("kwargs", [
    {"token_bytes": 8},
    {"resend_cooldown": timedelta(seconds=-1)},
    {"idempotency_window": timedelta(seconds=-1)},
])
def test_an_incoherent_policy_is_refused_at_construction(kwargs):
    with pytest.raises(ValueError):
        MagicLinkPolicy(**kwargs)


# ── issuing ──────────────────────────────────────────────────────────────


def test_a_request_issues_a_link_carrying_the_secret_and_a_loggable_handle():
    auth = _auth()
    link = auth.request("author@example.com", now=T0)

    assert link.email == "author@example.com"
    assert link.purpose == "sign_in"
    assert link.requested_at == T0
    assert link.expires_at == T0 + DEFAULT_LINK_TTL
    assert link.issued_by_support is None
    assert not link.is_support_recovery
    assert link.token and link.token_id
    assert link.token != link.token_id


def test_the_plaintext_token_is_never_held_at_rest():
    """"The plaintext exists once, in the email, and never at rest." Only the
    SHA-256 hash is stored — so a dump of the authenticator's state cannot be
    replayed as a sign-in."""
    auth = _auth()
    link = auth.request("author@example.com", now=T0)

    stored = repr(auth.__dict__)
    assert link.token not in stored
    assert ml._hash(link.token) in auth._by_hash


def test_two_requests_never_collide():
    auth = _auth(resend_cooldown=timedelta(0))
    tokens = {auth.request("a@example.com", now=T0).token for _ in range(50)}
    assert len(tokens) == 50


def test_the_token_carries_the_declared_entropy():
    """32 bytes = 256 bits; the urlsafe encoding is longer than the byte count,
    which is the thing worth pinning against a future "shorter is prettier"."""
    link = _auth().request("a@example.com", now=T0)
    assert len(link.token) >= ml.TOKEN_BYTES


# ── SPIKE-13's re-send cooldown ──────────────────────────────────────────


def test_a_resend_inside_the_cooldown_is_refused_with_a_renderable_wait():
    """`retry_after` is what the UI renders as the visible cooldown — the
    fallback SPIKE-13 required, since magic-link-only sits at the
    STAKE/FALLBACK boundary rather than at STAKE."""
    auth = _auth(resend_cooldown=timedelta(seconds=60))
    auth.request("a@example.com", now=T0)

    with pytest.raises(ResendCooldownError) as caught:
        auth.request("a@example.com", now=T0 + timedelta(seconds=20))

    assert caught.value.retry_after == timedelta(seconds=40)
    assert caught.value.email == "a@example.com"
    assert "40s" in str(caught.value)


def test_past_the_cooldown_a_resend_succeeds():
    auth = _auth(resend_cooldown=timedelta(seconds=60))
    auth.request("a@example.com", now=T0)
    second = auth.request("a@example.com", now=T0 + timedelta(seconds=61))
    assert second.token


def test_a_resend_leaves_the_earlier_link_working():
    """SPIKE-13's "keep both valid within the TTL": a re-request must never
    strand someone between two links, because the first mail may well be the
    one that arrives."""
    auth = _auth(resend_cooldown=timedelta(seconds=60))
    first = auth.request("a@example.com", now=T0)
    second = auth.request("a@example.com", now=T0 + timedelta(seconds=90))

    assert auth.consume(first.token, now=T0 + timedelta(seconds=120)).email == "a@example.com"
    assert auth.consume(second.token, now=T0 + timedelta(seconds=121)).email == "a@example.com"


def test_the_cooldown_is_per_address():
    auth = _auth(resend_cooldown=timedelta(seconds=60))
    auth.request("a@example.com", now=T0)
    assert auth.request("b@example.com", now=T0).token  # no raise


def test_a_consumed_link_does_not_hold_the_cooldown_open():
    """Someone who signed in and immediately wants another link (a second
    device) should not be told to wait on a link they already spent."""
    auth = _auth(resend_cooldown=timedelta(seconds=60))
    first = auth.request("a@example.com", now=T0)
    auth.consume(first.token, now=T0 + timedelta(seconds=5))

    assert auth.request("a@example.com", now=T0 + timedelta(seconds=10)).token


def test_an_expired_link_does_not_hold_the_cooldown_open():
    auth = _auth(link_ttl=MIN_LINK_TTL, resend_cooldown=timedelta(seconds=60))
    auth.request("a@example.com", now=T0)
    assert auth.request("a@example.com", now=T0 + MIN_LINK_TTL + timedelta(seconds=1)).token


def test_a_zero_cooldown_disables_the_wait():
    auth = _auth(resend_cooldown=timedelta(0))
    auth.request("a@example.com", now=T0)
    assert auth.request("a@example.com", now=T0).token


def test_cooldown_remaining_reports_what_the_ui_should_render():
    auth = _auth(resend_cooldown=timedelta(seconds=60))
    assert auth.cooldown_remaining("a@example.com", now=T0) == timedelta(0)

    auth.request("a@example.com", now=T0)
    assert auth.cooldown_remaining("a@example.com", now=T0 + timedelta(seconds=15)) == \
        timedelta(seconds=45)
    assert auth.cooldown_remaining("a@example.com", now=T0 + timedelta(seconds=90)) == \
        timedelta(0)


def test_has_live_link_tracks_the_outstanding_link():
    auth = _auth(link_ttl=MIN_LINK_TTL, resend_cooldown=timedelta(0))
    assert not auth.has_live_link("a@example.com", now=T0)

    link = auth.request("a@example.com", now=T0)
    assert auth.has_live_link("a@example.com", now=T0)

    auth.consume(link.token, now=T0 + timedelta(minutes=1))
    assert not auth.has_live_link("a@example.com", now=T0 + timedelta(minutes=1))


def test_has_live_link_goes_false_once_the_link_expires():
    auth = _auth(link_ttl=MIN_LINK_TTL, resend_cooldown=timedelta(0))
    auth.request("a@example.com", now=T0)
    assert not auth.has_live_link("a@example.com", now=T0 + MIN_LINK_TTL)


# ── the support-issued recovery path ─────────────────────────────────────


def test_a_support_link_bypasses_the_cooldown_and_records_who_issued_it():
    """This is what replaces "reset your password" — the identity-checked
    manual path. Who issued it is recorded because that is the whole control."""
    auth = _auth(resend_cooldown=timedelta(seconds=60))
    auth.request("a@example.com", now=T0)

    link = auth.request("a@example.com", now=T0 + timedelta(seconds=1),
                        issued_by_support="support:casey")

    assert link.purpose == "support_recovery"
    assert link.is_support_recovery
    assert link.issued_by_support == "support:casey"


def test_a_support_link_takes_its_own_longer_ttl():
    auth = _auth(support_link_ttl=timedelta(hours=24))
    link = auth.request("a@example.com", now=T0, issued_by_support="support:casey")
    assert link.expires_at == T0 + timedelta(hours=24)


def test_consuming_a_support_link_marks_the_identity_as_such():
    """A session opened by a support-issued link is not the same evidence of
    identity as one opened from the user's own mailbox, so the caller is told."""
    auth = _auth()
    link = auth.request("a@example.com", now=T0, issued_by_support="support:casey")
    identity = auth.consume(link.token, now=T0 + timedelta(minutes=1))

    assert identity.via_support_link is True
    assert identity.email == "a@example.com"


def test_a_support_link_does_not_start_a_cooldown_for_the_user():
    """"Support-issued links ignore this" — in both directions, or a recovery
    would lock the user out of asking for their own link."""
    auth = _auth(resend_cooldown=timedelta(seconds=60))
    auth.request("a@example.com", now=T0, issued_by_support="support:casey")
    assert auth.request("a@example.com", now=T0 + timedelta(seconds=1)).token


# ── consuming ────────────────────────────────────────────────────────────


def test_consuming_a_link_authenticates_the_address_it_was_issued_for():
    auth = _auth()
    link = auth.request("Author@Example.com", now=T0)
    identity = auth.consume(link.token, now=T0 + timedelta(minutes=1))

    assert isinstance(identity, Identity)
    assert identity.email == "author@example.com"
    assert identity.token_id == link.token_id
    assert identity.authenticated_at == T0 + timedelta(minutes=1)
    assert identity.via_support_link is False


@pytest.mark.parametrize("token", ["", "not-a-token", "x" * 43])
def test_a_token_this_authenticator_never_issued_is_refused(token):
    auth = _auth()
    auth.request("a@example.com", now=T0)
    with pytest.raises(InvalidTokenError):
        auth.consume(token, now=T0)


def test_a_truncated_token_does_not_match_the_link_it_came_from():
    """The stored value is a hash of the whole token — a prefix must not be
    enough."""
    auth = _auth()
    link = auth.request("a@example.com", now=T0)
    with pytest.raises(InvalidTokenError):
        auth.consume(link.token[:-1], now=T0)


def test_an_expired_link_says_so_rather_than_denying_it_existed():
    """The distinction is the whole UX: "expired" tells the user to re-send,
    "no such link" tells them something is wrong."""
    auth = _auth(link_ttl=MIN_LINK_TTL)
    link = auth.request("a@example.com", now=T0)

    with pytest.raises(TokenExpiredError):
        auth.consume(link.token, now=T0 + MIN_LINK_TTL)


def test_a_link_is_still_good_the_instant_before_it_expires():
    auth = _auth(link_ttl=MIN_LINK_TTL)
    link = auth.request("a@example.com", now=T0)
    just_before = T0 + MIN_LINK_TTL - timedelta(microseconds=1)
    assert auth.consume(link.token, now=just_before).email == "a@example.com"


def test_a_double_click_inside_the_window_returns_the_same_identity():
    """A mail-client prefetch, a double tap, a browser retry — none of these is
    a failure, and telling the user it is would be a support ticket."""
    auth = _auth()
    link = auth.request("a@example.com", now=T0)

    first = auth.consume(link.token, now=T0 + timedelta(minutes=1))
    second = auth.consume(link.token, now=T0 + timedelta(minutes=1, seconds=30))

    assert second is first
    assert second.authenticated_at == first.authenticated_at


def test_the_idempotent_replay_does_not_extend_itself():
    """The window runs from the first consume, not the latest — otherwise a
    poller keeps a spent link alive indefinitely."""
    auth = _auth()
    link = auth.request("a@example.com", now=T0)
    auth.consume(link.token, now=T0)
    auth.consume(link.token, now=T0 + IDEMPOTENCY_WINDOW - timedelta(seconds=1))

    with pytest.raises(TokenAlreadyUsedError):
        auth.consume(link.token, now=T0 + IDEMPOTENCY_WINDOW + timedelta(seconds=1))


def test_a_spent_link_presented_later_is_refused_as_already_used():
    auth = _auth()
    link = auth.request("a@example.com", now=T0)
    auth.consume(link.token, now=T0)

    with pytest.raises(TokenAlreadyUsedError):
        auth.consume(link.token, now=T0 + IDEMPOTENCY_WINDOW + timedelta(minutes=1))


# ── A4 — that answer does not depend on unrelated traffic ────────────────


def _stale_consume_error(auth: MagicLinkAuthenticator, token: str, when: datetime) -> str:
    try:
        auth.consume(token, now=when)
    except Exception as exc:  # noqa: BLE001 — the identity of the error *is* the assertion
        return type(exc).__name__
    return "no error"


@pytest.mark.parametrize("intervening_request", [False, True])
def test_a_stale_link_earns_the_same_error_whoever_else_asked_for_one(intervening_request):
    """#235 A4. `_purge` ran only from `request` and evicted consumed records by
    `consumed_at`, so the error for re-clicking a dead link flipped between
    `TokenAlreadyUsedError` and `InvalidTokenError` depending on whether some
    *other* address had requested a link in between. Retention is now keyed to
    the link's own clock and purging runs on both paths.
    """
    auth = _auth(resend_cooldown=timedelta(0))
    link = auth.request("a@example.com", now=T0)
    auth.consume(link.token, now=T0)

    later = T0 + IDEMPOTENCY_WINDOW + timedelta(minutes=1)
    if intervening_request:
        auth.request("someone-else@example.com", now=later)

    assert _stale_consume_error(auth, link.token, later) == "TokenAlreadyUsedError"


@pytest.mark.parametrize("intervening_request", [False, True])
def test_an_expired_link_likewise_reads_the_same_either_way(intervening_request):
    auth = _auth(link_ttl=MIN_LINK_TTL, resend_cooldown=timedelta(0))
    link = auth.request("a@example.com", now=T0)

    later = T0 + MIN_LINK_TTL + timedelta(minutes=1)
    if intervening_request:
        auth.request("someone-else@example.com", now=later)

    assert _stale_consume_error(auth, link.token, later) == "TokenExpiredError"


def test_retention_ends_at_the_links_own_expiry_plus_one_window():
    """Past retention the record really is gone and "no such link" is the honest
    answer — the point is that it happens at a stated time, the same for
    everyone, rather than whenever someone else's request happened to purge."""
    auth = _auth(link_ttl=MIN_LINK_TTL, resend_cooldown=timedelta(0))
    link = auth.request("a@example.com", now=T0)
    auth.consume(link.token, now=T0)

    retention_ends = T0 + MIN_LINK_TTL + IDEMPOTENCY_WINDOW
    assert _stale_consume_error(auth, link.token, retention_ends - timedelta(seconds=1)) == \
        "TokenAlreadyUsedError"
    assert _stale_consume_error(auth, link.token, retention_ends) == "InvalidTokenError"


def test_purging_does_not_strand_a_second_live_link_for_the_same_address():
    """Eviction walks two indexes; dropping one record must not disturb the
    address's other outstanding link."""
    auth = _auth(link_ttl=MIN_LINK_TTL, resend_cooldown=timedelta(0))
    first = auth.request("a@example.com", now=T0)
    second = auth.request("a@example.com", now=T0 + timedelta(minutes=10))

    past_first = T0 + MIN_LINK_TTL + IDEMPOTENCY_WINDOW
    assert _stale_consume_error(auth, first.token, past_first) == "InvalidTokenError"
    assert auth.consume(second.token, now=past_first).email == "a@example.com"


def test_spent_links_do_not_accumulate_for_the_life_of_the_process():
    """The store is in-memory and a hosted deployment substitutes a shared one
    with the same shape — either way, a sign-in loop must not grow it without
    bound."""
    auth = _auth(link_ttl=MIN_LINK_TTL, resend_cooldown=timedelta(0))
    now = T0
    for _ in range(50):
        link = auth.request("a@example.com", now=now)
        auth.consume(link.token, now=now)
        now += MIN_LINK_TTL + IDEMPOTENCY_WINDOW + timedelta(seconds=1)

    assert len(auth._by_hash) <= 2
    assert len(auth._by_email.get("a@example.com", [])) <= 2


# ── the injected clock ───────────────────────────────────────────────────


def test_the_default_clock_is_used_when_no_now_is_passed():
    """Every method takes an explicit `now` for testing, but the production
    call sites pass none — so the injected default has to actually work."""
    ticks = [T0, T0 + timedelta(seconds=1), T0 + timedelta(seconds=2)]
    auth = MagicLinkAuthenticator(MagicLinkPolicy(), now=lambda: ticks.pop(0))

    link = auth.request("a@example.com")
    assert link.requested_at == T0
    assert auth.consume(link.token).authenticated_at == T0 + timedelta(seconds=1)
