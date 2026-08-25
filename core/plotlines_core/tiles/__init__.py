"""Basemap tile serving (ARCH §8.2 `GET /tiles/{z}/{x}/{y}`; PRD FR92-94).

Pure library code (P1: no fastapi import) — `archive.py` reads a PMTiles
archive on disk, `extract.py` derives a bbox-scoped subset of one archive
from another. This is the one pipeline `service/plotlines_service/app.py`'s
`/tiles` endpoint and any future offline-package export both read through
(FR94: "the same pipeline is the origin for live map requests and offline
packages").
"""
