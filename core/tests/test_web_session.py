"""Story M4 — the same-site session cookie contract (ARCH §10.3, D15, A10).

`plotlines_core.web.session` is pure policy: it decides whether a domain can
carry a first-party shared-parent `SameSite=Lax` cookie and emits the one
attribute set that cookie is ever allowed to have. These tests pin the two
things that silently break in production if they regress — the attribute
string, and the public-suffix refusal.
"""

from __future__ import annotations

import pytest

from plotlines_core.web.session import (
    DEFAULT_COOKIE_NAME,
    InsecureCookieDomain,
    SessionCookiePolicy,
    registrable_domain,
)


# --- registrable_domain --------------------------------------------------

def test_registrable_domain_two_label_rule() -> None:
    assert registrable_domain("api.plotlines.app") == "plotlines.app"
    assert registrable_domain("app.staging.plotlines.app") == "plotlines.app"
    assert registrable_domain("plotlines.app") == "plotlines.app"


def test_registrable_domain_multi_label_public_suffix() -> None:
    # onrender.com is on the Public Suffix List, so a name registered there is
    # foo.onrender.com and its subdomains are cross-site (A10).
    assert registrable_domain("api.plotlines.onrender.com") == "plotlines.onrender.com"


def test_registrable_domain_rejects_bare_tld_and_bare_public_suffix() -> None:
    with pytest.raises(InsecureCookieDomain):
        registrable_domain("app")
    with pytest.raises(InsecureCookieDomain):
        registrable_domain("onrender.com")


def test_registrable_domain_honours_extra_suffixes() -> None:
    assert registrable_domain(
        "api.acme.internal.test", extra_public_suffixes=frozenset({"internal.test"})
    ) == "acme.internal.test"


# --- SessionCookiePolicy construction ----------------------------------

def test_policy_rejects_public_suffix_parent() -> None:
    with pytest.raises(InsecureCookieDomain):
        SessionCookiePolicy(parent_domain="onrender.com")


def test_policy_rejects_a_subdomain_as_parent() -> None:
    # api.plotlines.app is where the API lives, not the shared parent — the
    # error names the value the caller should have passed.
    with pytest.raises(InsecureCookieDomain, match="plotlines.app"):
        SessionCookiePolicy(parent_domain="api.plotlines.app")


def test_policy_rejects_bare_tld() -> None:
    with pytest.raises(InsecureCookieDomain):
        SessionCookiePolicy(parent_domain="localhost")


def test_policy_normalises_leading_dot_and_case() -> None:
    p = SessionCookiePolicy(parent_domain=".Plotlines.App")
    assert p.parent_domain == "plotlines.app"
    assert p.cookie_domain == ".plotlines.app"


def test_policy_rejects_nonpositive_max_age() -> None:
    with pytest.raises(ValueError):
        SessionCookiePolicy(parent_domain="plotlines.app", max_age_s=0)


# --- the Set-Cookie value ---------------------------------------------

def test_set_cookie_header_has_exactly_the_required_attributes() -> None:
    p = SessionCookiePolicy(parent_domain="plotlines.app")
    header = p.set_cookie_header("abc123", max_age=3600)
    assert header == (
        f"{DEFAULT_COOKIE_NAME}=abc123; Domain=.plotlines.app; Path=/; "
        "Max-Age=3600; HttpOnly; Secure; SameSite=Lax"
    )


def test_set_cookie_header_is_first_party_lax_httponly_secure() -> None:
    p = SessionCookiePolicy(parent_domain="plotlines.app")
    header = p.set_cookie_header("tok")
    assert "; HttpOnly" in header
    assert "; Secure" in header
    assert "; SameSite=Lax" in header
    assert "SameSite=None" not in header
    assert "SameSite=Strict" not in header
    assert "Domain=.plotlines.app" in header  # leading dot: shared by app.* and api.*


def test_set_cookie_header_uses_default_max_age() -> None:
    p = SessionCookiePolicy(parent_domain="plotlines.app")
    assert f"Max-Age={p.max_age_s}" in p.set_cookie_header("tok")


def test_set_cookie_header_rejects_a_malformed_token() -> None:
    p = SessionCookiePolicy(parent_domain="plotlines.app")
    for bad in ("a b", "a;b", "a,b", "a\nb"):
        with pytest.raises(ValueError):
            p.set_cookie_header(bad)


def test_set_cookie_header_rejects_nonpositive_max_age() -> None:
    p = SessionCookiePolicy(parent_domain="plotlines.app")
    with pytest.raises(ValueError):
        p.set_cookie_header("tok", max_age=0)


def test_clear_cookie_header_matches_domain_and_path_with_max_age_zero() -> None:
    p = SessionCookiePolicy(parent_domain="plotlines.app")
    header = p.clear_cookie_header()
    assert header == (
        f"{DEFAULT_COOKIE_NAME}=; Domain=.plotlines.app; Path=/; "
        "Max-Age=0; HttpOnly; Secure; SameSite=Lax"
    )


# --- the release gate: assert_same_site ------------------------------

def test_assert_same_site_accepts_subdomains_of_the_one_parent() -> None:
    p = SessionCookiePolicy(parent_domain="plotlines.app")
    p.assert_same_site("app.plotlines.app", "api.plotlines.app")  # no raise


def test_assert_same_site_rejects_two_different_registrable_domains() -> None:
    p = SessionCookiePolicy(parent_domain="plotlines.app")
    with pytest.raises(InsecureCookieDomain, match="api"):
        p.assert_same_site("app.plotlines.app", "api.example.com")


def test_assert_same_site_rejects_the_onrender_trap() -> None:
    # The exact A10 scenario: app.* and api.* on *.onrender.com are
    # cross-site, and a policy could never be built on onrender.com anyway —
    # but if someone tries to reuse a real policy against onrender hosts, it
    # is caught here too.
    p = SessionCookiePolicy(parent_domain="plotlines.app")
    with pytest.raises(InsecureCookieDomain):
        p.assert_same_site("app.plotlines.onrender.com", "api.plotlines.onrender.com")


def test_covers() -> None:
    p = SessionCookiePolicy(parent_domain="plotlines.app")
    assert p.covers("plotlines.app")
    assert p.covers("api.plotlines.app")
    assert p.covers("app.staging.plotlines.app")
    assert not p.covers("plotlines.app.evil.com")
    assert not p.covers("notplotlines.app")
