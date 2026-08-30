"""Web-tier seams that are pure policy, not FastAPI (P1 — no fastapi import).

`session` owns the same-site session-cookie contract (story M4). See ARCH §10.3.
"""
