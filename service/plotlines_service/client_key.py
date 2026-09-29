"""The shared Plotlines-client key (issue #263), in a module of its own so
the elevation proxy (#520) can gate its fills the same way the mirror does
without importing `mirror_clip`, whose pyosmium import needs `libexpat1` in
the image (#369). `mirror_clip` re-exports both names."""

from __future__ import annotations

#: Issue #263 — the shared Plotlines-client key every restricted `/clip`
#: request carries. Named as a module constant so a future client-side
#: caller (Phase 3, #272) has one spelling to import rather than a string
#: to copy.
CLIENT_KEY_HEADER = "X-Plotlines-Client-Key"


def normalize_client_key(raw: str | None) -> str | None:
    """Issue #371: collapse "no key configured" onto exactly one value.

    `deploy/mirror/docker-compose.yml` passes
    `MIRROR_CLIP_CLIENT_KEY=${MIRROR_CLIP_CLIENT_KEY:-}`, so an operator
    who leaves the variable unset — the documented default, and the one
    `--client-key --help` calls "leaves /clip open" — does not get an
    absent variable. Compose sets it to the empty string, `os.environ.get`
    returns `""` rather than `None`, and an `is not None` test arms the
    gate with a key no honest caller can present: 401 for everyone, while
    `hmac.compare_digest("", "")` would let a caller sending the header
    with an empty value straight through. Both halves of that come from
    treating `""` as a configured key, so it is fixed here once rather
    than at each reader.

    Whitespace is stripped for the same class of reason one step further
    out: a key sourced from a file or a heredoc arrives with a trailing
    newline attached, which is a deployment accident every time and a
    deliberate key never.

    Idempotent, so applying it at both the argparse and the app-
    construction boundary is safe.
    """
    if raw is None:
        return None
    return raw.strip() or None
