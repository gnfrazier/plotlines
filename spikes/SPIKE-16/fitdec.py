"""A minimal FIT reader — enough to verify what the writer produced, and to read
the real device files in `spikes/fit_files/` as a cross-check.

Not a general FIT parser. It handles the normal-header definition/data-message
stream a course file uses: no compressed timestamp headers, no developer fields
(a course export has neither). It returns messages as
``(mesg_name_or_num, {field_num: raw_value})`` so a test can assert on exact
stored bytes, which is the level SPIKE-16 and punch-list §6A.2 care about.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

from crc import fit_crc16
from profile import BASE_TYPE_BY_BYTE, BASE_TYPES, MESG

_MESG_NAME = {v: k for k, v in MESG.items()}


@dataclass
class DecodedMessage:
    name: str          # profile name if known, else "mesg_<num>"
    num: int
    fields: dict       # field_def_num -> python value (str for strings, int otherwise)

    def get(self, field_num, default=None):
        return self.fields.get(field_num, default)


@dataclass
class DecodedFile:
    header_size: int
    protocol_version: int
    profile_version: int
    data_size: int
    header_crc_ok: bool | None
    file_crc_ok: bool
    messages: list

    def of(self, name):
        return [m for m in self.messages if m.name == name]


def _read_value(buf, base_type, size):
    tbyte, tsize, code, invalid = BASE_TYPES[base_type]
    if base_type == "string":
        raw = buf[:size]
        nul = raw.find(0)
        return raw[: nul if nul >= 0 else size].decode("utf-8", "replace")
    count = size // tsize
    vals = struct.unpack("<" + code * count, buf[:size])
    if count == 1:
        v = vals[0]
        return None if v == invalid else v
    return list(vals)


def decode(data: bytes) -> DecodedFile:
    header_size = data[0]
    protocol_version = data[1]
    profile_version = struct.unpack("<H", data[2:4])[0]
    data_size = struct.unpack("<I", data[4:8])[0]
    assert data[8:12] == b".FIT", "not a FIT file (missing .FIT signature)"

    header_crc_ok = None
    if header_size >= 14:
        stored = struct.unpack("<H", data[12:14])[0]
        header_crc_ok = stored == 0 or stored == fit_crc16(data[:12])

    file_crc_stored = struct.unpack("<H", data[-2:])[0]
    file_crc_ok = file_crc_stored == fit_crc16(data[:-2])

    body = data[header_size : header_size + data_size]
    pos = 0
    defs: dict[int, tuple] = {}          # local_type -> (mesg_num, [(fnum, size, base_type)])
    messages: list[DecodedMessage] = []

    while pos < len(body):
        rec_header = body[pos]
        pos += 1
        if rec_header & 0x80:
            raise ValueError("compressed-timestamp header not supported (not used by course files)")
        local_type = rec_header & 0x0F
        is_def = bool(rec_header & 0x40)
        has_dev = bool(rec_header & 0x20)

        if is_def:
            _reserved = body[pos]
            arch = body[pos + 1]
            endian = "<" if arch == 0 else ">"
            mesg_num = struct.unpack(endian + "H", body[pos + 2 : pos + 4])[0]
            nfields = body[pos + 4]
            pos += 5
            fields = []
            for _ in range(nfields):
                fnum, fsize, ftype_byte = body[pos], body[pos + 1], body[pos + 2]
                pos += 3
                fields.append((fnum, fsize, BASE_TYPE_BY_BYTE.get(ftype_byte, "byte")))
            if has_dev:
                ndev = body[pos]
                pos += 1 + 3 * ndev  # skip developer field declarations
            defs[local_type] = (mesg_num, fields)
        else:
            mesg_num, fields = defs[local_type]
            parsed = {}
            for fnum, fsize, base_type in fields:
                parsed[fnum] = _read_value(body[pos : pos + fsize], base_type, fsize)
                pos += fsize
            messages.append(
                DecodedMessage(_MESG_NAME.get(mesg_num, f"mesg_{mesg_num}"), mesg_num, parsed)
            )

    return DecodedFile(
        header_size, protocol_version, profile_version, data_size,
        header_crc_ok, file_crc_ok, messages,
    )
