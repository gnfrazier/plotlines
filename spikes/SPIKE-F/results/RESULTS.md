# SPIKE-F — Anonymous web reading surface · RESULTS

**Issue:** [#175](https://github.com/gnfrazier/plotlines/issues/175) ·
**Covers:** PRD **FR132**, **FR116**, **FR138** — story **H13** `[P1]`;
ARCH §10.3, **Q17**, risk **A26** ·
**Run:** 2026-08-30 ·
**Harness:** [`spikes/SPIKE-F/`](../) — stdlib only, `run_spike.json` regenerated each run.

---

## Verdict

**Q17's "likely resolution" holds on all three strands, and the one place it
was under-specified is now pinned.** An anonymous share-token reader is
served the **always-visible set only**; revealed content requires an
account. The two strands Q17 framed as security questions each have a
concrete mechanism rather than a posture, and both were checkable, so they
were checked:

| Strand | Decision | Evidence |
|---|---|---|
| **1 — token carrier** | The share token is **exchanged once for an opaque `__Host-` session cookie** (`HttpOnly; Secure; SameSite=Strict`, `Max-Age` = token TTL). The token appears in the request path on exactly **one** hit — the initial `GET /read/{token}` that 302-redirects to a tokenless `/j/{opaque}` — and never again. `Referrer-Policy: no-referrer` on every reading-view response. | `run_spike.json` → `strand1`. Path and query carriers put the token in the access log **and** in the `Referer` of every subresource (2/2 requests). Fragment keeps it off the wire but `residual_exposure: [browser_history, clipboard_when_copied]`. Exchange: `token_hits_in_log == 1`, `cookie_is_token == false`, `cookie_httponly == cookie_samesite == true`. |
| **2 — log retention** | Two tiers. **Edge/CDN access logs**: cannot be made not to exist, so the mitigation is Strand 1 (no token in the URL ⇒ no token in them) plus a short window — **≤72 h, operational only**. **Application request logs**: Plotlines-shaped, written through an **allowlist** — route *template* not URL, no token, no `Referer`, no cookie, client IP truncated to /24, `retain_until` stamped — **≤30 d**. FR138's privacy statement now says this in plain words and is reachable from About on the reading view itself. | `run_spike.json` → `strand2`. `redacted` keys = `{ts, method, route, status, bytes, cache_status, ua_family, client_ip, retain_until}`; `_dropped_fields` = `{path, query, referer, cookie, user_agent}`; `token_leaks == false`; `route == "/read/{share_token}"`; `client_ip 203.0.113.47 → 203.0.113.0/24`. |
| **3 — reveal for an accountless reader** | The reader is resolved as a Character whose **revealed set is permanently empty** — not a special code path, just the empty-set case of the existing reveal model. `anonymous_view(payload)` takes **no identity argument**, so there is no "trusted reader" flag to become a spoiler path. An `on_arrival` plot point renders as a **withheld placeholder** that keeps its `kind` and `arc` stage but no content — *not* an omission, because FR116 requires the arc's shape to survive and a hole cannot carry shape. Hazards (role-level and passage `hazards[]`) and provisions are always emitted in full. | `run_spike.json` → `strand3`. `secret_plot_point_leaks == false`; `hazard_content_present == provision_content_present == true`; `arc_shape == [exposition, crux, rising_action]` (crux **position** kept, crux **content** not); `roles_by_visibility == {visible: 2, withheld: 1, hazard: 1}`; `deterministic == true`. |

`run_spike.py` exits non-zero unless all nine verdict clauses hold; they do.

---

## Strand 1 — token handling, in detail

Four carriers, each fetching a reading page then one subresource, with the
server recording every request line and header:

| Carrier | Token in access-log URL | Token in `Referer` of subresource | Residual |
|---|---|---|---|
| **path** `/read/{token}` | yes — every request | **yes — every subresource and outbound link** | — |
| **query** `/read?t={token}` | yes — every request | **yes** | — |
| **fragment** `/read#{token}` | no (RFC 3986 §3.5 — never sent) | no (browsers strip `#…` from `Referer`) | **browser history, clipboard, and it needs JS to read the token then still has to exchange it** |
| **exchange-for-cookie** | **once** — the initial redirected hit | no | token still lands in history **once**; mitigated by a short token TTL and the token being single-use at exchange |

**Why exchange-for-cookie wins over fragment.** Fragment removes the token
from server logs but not from the two client-side surfaces Q17 also names
(history, and a copied URL), and a fragment token has to be read by
JavaScript and sent to the server *somehow* — which is the exchange step
again, just done less cleanly. Exchange-for-cookie confines the token to a
single request, converts it to an opaque `HttpOnly` cookie the page's JS
cannot read (XSS can't lift it), and `SameSite=Strict` keeps it off
cross-site navigations entirely. This is the same reasoning ARCH D15 used
for the signed-in session cookie, one auth shape down.

**The token contract from ARCH §10.3 survives the carrier change.** It is
still revocable (`DELETE /shares/{token}` invalidates the token *and*, via a
`share.revoked_at` check on every `/j/{opaque}` request, the cookies minted
from it) and still scoped to one trip's reveal-filtered content. The cookie
carries no more authority than the token did.

---

## Strand 2 — what is logged, and for how long

`redact_record` is written as an **allowlist**, not a scrubber: a field
added to the raw record later is dropped by default (`_dropped_fields`
reports what it caught), so a future change to the log shape trips a test
rather than leaking. What survives into an application log line for an
accountless reader:

```json
{"ts": "...", "method": "GET", "route": "/read/{share_token}",
 "status": 200, "bytes": 5123, "cache_status": "HIT",
 "ua_family": "firefox", "client_ip": "203.0.113.0/24",
 "retain_until": "..."}
```

No token, no full path, no `Referer`, no cookie, no raw User-Agent (family
only — one fewer fingerprinting bit, consistent with §11.2's "web guests
persist no preferences"). **Edge/CDN logs** are the harder case because they
are written before any Plotlines code runs; the answer is that Strand 1
keeps the token out of the URL so it is out of them regardless, and the
retention window is short (**≤72 h**). Application logs: **≤30 d**.

**FR138 consequence.** The privacy statement must now state, in the app's
voice, on the reading view itself: what a reader with no account leaves
behind (a short-lived operational log line with a truncated IP, no account,
no name), that it is deleted on that schedule, and — unchanged — that reveal
is a product guarantee and not a security boundary.

---

## Strand 3 — the reveal model for an accountless reader

This is the strand Q17 flagged as "the interesting one … a model gap." The
gap closes without new machinery:

- **There is no `reveal_state` row for an anonymous reader and there never
  will be.** Rather than invent a home for it, the reader is the *empty
  revealed set* — every `on_arrival` role is unrevealed, permanently.
- **`anonymous_view(payload)` has no identity parameter.** `inspect`
  confirms the signature is `(payload)` only. There is deliberately nowhere
  to pass "this reader is allowed to see more", because that parameter is
  exactly how the export-corner spoiler (A22) happens.
- **Withheld ≠ omitted.** The crux role at the overlook renders as
  `{kind: narrative, arc: "crux", withheld: true, note: "A plot point is
  held here until you arrive…"}`. The reader learns a plot point exists and
  where it sits in the arc; they do not learn what it says. `arc_shape()`
  over the projection still returns `[exposition, crux, rising_action]`.
- **Hazards and provisions are unconditional.** The role-level hazard on the
  same anchor as the withheld crux, and the segment's `hazards[]` fords, and
  the spring's water note all render in full. FR116's "shows every
  provision, every hazard, and the arc's shape" holds.

**Placeholder copy vs. nothing at all** — Q17 asks which. The spike
recommends the **placeholder**: FR116 makes the arc's shape a requirement,
an invisible gap conveys no shape, and the placeholder is also the honest
teaching moment ("this is held for arrival — that is the product working,
not broken", FR142(e)).

---

## Decides

- **ARCH Q17 — closed.** Anonymous reader = always-visible set only;
  revealed content requires an account.
- **Risk A26 — mitigation is now concrete, not "a spike":** token
  exchanged once for an opaque `__Host-` `HttpOnly; Secure; SameSite=Strict`
  cookie; `Referrer-Policy: no-referrer`; two-tier log retention with an
  allowlisted app-log record; anonymous reader resolved as the empty
  revealed set with no identity parameter to subvert.
- **New Decision Log entry D59** records the above.
- **FR138** updated to state the accountless-reader log posture truthfully.
- **FR116 / H13** — the gate is satisfied for the web leg: a web copy
  cannot spoil the trip, and shows every provision, every hazard, and the
  arc's shape.

## Done when

The token carrier, the log-retention posture, and the anonymous-reader
reveal model are decided and recorded as a Decision Log entry, with FR138's
privacy statement updated to match — **before any web presentation ships.**
**Met** — D59 added, Q17 closed, A26 amended, FR138/FR116/H13 updated, and
each decision has a checkable prototype here.

## Left open, deliberately

- **The `/read` endpoint and the Flutter reading view are not built** —
  this spike is gated to the web/hosted leg (Leg 4) and settles the
  decision, not the implementation. `RevealResolver` in the Dart Data layer
  is where `anonymous_view`'s logic lands when H13 is built; the projection
  here is the spec for it.
- **`share.revoked_at` propagation to minted cookies** is specified (check
  on every `/j/{opaque}` hit) but not load-tested — it is one indexed
  lookup per request and the same shape as the session check, so it was not
  worth a harness.
- **CDN choice** — the ≤72 h edge-log window is a configuration the hosting
  decision (ARCH §10.3, Render + custom domain) has to honour; if a chosen
  CDN cannot bound access-log retention that tightly, that is a procurement
  constraint this spike surfaces, not a design change.
- **TTS on the reading view** (FR40a / H13) reads only what the resolver
  released, so it inherits Strand 3 unchanged; not separately exercised.

**Closed.**
