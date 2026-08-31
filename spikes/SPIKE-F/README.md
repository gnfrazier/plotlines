# SPIKE-F — Anonymous web reading surface

Settles the three strands of **ARCH Q17 / risk A26** for the Character-facing
web reading view (`GET /read/{share_token}`, PRD FR132 / story H13), per
issue [#175](https://github.com/gnfrazier/plotlines/issues/175). This is a
**joint design, security and product decision, not a library choice** — the
harness here exists to make each strand's answer checkable rather than
asserted. **Verdict and full write-up: [`results/RESULTS.md`](results/RESULTS.md).**

```bash
python3 spikes/SPIKE-F/run_spike.py          # -> results/run_spike.json
python3 -m pytest spikes/SPIKE-F/tests -q    # 10 assertions
```

No virtualenv needed. The harness is stdlib-only (`http.server`,
`http.client`, `hmac`) and imports **no `plotlines_core`** — the reveal
resolver ARCH names lives in the Flutter Data layer, so the anonymous-view
projection is modelled here, the same standing as SPIKE-G's calibrated model.

## The three strands, and what each file demonstrates

| Strand | File | What it shows |
|---|---|---|
| **1 — token carrier** | `carriers.py` | A live stdlib server records every request line + header into an in-memory access log. Four carriers each fetch a page then a subresource: **path** and **query** put the token in the access log *and* in the `Referer` of every subresource; **fragment** keeps it off the wire but not out of browser history; **exchange-for-cookie** puts the token in the log exactly once (the one-time redirect) and every later request carries only an opaque `__Host-` `HttpOnly; Secure; SameSite=Strict` cookie that is *not* the token. |
| **2 — log retention** | `logredact.py` | `redact_record` is an allowlist (same discipline as `granted_fields`, ARCH §11.1): a raw access record collapses to a **route template** (`/read/{share_token}`), no token, no `Referer`, no cookie, client IP truncated to /24, with a `retain_until` stamp. Two tiers: edge/CDN logs **≤72 h**, app logs **≤30 d**. |
| **3 — anonymous reveal model** | `anonview.py`, `fixtures.py` | `anonymous_view(payload)` takes **no identity argument** and resolves the reader as a Character whose revealed set is permanently empty. Hazards (role and passage-level) and provisions are always emitted in full; an `on_arrival` narrative role becomes a **withheld placeholder** that keeps its `kind` and `arc` stage but drops all content — so FR116's "the arc's shape survives" holds while the crux plot point never reaches the page. |

## Files

| File | What |
|---|---|
| `carriers.py` | strand 1 — server, access-log capture, four carrier strategies |
| `logredact.py` | strand 2 — allowlist redactor + retention windows |
| `anonview.py` | strand 3 — `anonymous_view()` projection + `arc_shape()` |
| `fixtures.py` | a small trip payload mixing provision / always-visible / on-arrival / hazard roles + passage hazards + arc stages |
| `run_spike.py` | runs all three strands, writes `results/run_spike.json`, prints a 9-line verdict |
| `tests/test_spike_f.py` | 10 assertions, stdlib only |
| `results/RESULTS.md` | the write-up |
| `results/run_spike.json` | full dump |

## What is real, and what stands in

**The token-carrier behaviour is exercised, not argued.** The server and the
access log are real; the leak into `Referer` on a subresource is a real
request the harness makes and reads back. The one browser behaviour a
non-browser client cannot exercise is the URL **fragment** — by RFC 3986
§3.5 it is never sent to the server and browsers strip it from `Referer` —
so the `fragment` strategy models that by construction and the assertions
credit it only with what it actually buys (off the wire) and not with what
it does not (browser history, clipboard).

**No product code changed** — same discipline as SPIKE-A/C/D/G/H. The
outputs are the decision text now in ARCH (D59, Q17 closed, A26 amended) and
PRD (FR138, FR116, H13's gate), plus this checkable prototype of the shape
each decision implies.
