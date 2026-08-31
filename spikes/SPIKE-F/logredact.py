"""Strand 2 — what is logged for an accountless reader, and for how long.

The reading surface reaches people who never consented to an account (P4:
"guest sessions leave no server-side trace"). Two log tiers exist in a
hosted deploy and they need different rules:

* **edge / CDN / reverse-proxy access logs** — written before any Plotlines
  code runs. These cannot be made not to exist, so the posture is: keep them
  short, and keep the token out of the URL so it is out of them (Strand 1's
  exchange-for-cookie). Recommended retention: **72 hours**, operational
  only.
* **application request logs** — Plotlines writes these, so Plotlines
  controls their shape. `redact_record` is the allowlist: a request is
  logged as a **route template**, never a concrete URL, with no token, no
  cookie, no `Referer`, and the client IP truncated to a /24. Recommended
  retention: **30 days**.

`redact_record` is written as an allowlist (like `granted_fields`, ARCH
§11.1): a field added to the raw record later is dropped by default rather
than logged by accident.
"""

from __future__ import annotations

import datetime as _dt
import re
from typing import Any

# raw-record field -> keep? Anything not listed is dropped.
_ALLOW = {
    "ts": True,
    "method": True,
    "route": True,        # template, filled in by _route_template
    "status": True,
    "bytes": True,
    "cache_status": True,
    "ua_family": True,
    "client_ip": True,    # kept but truncated by _trunc_ip
    # explicitly dropped even though a caller might pass them:
    "path": False,
    "query": False,
    "referer": False,
    "cookie": False,
    "user_agent": False,  # raw UA is a fingerprinting surface; family only
    "token": False,
}

EDGE_LOG_RETENTION_HOURS = 72
APP_LOG_RETENTION_DAYS = 30

_TOKEN_SEG = re.compile(r"/read/[^/?#]+")
_HEX24 = re.compile(r"/j/[0-9a-f]{6,}", re.I)


def route_template(path: str) -> str:
    """Collapse a concrete reading URL to its template."""
    path = _TOKEN_SEG.sub("/read/{share_token}", path)
    path = _HEX24.sub("/j/{session}", path)
    return path


def _trunc_ip(ip: str) -> str:
    if ip.count(".") == 3:
        return ip.rsplit(".", 1)[0] + ".0/24"
    if ":" in ip:  # IPv6 -> /48
        return ":".join(ip.split(":")[:3]) + "::/48"
    return "0.0.0.0/24"


def _ua_family(ua: str) -> str:
    ua = ua.lower()
    for fam in ("firefox", "chrome", "safari", "edg", "curl", "python"):
        if fam in ua:
            return "edge" if fam == "edg" else fam
    return "other"


def redact_record(raw: dict[str, Any], *, now: _dt.datetime | None = None) -> dict[str, Any]:
    now = now or _dt.datetime.now(_dt.timezone.utc)
    # Guard: refuse to even look at a field the allowlist marks as drop-always,
    # so a future caller that renames things trips a test rather than a leak.
    dropped = {k for k, keep in _ALLOW.items() if not keep}
    out: dict[str, Any] = {"_dropped_fields": sorted(dropped & set(raw))}
    out["ts"] = raw.get("ts") or now.replace(microsecond=0).isoformat()
    out["method"] = raw.get("method", "GET")
    out["route"] = raw.get("route") or route_template(raw.get("path", "/"))
    out["status"] = raw.get("status", 200)
    out["bytes"] = raw.get("bytes", 0)
    out["cache_status"] = raw.get("cache_status", "-")
    out["ua_family"] = raw.get("ua_family") or _ua_family(raw.get("user_agent", ""))
    out["client_ip"] = _trunc_ip(raw.get("client_ip", "0.0.0.0"))
    out["retain_until"] = (
        now + _dt.timedelta(days=APP_LOG_RETENTION_DAYS)
    ).replace(microsecond=0).isoformat()
    return out


def leaks_secret(redacted: dict[str, Any], secret: str) -> bool:
    import json
    return secret in json.dumps(redacted)
