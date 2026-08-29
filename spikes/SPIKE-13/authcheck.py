"""SPIKE-13 — SPF / DKIM / DMARC posture for the sending domain.

The spike question asks, in one clause: *"Check SPF/DKIM/DMARC setup and whether
the custom domain (ARCH §10.3) is needed for sender reputation too."* That last
part is the load-bearing one for Plotlines, because risk A10 already makes a
custom domain a hard prerequisite for the Web leg (`*.onrender.com` breaks the
session cookie in Safari/Firefox). If the same domain decision also carries sender
reputation, the two are one decision, made once — which is the outcome this file
exists to confirm or deny.

The record *fetch* needs network (`dig`); the record *parsing and scoring* is pure
and is what the tests cover. A run captures the three lookups into
`results/auth_records.json` and this module grades them offline, so the grade
reproduces without re-querying DNS.
"""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass, field
from enum import Enum


class AuthGrade(str, Enum):
    STANDARD = "standard"        # SPF + aligned DKIM + DMARC p>=quarantine, all present
    WEAK = "weak"                # present but permissive (p=none, or SPF ~all with no DMARC teeth)
    MISSING = "missing"          # at least one of the three absent


@dataclass
class SpfRecord:
    raw: str
    mechanisms: list[str] = field(default_factory=list)
    all_qualifier: str = ""     # "-" hardfail, "~" softfail, "?" neutral, "+" pass, "" none

    @property
    def present(self) -> bool:
        return self.raw.lower().startswith("v=spf1")


@dataclass
class DmarcRecord:
    raw: str
    policy: str = "none"        # none | quarantine | reject
    pct: int = 100
    rua: list[str] = field(default_factory=list)
    adkim: str = "r"            # r relaxed | s strict
    aspf: str = "r"

    @property
    def present(self) -> bool:
        return self.raw.lower().startswith("v=dmarc1")

    @property
    def has_teeth(self) -> bool:
        return self.policy in ("quarantine", "reject") and self.pct >= 100


def parse_spf(raw: str) -> SpfRecord:
    raw = raw.strip().strip('"')
    rec = SpfRecord(raw=raw)
    if not rec.present:
        return rec
    for tok in raw.split()[1:]:
        low = tok.lower()
        if low.endswith("all") and low[:-3] in ("-", "~", "?", "+", ""):
            rec.all_qualifier = low[:-3] or "+"
        else:
            rec.mechanisms.append(tok)
    return rec


def parse_dmarc(raw: str) -> DmarcRecord:
    raw = raw.strip().strip('"')
    rec = DmarcRecord(raw=raw)
    if not rec.present:
        return rec
    for part in raw.split(";"):
        part = part.strip()
        if not part or "=" not in part:
            continue
        k, _, v = part.partition("=")
        k, v = k.strip().lower(), v.strip()
        if k == "p":
            rec.policy = v.lower()
        elif k == "pct":
            try:
                rec.pct = int(v)
            except ValueError:
                rec.pct = 100
        elif k == "rua":
            rec.rua = [a.strip() for a in v.split(",") if a.strip()]
        elif k == "adkim":
            rec.adkim = v.lower()
        elif k == "aspf":
            rec.aspf = v.lower()
    return rec


def dkim_selector_present(raw: str) -> bool:
    """A DKIM selector TXT record looks like `v=DKIM1; k=rsa; p=<base64>`.

    We only check that a key is published and non-empty (`p=` with content). Key
    length and rotation are the provider's job; what the spike cares about is
    whether mail from this domain can be DKIM-signed at all.
    """
    raw = raw.strip().strip('"')
    low = raw.lower()
    if "v=dkim1" not in low and "k=rsa" not in low and "p=" not in low:
        return False
    for part in raw.split(";"):
        k, _, v = part.strip().partition("=")
        if k.strip().lower() == "p":
            return len(v.strip()) > 0
    return False


@dataclass
class AuthRecords:
    domain: str
    spf: SpfRecord
    dmarc: DmarcRecord
    dkim_selectors: dict[str, bool]   # selector -> key published

    @property
    def any_dkim(self) -> bool:
        return any(self.dkim_selectors.values())


def grade(records: AuthRecords) -> AuthGrade:
    if not records.spf.present or not records.any_dkim or not records.dmarc.present:
        return AuthGrade.MISSING
    if not records.dmarc.has_teeth:
        return AuthGrade.WEAK
    if records.spf.all_qualifier not in ("-", "~"):
        return AuthGrade.WEAK
    return AuthGrade.STANDARD


def notes(records: AuthRecords) -> list[str]:
    out: list[str] = []
    if records.spf.present and records.spf.all_qualifier == "~":
        out.append("SPF uses ~all (softfail); -all is stricter but DMARC teeth matter more")
    if records.dmarc.present and records.dmarc.policy == "none":
        out.append("DMARC p=none — monitoring only, provides no anti-spoofing enforcement")
    if records.dmarc.present and not records.dmarc.rua:
        out.append("DMARC has no rua= — you will not see auth failures until users report them")
    if records.dmarc.present and records.dmarc.policy == "quarantine":
        out.append("DMARC p=quarantine is the launch floor; ramp to p=reject once rua is clean")
    return out


# --- network side: capture DNS into a JSON the offline grader reads --------------

def _dig_txt(name: str) -> list[str]:
    proc = subprocess.run(
        ["dig", "+short", "TXT", name],
        capture_output=True, text=True, timeout=15, check=False,
    )
    out: list[str] = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line:
            out.append(line.strip('"'))
    return out


def capture(domain: str, dkim_selectors: list[str], out_path: str) -> AuthRecords:
    spf_raw = next((r for r in _dig_txt(domain) if r.lower().startswith("v=spf1")), "")
    dmarc_raw = next(
        (r for r in _dig_txt(f"_dmarc.{domain}") if r.lower().startswith("v=dmarc1")), ""
    )
    selectors: dict[str, bool] = {}
    for sel in dkim_selectors:
        recs = _dig_txt(f"{sel}._domainkey.{domain}")
        selectors[sel] = any(dkim_selector_present(r) for r in recs)

    records = AuthRecords(
        domain=domain,
        spf=parse_spf(spf_raw),
        dmarc=parse_dmarc(dmarc_raw),
        dkim_selectors=selectors,
    )
    with open(out_path, "w") as fh:
        json.dump(
            {
                "domain": domain,
                "spf_raw": spf_raw,
                "dmarc_raw": dmarc_raw,
                "dkim_selectors": selectors,
                "grade": grade(records).value,
                "notes": notes(records),
            },
            fh,
            indent=2,
        )
    return records
