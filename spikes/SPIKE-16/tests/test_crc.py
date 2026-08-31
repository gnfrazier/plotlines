import os
import struct

from crc import fit_crc16

CORPUS = os.path.join(os.path.dirname(__file__), "..", "..", "fit_files")


def _fit_files():
    return [os.path.join(CORPUS, f) for f in sorted(os.listdir(CORPUS)) if f.endswith(".fit")]


def test_crc16_arc_check_value():
    # CRC-16/ARC canonical check value for the ASCII string "123456789".
    assert fit_crc16(b"123456789") == 0xBB3D


def test_crc16_is_seedable_continuable():
    a, b = b"the mash tuns", b" are under the floor"
    assert fit_crc16(a + b) == fit_crc16(b, fit_crc16(a))


def test_file_crc_matches_every_reference_file():
    for path in _fit_files():
        raw = open(path, "rb").read()
        stored = struct.unpack("<H", raw[-2:])[0]
        assert fit_crc16(raw[:-2]) == stored, path


def test_header_crc_matches_every_reference_file():
    for path in _fit_files():
        raw = open(path, "rb").read()
        if raw[0] < 14:
            continue
        stored = struct.unpack("<H", raw[12:14])[0]
        if stored == 0:                      # some writers leave it zero — allowed
            continue
        assert fit_crc16(raw[:12]) == stored, path


def test_reference_corpus_is_present():
    # if this ever fails the CRC cross-check has silently lost its teeth
    assert len(_fit_files()) >= 8
