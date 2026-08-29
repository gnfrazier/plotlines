# SPIKE-13 results — Magic-link email deliverability

**Recorded:** 2026-08-29 · **Issue:** [#168](https://github.com/gnfrazier/plotlines/issues/168)
**Covers:** PRD **FR57** · story **K1** `[MVP]` · ARCH **D9**, §10.3

---

## Verdict

**FALLBACK — and the decision is made on that basis.** Magic-link-only auth should
ship with a documented backup path, not as the sole route in and out of an account.

This lands on the second branch of the issue's *Done when*:

> Delivery rate and time-to-inbox meet a bar you'd stake login on across the major
> mail hosts, **or the gap is documented so the auth approach can add a fallback
> before Web ships.**

The gap is documented here, the fallback is specified below, and the live harness
(`run.py --live`) is committed so the FALLBACK→STAKE question can be re-measured
with real numbers once the custom domain exists.

## Why this is not a live measurement

The live half needs infrastructure that does not exist yet and is not worth
standing up early *for this spike alone*:

* a **registered custom domain** — already a hard prerequisite for the Web leg via
  risk **A10** (`*.onrender.com` breaks the session cookie in Safari/Firefox);
* **DNS control** to publish SPF, DKIM, and a DMARC policy with `rua` reporting;
* a **funded transactional-email provider account** past its sandbox limits;
* **seed mailboxes** on all six major consumer hosts, each with IMAP access.

Standing that up ahead of the Web leg would only be wasted effort if the answer
were obviously STAKE. It is not — see below — so the spike resolves via **prior
art** (the move SPIKE-18 made for the elevation provider) plus a pre-registered bar
and a ready-to-run harness.

## What prior art says

`providers.py::PRIOR_ART` compares the realistic candidates on the axes that decide
this: IP-reputation model, whether transactional traffic is isolated from bulk,
warmup cost, and delivery-event webhooks. Sources are each provider's own
deliverability docs and status history, plus the cycling-tour-planner POC's use of
SES for non-login mail.

The consistent picture: a **correctly authenticated** transactional sender on a
**warmed** custom domain delivers to the inbox in the **~98–99%+** range with a
**seconds** median. That is precisely the **STAKE/FALLBACK boundary** — good enough
that most users never notice, not so airtight that the 1-in-50 case (a Microsoft or
Yahoo spam-file, a greylisting deferral in the tail) can be ignored when it is
someone's *only* way in. It is not a BLOCK: no major host is reported to routinely
drop authenticated transactional mail.

The synthetic `results/sample_run.json` is shaped to that profile — 98.7% inbox,
1.3% spam concentrated on Microsoft/Yahoo, p50 9 s, p95 33 s — and
`analyze.py` classifies it **FALLBACK**, failing STAKE on the overall inbox rate,
the p95, and the two hosts' spam placement. It is a fixture that pins the band
logic, **not a measured result**, and is labelled `"synthetic": true`.

## Decides

### Provider — **Postmark**, dedicated transactional Message Stream

* Isolates transactional mail from any future marketing mail **by construction**
  (separate stream), so a campaign can never poison login deliverability.
* **No IP warmup** for the shared transactional stream — sender signature + DKIM
  verification only.
* Delivery-event webhooks (delivered / bounced / spam-complaint) out of the box.
* Median send-to-delivery in seconds; positioned specifically on transactional
  inbox placement.

**Documented alternative: AWS SES**, if per-message cost dominates at volume. It is
already in the POC for non-login mail. The catch is a **4–6 week dedicated-IP
warmup** — SES cannot be a late swap-in; choosing it is a schedule commitment to
start sending real traffic weeks before Web launches. SendGrid's shared pool has a
long history of co-tenant reputation problems for exactly this use case and is not
the first pick. Resend is fine as a second source but its isolation guarantee is
weaker than Postmark's (it is SES underneath).

### Sender configuration — one domain, decided once

* From `login@<web-domain>` (or an `auth.` subdomain) on the **same registrable
  domain as the Web app**.
* **SPF** ending `-all` or `~all`; **DKIM** published by the provider (verify the
  key is present — `authcheck.py`); **DMARC** `p=quarantine; rua=mailto:…` as the
  launch floor, ramping to `p=reject` once the aggregate reports are clean.
* `authcheck.py::grade` encodes this: SPF + aligned DKIM + DMARC with teeth =
  `STANDARD`; `p=none` or a neutral SPF qualifier = `WEAK`; any of the three
  missing = `MISSING`.

**This is the same domain decision as ARCH §10.3 / risk A10.** The custom domain
that makes the session cookie first-party also carries sender reputation for the
magic-link mail. Settle it once, for both, rather than twice.

### Is magic-link-only safe as the sole path? — **No. Ship K1 with a backup.**

1. **In-product re-send** with a visible cooldown. The verify endpoint must be
   idempotent, and a re-request must not strand the user between two links (either
   invalidate the prior link or keep both valid within the TTL).
2. **Link TTL ≥ 15 minutes**, so a greylisting deferral (commonly 1–15 min on
   first contact between two domains) does not expire the link before it arrives.
3. **A support recovery route** — identity-checked manual link issuance, written up
   as a runbook — for the user whose mail host is silently dropping. This is the
   thing that replaces "reset your password" and it must exist before Web ships.
4. **Delivery telemetry** — consume the provider's delivered / bounced /
   spam-complaint webhooks and alert on a rate regression, so a deliverability
   problem is visible before it becomes a support queue.

If a later live run clears STAKE, (3) and (4) stay — they are cheap insurance — but
the re-send UI can be de-emphasised.

## Doc edits this spike owes (K1 / #107 carries them)

* **PRD FR57 / K1 AC** — "magic link is the only auth **and the recovery path**"
  becomes "magic link is the only auth; **recovery is re-send plus a support-issued
  link**, not a password."
* **ARCH D9** — annotate: "Magic-link-only auth, **with a re-send + support
  recovery fallback (SPIKE-13)**."
* **ARCH §10.3** — note that the custom domain also carries sender reputation for
  magic-link mail: one domain decision, not two.
* **`Plotlines_Research_Spikes.md`** — SPIKE-13 entry + summary-table row: resolved
  2026-08-29 on the documented-gap branch.
* **`Plotlines_MVP_Redirection_Punchlist.md` §6** — SPIKE-13 row: resolved.

## No product code changed

`plotlines-core` and `plotlines-service` are untouched. `bands.py` /
`analyze.py` / `authcheck.py` are spike-local. The live adapters in `providers.py`
and `probe.py` are stdlib-only and are exercised only when a real API key is
present.
