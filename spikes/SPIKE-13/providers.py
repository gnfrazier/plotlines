"""SPIKE-13 — the candidate transactional-email providers, and how to send through them.

Two things live here:

1. `PRIOR_ART` — a comparison of the providers a magic-link sender would realistically
   pick, on the axes that decide this spike: shared vs dedicated IP reputation, whether
   transactional traffic is isolated from any marketing traffic, warmup cost, and
   delivery-event webhooks (so a regression is visible before users report it). This is
   the "resolved via prior art" half — the same move SPIKE-18 made for the elevation
   provider. It is data, not a live measurement, and it is labelled as such.

2. Thin send adapters (`send_one`) for the providers whose free tier is enough to run
   the live half. Pure stdlib (`urllib`), no SDK. These are only exercised when a real
   API key is present in the environment; the offline analysis and the tests do not
   touch them.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from dataclasses import dataclass


@dataclass(frozen=True)
class ProviderProfile:
    name: str
    ip_model: str                 # how sender IP reputation is managed
    txn_isolation: str            # is transactional traffic walled off from bulk/marketing
    warmup: str                   # cost of standing up a fresh sending domain
    delivery_webhooks: bool       # delivered / bounced / spam-complaint callbacks
    custom_domain_required: str   # what the provider needs on the sending domain
    notes: str


# Prior art as of 2026-08. Sources: each provider's own deliverability docs and status
# history, plus the cycling-tour-planner POC's use of SES for its (non-login) mail.
# Numbers providers publish about themselves are directional, not measured here — the
# live half exists precisely because self-reported inbox rates are not stakeable.
PRIOR_ART: tuple[ProviderProfile, ...] = (
    ProviderProfile(
        name="postmark",
        ip_model="shared pools, transactional-only; strong aggregate reputation",
        txn_isolation="hard — separate 'Message Streams', marketing mail is a different "
        "stream and (historically) a different product entirely",
        warmup="none for shared transactional stream; sender signature + DKIM verify only",
        delivery_webhooks=True,
        custom_domain_required="verified sender domain, DKIM (CNAME), return-path CNAME; "
        "DMARC recommended",
        notes="Positions specifically on transactional speed/inbox placement. Median "
        "send-to-delivery is seconds. The default recommendation for a login sender.",
    ),
    ProviderProfile(
        name="ses",
        ip_model="shared by default; dedicated IPs available but need manual warmup",
        txn_isolation="none built in — you separate streams via configuration sets; "
        "reputation is entirely yours to build and lose",
        warmup="4–6 weeks for a dedicated IP; shared IPs inherit AWS's mixed reputation",
        delivery_webhooks=True,  # via SNS configuration sets
        custom_domain_required="verified identity, DKIM (3x CNAME), custom MAIL FROM "
        "subdomain for SPF alignment; DMARC recommended",
        notes="Cheapest at volume and already in use in the POC for non-login mail. The "
        "warmup cost means it cannot be a late swap-in — if SES is the choice it has to "
        "be sending real traffic weeks before Web launches. Sandbox mode until raised.",
    ),
    ProviderProfile(
        name="resend",
        ip_model="shared, built on SES; dedicated IP on higher tiers",
        txn_isolation="soft — one sending domain, no stream concept; you self-segment",
        warmup="inherits SES shared-IP reputation; dedicated IP warmup if chosen",
        delivery_webhooks=True,
        custom_domain_required="verified domain, SPF + DKIM (TXT), DMARC recommended",
        notes="Best DX of the set. Reputation story is SES's story. Fine as a second "
        "source or for the spike itself; the isolation guarantee is weaker than Postmark's.",
    ),
    ProviderProfile(
        name="sendgrid",
        ip_model="shared pools by default; dedicated IP add-on",
        txn_isolation="soft — subusers / IP pools, but the shared pool has a long history "
        "of reputation problems from co-tenants",
        warmup="automated IP warmup for dedicated IPs",
        delivery_webhooks=True,
        custom_domain_required="authenticated domain: SPF + DKIM (CNAME), link branding; "
        "DMARC recommended",
        notes="Historically the shared-pool reputation is the weak spot for exactly this "
        "use case. Not the first pick for a login sender on a free/low tier.",
    ),
)


def recommended() -> ProviderProfile:
    """The prior-art pick, pending the live measurement."""
    return next(p for p in PRIOR_ART if p.name == "postmark")


# --- send adapters (live half only) -------------------------------------------------

def _post_json(url: str, headers: dict[str, str], payload: dict) -> dict:
    body = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=body, headers={**headers, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:  # surface the provider's error body
        raise RuntimeError(f"{url} -> {exc.code}: {exc.read().decode(errors='replace')}") from exc


def send_one(provider: str, from_address: str, to_address: str, subject: str, text: str) -> dict:
    """Send a single message. Returns the provider's response dict (includes a message id).

    Reads the API key from the environment:
      postmark -> POSTMARK_SERVER_TOKEN
      resend   -> RESEND_API_KEY
      sendgrid -> SENDGRID_API_KEY
    SES is intentionally not wired here — its send path is SigV4-signed and belongs in a
    dedicated adapter if SES becomes the choice.
    """
    if provider == "postmark":
        token = os.environ["POSTMARK_SERVER_TOKEN"]
        return _post_json(
            "https://api.postmarkapp.com/email",
            {"X-Postmark-Server-Token": token, "Accept": "application/json"},
            {
                "From": from_address, "To": to_address, "Subject": subject,
                "TextBody": text, "MessageStream": "outbound",
            },
        )
    if provider == "resend":
        key = os.environ["RESEND_API_KEY"]
        return _post_json(
            "https://api.resend.com/emails",
            {"Authorization": f"Bearer {key}"},
            {"from": from_address, "to": [to_address], "subject": subject, "text": text},
        )
    if provider == "sendgrid":
        key = os.environ["SENDGRID_API_KEY"]
        return _post_json(
            "https://api.sendgrid.com/v3/mail/send",
            {"Authorization": f"Bearer {key}"},
            {
                "personalizations": [{"to": [{"email": to_address}]}],
                "from": {"email": from_address},
                "subject": subject,
                "content": [{"type": "text/plain", "value": text}],
            },
        )
    raise ValueError(f"no send adapter for provider {provider!r}")
