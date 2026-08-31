"""FIT CRC-16 — the checksum a head unit uses to reject a structurally broken file.

FIT's file CRC and (optional) header CRC are **CRC-16/ARC**: reflected polynomial
0xA001, initial value 0x0000, no final XOR. That is exactly what the nibble-table
routine in the Garmin FIT SDK (`FitCRC_Get16` in `fit_crc.c`) computes; a
256-entry table is used here because it is easier to read and to test.

The first finding of this spike lives in this file: **the byte-exact parts of
FIT are small and fully specified.** This module is validated in `run.py` and
`tests/test_crc.py` against the stored header CRC and trailing file CRC of every
real `.fit` file in `spikes/fit_files/` — 10 files, 10/10 both CRCs — so it is
not "matches a validator", it is "matches what real Garmin devices wrote".

`basis`: FIT SDK "FIT File Types Description" §3.3.1; `fit_crc.c`. CRC-16/ARC
check value for "123456789" is 0xBB3D (asserted in the tests).
"""

from __future__ import annotations

_POLY = 0xA001

_TABLE = []
for _n in range(256):
    _c = _n
    for _ in range(8):
        _c = (_c >> 1) ^ _POLY if _c & 1 else _c >> 1
    _TABLE.append(_c & 0xFFFF)
_TABLE = tuple(_TABLE)


def fit_crc16(data: bytes, crc: int = 0) -> int:
    """Running FIT CRC-16 over ``data``, seeded with ``crc`` (0 for a fresh run).

    Seedable so a caller can checksum the header, then continue the same running
    value through the data section — the SDK's streaming pattern.
    """
    for byte in data:
        crc = (crc >> 8) ^ _TABLE[(crc ^ byte) & 0xFF]
    return crc & 0xFFFF
