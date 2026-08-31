"""Pure-Python FIT container encoder — zero dependencies.

Ported into `plotlines-core` from `spikes/SPIKE-16/{crc,fitenc}.py` (SPIKE-16,
issue #163). The spike priced the FFI-against-Garmin's-SDK alternative and found
it buys no fidelity while costing a native per-platform dependency (risk A5), the
FIT SDK redistribution obligation, and a fork of one of four formats off the
shared `export_trip` code path. So the FIT arm stays here, in the core's own
language, small enough to hold behind the reveal gate (ARCH §6.1, §13.3).

This module is the byte-level container only: the 14-byte file header, the
definition/data message framing, and the CRC. The *course* sub-profile (which
messages, which fields, which unit encodings) lives in `_fit_profile.py`; the
trip-to-course-file mapping and the reveal gate live in `fit.py`.

Layout produced:  [14-byte header + header CRC] [data records] [file CRC]
"""

from __future__ import annotations

import struct

from plotlines_core.export._fit_profile import BASE_TYPES, FIELDS, MESG

_PROTOCOL_VERSION = 0x20   # FIT protocol 2.0
_PROFILE_VERSION = 21158   # SDK 21.158 — informational; devices do not gate on it

_CRC_POLY = 0xA001         # CRC-16/ARC, reflected

_CRC_TABLE = []
for _n in range(256):
    _c = _n
    for _ in range(8):
        _c = (_c >> 1) ^ _CRC_POLY if _c & 1 else _c >> 1
    _CRC_TABLE.append(_c & 0xFFFF)
_CRC_TABLE = tuple(_CRC_TABLE)


def fit_crc16(data: bytes, crc: int = 0) -> int:
    """Running FIT CRC-16/ARC over ``data``, seeded with ``crc`` (0 for a fresh run).

    This is what ``FitCRC_Get16`` in the Garmin SDK's ``fit_crc.c`` computes. It
    is validated against the stored header and file CRC of the real device files
    in ``spikes/fit_files/`` by ``spikes/SPIKE-16/tests/test_crc.py`` — "matches
    what real Garmin devices wrote", not "matches a spec reading". The canonical
    CRC-16/ARC check value for ``b"123456789"`` is ``0xBB3D``.
    """
    for byte in data:
        crc = (crc >> 8) ^ _CRC_TABLE[(crc ^ byte) & 0xFF]
    return crc & 0xFFFF


class FitEncoder:
    """Emits the normal-header definition/data stream a FIT *course* file uses.

    One local message type is reused per message name — a course file never needs
    more than a handful concurrently. A definition is re-emitted only when a
    message's field layout changes (e.g. ``altitude`` first appearing on a
    ``record``).
    """

    def __init__(self) -> None:
        self._body = bytearray()
        self._local_for: dict[str, int] = {}
        self._def_sig: dict[int, bytes] = {}
        self._next_local = 0

    # -- public API --------------------------------------------------------

    def write(self, mesg_name: str, fields: dict[int, object]) -> None:
        """Append one data message. ``fields`` is ``{field_number: value}``.

        A value of ``None`` is dropped — the field is simply not written, which
        is how FIT represents "absent" (cleaner than writing the invalid
        sentinel, and how ``fit.py`` suppresses toggled-off contents).
        """
        mesg_num = MESG[mesg_name]
        field_defs = FIELDS[mesg_name]
        present = sorted((fn, v) for fn, v in fields.items() if v is not None)

        encoded = []
        for fn, value in present:
            _name, base_type = field_defs[fn]
            encoded.append((fn, base_type, self._encode_value(base_type, value)))

        local = self._ensure_definition(mesg_name, mesg_num, encoded)
        rec = bytearray([local & 0x0F])           # normal data header
        for _fn, _bt, raw in encoded:
            rec += raw
        self._body += rec

    def getvalue(self) -> bytes:
        """The finished file: header + header CRC + data + trailing file CRC."""
        data_size = len(self._body)
        header = bytearray()
        header += struct.pack(
            "<BBHI", 14, _PROTOCOL_VERSION, _PROFILE_VERSION, data_size
        )
        header += b".FIT"
        header += struct.pack("<H", fit_crc16(bytes(header)))
        out = bytes(header) + bytes(self._body)
        return out + struct.pack("<H", fit_crc16(out))

    # -- internals -------------------------------------------------------

    @staticmethod
    def _encode_value(base_type: str, value: object) -> bytes:
        _tbyte, _tsize, code, _invalid = BASE_TYPES[base_type]
        if base_type == "string":
            raw = value.encode("utf-8") if isinstance(value, str) else bytes(value)
            return raw + b"\x00"                  # NUL-terminated; length set in the definition
        return struct.pack("<" + code, int(value))  # type: ignore[arg-type]

    def _ensure_definition(self, mesg_name, mesg_num, encoded) -> int:
        # signature = the exact field layout; a change means a new definition record
        sig = bytes([mesg_num & 0xFF, mesg_num >> 8]) + b"".join(
            bytes([fn, len(raw), BASE_TYPES[bt][0]]) for fn, bt, raw in encoded
        )
        local = self._local_for.get(mesg_name)
        if local is None:
            local = self._next_local
            self._next_local += 1
            self._local_for[mesg_name] = local
        if self._def_sig.get(local) == sig:
            return local
        self._def_sig[local] = sig

        d = bytearray([0x40 | (local & 0x0F)])    # definition header
        d += bytes([0x00, 0x00])                  # reserved, architecture = little-endian
        d += struct.pack("<H", mesg_num)
        d += bytes([len(encoded)])
        for fn, bt, raw in encoded:
            d += bytes([fn, len(raw), BASE_TYPES[bt][0]])
        self._body += d
        return local
