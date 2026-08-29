"""SPIKE-13 — the live half: watch seed mailboxes for the magic-link mail.

Given a set of seed accounts on the major consumer hosts, each reachable over IMAP,
this polls Inbox and Junk/Spam for the message sent by `run.py` and records, per
recipient:

  * placement  — inbox | spam | missing (never seen inside the wait window)
  * time_to_inbox_seconds — arrival time minus send time, for inbox hits
  * spf / dkim / dmarc — pulled from Authentication-Results when the host adds it

Seed accounts are described in a JSON file kept **out of git** (it holds
credentials). Shape:

    {
      "seeds": [
        {
          "host": "gmail",
          "address": "plotlines.seed01@gmail.com",
          "imap_host": "imap.gmail.com",
          "imap_user": "plotlines.seed01@gmail.com",
          "imap_password": "<app password>",
          "inbox_folder": "INBOX",
          "spam_folder": "[Gmail]/Spam"
        },
        ...
      ]
    }

Nothing here runs in CI or in the tests — it needs real credentials and real
network. `analyze.py` consumes what this writes.
"""

from __future__ import annotations

import email
import imaplib
import re
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

AUTH_RE = {
    "spf": re.compile(r"spf=(\w+)", re.I),
    "dkim": re.compile(r"dkim=(\w+)", re.I),
    "dmarc": re.compile(r"dmarc=(\w+)", re.I),
}


@dataclass
class Seed:
    host: str
    address: str
    imap_host: str
    imap_user: str
    imap_password: str
    inbox_folder: str = "INBOX"
    spam_folder: str = "Junk"


@dataclass
class Observation:
    recipient: str
    host: str
    placement: str = "missing"
    time_to_inbox_seconds: float | None = None
    spf: str | None = None
    dkim: str | None = None
    dmarc: str | None = None

    def as_dict(self) -> dict:
        return {
            "recipient": self.recipient,
            "host": self.host,
            "placement": self.placement,
            "time_to_inbox_seconds": self.time_to_inbox_seconds,
            "spf": self.spf,
            "dkim": self.dkim,
            "dmarc": self.dmarc,
        }


def _auth_results(msg: email.message.Message) -> dict[str, str | None]:
    header = " ".join(msg.get_all("Authentication-Results", []))
    return {k: (m.group(1).lower() if (m := rx.search(header)) else None) for k, rx in AUTH_RE.items()}


def _search_folder(conn: imaplib.IMAP4_SSL, folder: str, token: str) -> email.message.Message | None:
    typ, _ = conn.select(f'"{folder}"', readonly=True)
    if typ != "OK":
        return None
    typ, data = conn.search(None, "SUBJECT", f'"{token}"')
    if typ != "OK" or not data or not data[0]:
        return None
    msg_id = data[0].split()[-1]
    typ, raw = conn.fetch(msg_id, "(RFC822)")
    if typ != "OK" or not raw or not isinstance(raw[0], tuple):
        return None
    return email.message_from_bytes(raw[0][1])


def poll_seed(seed: Seed, token: str, sent_at: datetime, wait_window_s: int, interval_s: int = 5) -> Observation:
    """Poll one seed's inbox and spam folders until the message shows up or the
    wait window elapses. `token` is a unique string in the Subject line."""
    obs = Observation(recipient=seed.address, host=seed.host)
    deadline = time.monotonic() + wait_window_s
    conn = imaplib.IMAP4_SSL(seed.imap_host)
    try:
        conn.login(seed.imap_user, seed.imap_password)
        while time.monotonic() < deadline:
            for folder, placement in ((seed.inbox_folder, "inbox"), (seed.spam_folder, "spam")):
                msg = _search_folder(conn, folder, token)
                if msg is None:
                    continue
                obs.placement = placement
                obs.__dict__.update(_auth_results(msg))
                if placement == "inbox":
                    try:
                        received = parsedate_to_datetime(msg["Date"]).astimezone(timezone.utc)
                        obs.time_to_inbox_seconds = max(0.0, (received - sent_at).total_seconds())
                    except (TypeError, ValueError):
                        obs.time_to_inbox_seconds = None
                return obs
            time.sleep(interval_s)
    finally:
        try:
            conn.logout()
        except Exception:
            pass
    return obs
