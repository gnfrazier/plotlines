"""A pure-Python FIT encoder — zero dependencies, ~90 lines.

This is the artefact SPIKE-16 exists to price. The "spike candidates" note
assumed a correct FIT writer needs Dart FFI against Garmin's official SDK; this
module is the counter-evidence — the writer, in the core's own language, small
enough to read in one sitting and to hold behind the reveal gate.

What it does *not* try to be: a general FIT library. It emits the normal-header
definition/data stream a **course** file uses. One local message type is reused
per message name (a course file never needs more than a handful concurrently).

Layout produced:  [14-byte header + header CRC] [data records] [file CRC]
"""

from __future__ import annotations

import struct

from crc import fit_crc16
from profile import BASE_TYPES, FIELDS, MESG

_PROTOCOL_VERSION = 0x20   # 2.0
_PROFILE_VERSION = 21158   # SDK 21.158 — informational; devices don't gate on it


class FitEncoder:
    def __init__(self) -> None:
        self._body = bytearray()
        self._local_for: dict[str, int] = {}
        self._def_sig: dict[int, bytes] = {}
        self._next_local = 0

    # -- public API -------------------------------------------------
    def write(self, mesg_name: str, fields: dict[int, object]) -> None:
        """Append one data message. ``fields`` is {field_number: value}; a value
        of ``None`` is dropped (the field is simply not written, which is how FIT
        represents "absent" — cleaner than writing the invalid sentinel)."""
        mesg_num = MESG[mesg_name]
        field_defs = FIELDS[mesg_name]
        present = [(fn, v) for fn, v in fields.items() if v is not None]
        present.sort()

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
        data_size = len(self._body)
        header = bytearray()
        header += struct.pack("<BBHI", 14, _PROTOCOL_VERSION, _PROFILE_VERSION, data_size)
        header += b".FIT"
        header += struct.pack("<H", fit_crc16(bytes(header)))
        out = bytes(header) + bytes(self._body)
        return out + struct.pack("<H", fit_crc16(out))

    # -- internals ------------------------------------------------
    @staticmethod
    def _encode_value(base_type: str, value) -> bytes:
        tbyte, tsize, code, invalid = BASE_TYPES[base_type]
        if base_type == "string":
            raw = value.encode("utf-8") if isinstance(value, str) else bytes(value)
            return raw + b"\x00"                  # NUL-terminated, length set in the definition
        return struct.pack("<" + code, int(value))

    def _ensure_definition(self, mesg_name, mesg_num, encoded) -> int:
        # signature = the exact field layout; if it changes we must re-emit a definition
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
