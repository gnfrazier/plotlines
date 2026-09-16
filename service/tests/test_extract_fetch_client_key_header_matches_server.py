"""Issue #274/#262 — `plotlines_core.graph.extract_fetch.CLIENT_KEY_HEADER`
and `plotlines_service.mirror_clip.CLIENT_KEY_HEADER` must name the exact
same HTTP header, or the client's `--mirror-clip-client-key` silently stops
authenticating against a mirror with `--client-key` set. `plotlines_core`
may not import anything from `plotlines_service` (P1's layering runs the
other direction), so the two constants are independently defined and
pinned equal here instead, from the one module that is allowed to import
both.
"""

from __future__ import annotations

from plotlines_core.graph.extract_fetch import CLIENT_KEY_HEADER as CORE_HEADER
from plotlines_service.mirror_clip import CLIENT_KEY_HEADER as SERVICE_HEADER


def test_client_key_header_names_match_byte_for_byte():
    assert CORE_HEADER == SERVICE_HEADER


def test_pin_header_matches_what_the_server_actually_sends():
    # mirror_clip.py hardcodes the literal in its response headers dict
    # rather than a shared constant (see `_run_clip`'s
    # "X-Plotlines-Clip-Source-Pin" entry) — pinned here too so the two
    # never drift silently.
    from plotlines_core.graph.extract_fetch import PIN_HEADER
    assert PIN_HEADER == "X-Plotlines-Clip-Source-Pin"
