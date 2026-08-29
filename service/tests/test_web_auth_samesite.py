"""Story M4 (issue #132) — hosted mode serves web auth same-site.

`core/tests/test_web_session.py` covers the cookie policy itself. What only
the service layer can catch: that hosted mode *requires* a real registered
domain (the analogue of sidecar mode refusing a non-loopback bind), that the
one session-cookie seam is wired onto `app.state`, and that a sidecar has no
web/auth surface at all.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi import Response
from fastapi.testclient import TestClient

from plotlines_core.web.session import InsecureCookieDomain
from plotlines_service.app import create_app


# --- hosted mode requires a same-site-capable domain ------------------

def test_hosted_mode_requires_a_web_domain(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="web-domain"):
        create_app(tmp_path, mode="hosted")


def test_hosted_mode_refuses_a_public_suffix_domain(tmp_path: Path) -> None:
    # The A10 trap — Render hands out `<service>.onrender.com`, so the only
    # "shared parent" is `onrender.com`, which is a public suffix: its
    # subdomains are cross-site and the session cookie is third-party.
    with pytest.raises(InsecureCookieDomain):
        create_app(tmp_path, mode="hosted", web_domain="onrender.com")


def test_hosted_policy_rejects_the_render_service_host_pair(tmp_path: Path) -> None:
    app = create_app(tmp_path, mode="hosted", web_domain="plotlines.app")
    with pytest.raises(InsecureCookieDomain):
        app.state.session_cookie.assert_same_site(
            "plotlines-app.onrender.com", "plotlines-api.onrender.com"
        )


def test_hosted_mode_builds_with_a_real_domain(tmp_path: Path) -> None:
    app = create_app(tmp_path, mode="hosted", web_domain="plotlines.app")
    assert app.state.session_cookie.parent_domain == "plotlines.app"


# --- the session-cookie seam ----------------------------------------

def test_issue_session_sets_a_first_party_lax_cookie(tmp_path: Path) -> None:
    app = create_app(tmp_path, mode="hosted", web_domain="plotlines.app")
    resp = Response()
    app.state.issue_session(resp, "token-abc")
    setcookie = resp.headers["set-cookie"]
    assert setcookie.startswith("pl_session=token-abc; ")
    assert "Domain=.plotlines.app" in setcookie
    assert "HttpOnly" in setcookie
    assert "Secure" in setcookie
    assert "SameSite=Lax" in setcookie


def test_end_session_clears_the_cookie(tmp_path: Path) -> None:
    app = create_app(tmp_path, mode="hosted", web_domain="plotlines.app")
    resp = Response()
    app.state.end_session(resp)
    setcookie = resp.headers["set-cookie"]
    assert setcookie.startswith("pl_session=; ")
    assert "Max-Age=0" in setcookie
    assert "Domain=.plotlines.app" in setcookie


# --- /health surfaces the contract in hosted mode only --------------

def test_health_reports_the_same_site_contract_in_hosted_mode(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path, mode="hosted", web_domain="plotlines.app"))
    body = client.get("/health").json()
    assert body["mode"] == "hosted"
    assert body["web"]["parent_domain"] == "plotlines.app"
    assert body["web"]["cookie"]["same_site"] == "Lax"
    assert body["web"]["cookie"]["secure"] is True
    assert body["web"]["cookie"]["http_only"] is True


def test_sidecar_mode_has_no_web_block_and_no_session_seam(tmp_path: Path) -> None:
    app = create_app(tmp_path)  # default: sidecar
    assert not hasattr(app.state, "session_cookie")
    assert not hasattr(app.state, "issue_session")
    body = TestClient(app).get("/health").json()
    assert body["mode"] == "sidecar"
    assert "web" not in body


def test_sidecar_mode_registers_no_auth_routes(tmp_path: Path) -> None:
    app = create_app(tmp_path)
    paths = {route.path for route in app.routes}
    assert not any(p.startswith("/auth") for p in paths)
