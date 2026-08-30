"""The web session cookie contract — first-party, same-site by construction
(PRD story M4; ARCH §10.3, D15; risk A10).

M4 is an *architectural* requirement, not a feature: the hosted web build and
the hosted API must sit on subdomains of **one registered domain** so the
signed-in session can travel as a first-party `HttpOnly; Secure;
SameSite=Lax` cookie on the shared parent. `SameSite` is evaluated on the
registrable domain (eTLD+1); if `app.` and `api.` resolve to different
registrable domains the cookie becomes third-party and is **silently blocked
by Safari and Firefox while still working in Chrome** (A10). The classic way
to trip this is a PaaS host on the Public Suffix List — `app.onrender.com`
and `api.onrender.com` are cross-*site* because `onrender.com` is an eTLD.

This module makes that contract mechanical so no call site can get it wrong:

* `SessionCookiePolicy` refuses to be built on a domain that cannot carry a
  first-party shared-parent cookie (a bare TLD, a known multi-label public
  suffix, or a subdomain passed where the registrable parent was meant).
* `assert_same_site(app_host, api_host)` is the release gate in code form —
  both hosts must fall under the one registrable parent.
* `set_cookie_header` / `clear_cookie_header` emit the **only** attribute set
  the session cookie is ever allowed to have: `Domain=.<parent>; Path=/;
  HttpOnly; Secure; SameSite=Lax`.

`HttpOnly` is also how the "no tokens in `localStorage`/`IndexedDB`" clause
is enforced structurally rather than by convention: the token only ever
exists as a cookie the browser attaches automatically and JavaScript cannot
read, so there is nothing for the web client to store and no code path that
could.

Pure policy — no `fastapi`, no `http` client. `service` builds one
`SessionCookiePolicy` in hosted mode and routes every `Set-Cookie` through
it; the not-yet-built `/auth/*` endpoints (ARCH §8.2) have exactly one way
to open and close a session.
"""

from __future__ import annotations

from dataclasses import dataclass, field

#: Multi-label suffixes that are on the Public Suffix List: registering a name
#: under one of these gives you an eTLD+1, and *its* subdomains are
#: cross-site. This is not the full PSL — it is the set of PaaS/static hosts a
#: Plotlines deploy could plausibly land on by accident, which is exactly the
#: A10 failure. `SessionCookiePolicy` refuses a parent domain that is one of
#: these (you cannot scope a cookie to `.onrender.com`) or that is only one
#: label below one (`foo.onrender.com` is a valid parent, but its own
#: subdomains still work — the point is that `onrender.com` itself is the
#: boundary). Extend via `SessionCookiePolicy(extra_public_suffixes=...)`.
KNOWN_MULTI_LABEL_PUBLIC_SUFFIXES: frozenset[str] = frozenset({
    "onrender.com",
    "herokuapp.com",
    "azurewebsites.net",
    "elasticbeanstalk.com",
    "github.io",
    "gitlab.io",
    "pages.dev",
    "workers.dev",
    "vercel.app",
    "netlify.app",
    "web.app",
    "firebaseapp.com",
    "fastly-edge.com",
    "cloudfront.net",
})

#: 30 days. A session cookie needs a finite lifetime (a "remember me" that is
#: really forever is its own problem); the exact value is a product call the
#: auth endpoints can override per-issue.
DEFAULT_MAX_AGE_S: int = 30 * 24 * 60 * 60

#: The cookie name. First-party, so no `__Host-`/`__Secure-` prefix is
#: required, and `__Host-` is actually incompatible with the shared-parent
#: `Domain` attribute this contract depends on.
DEFAULT_COOKIE_NAME: str = "pl_session"


class InsecureCookieDomain(ValueError):
    """The domain cannot carry a first-party, shared-parent `SameSite=Lax`
    session cookie — a bare TLD, a Public-Suffix-List multi-label host, or a
    subdomain handed in where the registrable parent was meant. Building the
    web tier on it would mean the session breaks in Safari and Firefox
    (ARCH §10.3, A10)."""


def _labels(host: str) -> list[str]:
    return [p for p in host.strip().strip(".").lower().split(".") if p]


def registrable_domain(host: str, *, extra_public_suffixes: frozenset[str] = frozenset()) -> str:
    """The eTLD+1 (registrable domain) of `host`.

    Uses the ordinary two-label rule (`api.example.co` -> `example.co`)
    unless `host` sits under a known multi-label public suffix, in which case
    it is three labels (`api.foo.onrender.com` -> `foo.onrender.com`). This
    is a deliberately small approximation of the Public Suffix List — enough
    to catch the deploy targets that would silently break `SameSite`
    (see `KNOWN_MULTI_LABEL_PUBLIC_SUFFIXES`), not a general PSL resolver.
    """
    labels = _labels(host)
    if len(labels) < 2:
        raise InsecureCookieDomain(
            f"{host!r} is not a registrable domain (needs at least two labels)"
        )
    suffixes = KNOWN_MULTI_LABEL_PUBLIC_SUFFIXES | extra_public_suffixes
    tail2 = ".".join(labels[-2:])
    if tail2 in suffixes:
        if len(labels) < 3:
            raise InsecureCookieDomain(
                f"{host!r} is a public suffix ({tail2}) — a name registered here "
                f"has no shared parent its subdomains can set a cookie on (A10)"
            )
        return ".".join(labels[-3:])
    return tail2


@dataclass(frozen=True)
class SessionCookiePolicy:
    """The one way the hosted web tier is allowed to set or clear the
    signed-in session cookie (M4). Construction validates that
    `parent_domain` can actually carry a first-party shared-parent
    `SameSite=Lax` cookie; every `Set-Cookie` value the auth endpoints emit
    comes from `set_cookie_header` / `clear_cookie_header` so the attribute
    set is fixed and un-bypassable.
    """

    parent_domain: str
    cookie_name: str = DEFAULT_COOKIE_NAME
    max_age_s: int = DEFAULT_MAX_AGE_S
    extra_public_suffixes: frozenset[str] = field(default_factory=frozenset)

    def __post_init__(self) -> None:
        host = self.parent_domain.strip().strip(".").lower()
        object.__setattr__(self, "parent_domain", host)
        # Raises InsecureCookieDomain for a bare TLD or a public suffix.
        registrable = registrable_domain(host, extra_public_suffixes=self.extra_public_suffixes)
        if registrable != host:
            raise InsecureCookieDomain(
                f"parent_domain {host!r} is a subdomain, not the registrable parent "
                f"— pass {registrable!r} so the cookie is scoped to the domain both "
                f"app.* and api.* share (ARCH §10.3)"
            )
        if self.max_age_s <= 0:
            raise ValueError("max_age_s must be positive")

    @property
    def cookie_domain(self) -> str:
        """The `Domain` attribute value — a leading dot marks it as shared by
        every subdomain of the registrable parent (`app.`, `api.`, …)."""
        return f".{self.parent_domain}"

    def covers(self, host: str) -> bool:
        """Whether `host` is the parent itself or a subdomain of it — i.e. a
        request to `host` would send this cookie."""
        h = host.strip().strip(".").lower()
        return h == self.parent_domain or h.endswith(f".{self.parent_domain}")

    def assert_same_site(self, app_host: str, api_host: str) -> None:
        """The M4 release gate, in code: the web build and the API must both
        sit under this one registrable parent, so the session cookie is
        first-party to both. Raises `InsecureCookieDomain` naming the offender
        otherwise — the same failure Safari and Firefox would show silently."""
        for label, host in (("web", app_host), ("api", api_host)):
            reg = registrable_domain(host, extra_public_suffixes=self.extra_public_suffixes)
            if reg != self.parent_domain:
                raise InsecureCookieDomain(
                    f"{label} host {host!r} has registrable domain {reg!r}, not "
                    f"{self.parent_domain!r}: the session cookie would be "
                    f"third-party and blocked by Safari/Firefox (ARCH §10.3, A10)"
                )
        if not self.covers(app_host) or not self.covers(api_host):
            raise InsecureCookieDomain(
                f"{app_host!r} and {api_host!r} must both be subdomains of "
                f"{self.parent_domain!r}"
            )

    def _attributes(self, *, max_age: int) -> str:
        # Order and spelling are fixed. `SameSite=Lax` (not Strict) so a
        # top-level navigation from an email magic-link still carries the
        # session; not `None`, which would need `Secure` + a third-party
        # context we deliberately do not have.
        return "; ".join([
            f"Domain={self.cookie_domain}",
            "Path=/",
            f"Max-Age={max_age}",
            "HttpOnly",
            "Secure",
            "SameSite=Lax",
        ])

    def set_cookie_header(self, token: str, *, max_age: int | None = None) -> str:
        """The full `Set-Cookie` value that opens a session for `token`."""
        if "\n" in token or "\r" in token or ";" in token or "," in token or " " in token:
            raise ValueError("session token must be a bare cookie value")
        ttl = self.max_age_s if max_age is None else max_age
        if ttl <= 0:
            raise ValueError("max_age must be positive; use clear_cookie_header to end a session")
        return f"{self.cookie_name}={token}; {self._attributes(max_age=ttl)}"

    def clear_cookie_header(self) -> str:
        """The `Set-Cookie` value that ends the session — same attributes
        (a browser only drops the cookie if `Domain`/`Path` match), empty
        value, `Max-Age=0`."""
        return f"{self.cookie_name}=; {self._attributes(max_age=0)}"
