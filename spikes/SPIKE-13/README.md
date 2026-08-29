# SPIKE-13 — Magic-link email deliverability

**Issue:** [#168](https://github.com/gnfrazier/plotlines/issues/168) ·
**Covers:** PRD **FR57** · story **K1** `[MVP]` · ARCH **D9**, §10.3 ·
**Run before:** the Web / accounts leg (Leg 4) ·
**Result:** [`results/RESULTS.md`](results/RESULTS.md)

```bash
# offline — the CI-safe self-check. Re-derives every published figure from the
# committed sample and asserts the band logic still lands where RESULTS.md says.
python spikes/SPIKE-13/run.py --dry-run

# offline — just the analysis, over the committed sample or a real run file
python spikes/SPIKE-13/analyze.py results/sample_run.json results/deliverability.json

# live — needs a custom domain, a provider API key, and seed mailboxes (see below)
SPIKE13_PROVIDER=postmark SPIKE13_FROM=login@auth.plotlines.app \
  python spikes/SPIKE-13/run.py --live seeds.json

# tests
core/.venv/bin/python -m pytest spikes/SPIKE-13/tests -q
```

## Why this spike exists

Magic-link-only auth has a single point of failure **by design**: no password, no
SMS OTP (ARCH D9). If the login email lands in spam, is delayed minutes, or is
dropped, the user cannot log in. Whether a transactional-email provider delivers
reliably and within seconds — across the major consumer mail hosts and their spam
filters — is the feasibility question, and its failure cost is unusually high.

## The two halves, and why one of them is prior art

**The bar (`bands.py`) and the analysis (`analyze.py`) are complete and tested.**
The thresholds are pre-registered — declared before any number arrives — the same
discipline SPIKE-21 used with its cues/km ceiling and SPIKE-C used with its
coverage bands. Three bands:

| band | meaning |
|---|---|
| **STAKE** | inbox delivery is good enough to be the sole path — ship K1 as the PRD writes it |
| **FALLBACK** | fast on the median, ragged in the tail or on one host — ship K1 **with a documented backup** |
| **BLOCK** | a major consumer host drops or spam-files login mail often enough that no fallback rescues it |

The rollup can never launder one bad host: a 99% overall with Yahoo at 80% inbox
is a BLOCK, because a user does not pick their mail provider when they sign up.

**The live measurement is not run here**, because it needs infrastructure that does
not exist until the Web leg: a registered custom domain (already a hard
prerequisite via risk A10), DNS control for SPF/DKIM/DMARC, a funded provider
account, and seed mailboxes on all six major consumer hosts. What stands in for it
is **prior art** — provider deliverability documentation plus the
cycling-tour-planner POC's use of SES for its (non-login) mail — exactly the move
SPIKE-18 made for the elevation provider. `providers.py::PRIOR_ART` is that
comparison as data, and `results/RESULTS.md` is the decision it supports.

The live half (`providers.py::send_one`, `probe.py`, `run.py --live`) is
**committed and ready** so the FALLBACK→STAKE question can be re-tested with real
numbers the moment the domain exists.

## Seed mailboxes (live half)

A JSON file kept **out of git** (it holds IMAP credentials). One entry per major
consumer host; shape is documented in `probe.py`. Use app-passwords, not primary
credentials, and dedicated throwaway accounts.

## Files

| file | what it is |
|---|---|
| `bands.py` | The pre-registered STAKE / FALLBACK / BLOCK thresholds and the classifier. **Change these only with a reason written down.** |
| `authcheck.py` | SPF / DKIM / DMARC record parsing and grading; `dig`-based capture for the live run |
| `providers.py` | `PRIOR_ART` provider comparison (data, not a measurement) + thin stdlib send adapters |
| `probe.py` | Live half: IMAP-poll each seed mailbox, classify placement, time the arrival |
| `analyze.py` | Offline: a run file → delivery rate, time-to-inbox percentiles, per-host rollup, verdict |
| `run.py` | `--dry-run` self-check gate; `--live` orchestrator |
| `results/sample_run.json` | **Synthetic** fixture — not a measured run. Exercises `analyze.py` and pins the bands. |
| `results/deliverability.json` | `analyze.py` output over the sample |
| `results/RESULTS.md` | The verdict and what it decides |
| `tests/` | `pytest` over the bands, the auth parsing, and the analysis |

## No product code changed

Same discipline as SPIKE-C / SPIKE-D / SPIKE-H: nothing here edits `plotlines-core`
or `plotlines-service`. What the spike decides is written up in `results/RESULTS.md`
and reconciled into the PRD/ARCH by the story that owns it (K1 / #107).
