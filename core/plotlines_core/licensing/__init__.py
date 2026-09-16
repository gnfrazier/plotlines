"""Software-notice machinery — issue #267, addendum L5.

Distinct from `curation/attribution.py`: that module is FR101's *data*
attribution, derived from the loaded layer set at render time. This package is
*software* notices — the licence texts owed for the third-party packages the
frozen sidecar ships. That obligation is a static artifact of the build, not
something a request-time registry can enumerate, which is why it lives in its
own package rather than folding into `curation.attribution` (`web/about.py`
keeps the two as separate lists for exactly this reason).

`generate.py` runs at freeze time (`packaging/build_sidecar.sh`) against the
build venv's installed distributions and writes the `THIRD_PARTY_LICENSES`
bundle. `software_notices.py` reads that same bundle back at runtime so
`web/about.py` can surface it. The two share one record format — a change to
one is a change to both.
"""
