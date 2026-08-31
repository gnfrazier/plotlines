import struct

from crc import fit_crc16
from fitdec import decode
from fitenc import FitEncoder
from profile import fit_time, semicircles


def _minimal_course():
    enc = FitEncoder()
    enc.write("file_id", {0: 6, 1: 255, 4: fit_time(1_726_000_000)})
    enc.write("course", {4: 2, 5: "Test"})
    enc.write("record", {253: fit_time(1_726_000_000), 0: semicircles(35.5), 1: semicircles(-82.5)})
    return enc.getvalue()


def test_output_has_fit_signature_and_14_byte_header():
    data = _minimal_course()
    assert data[0] == 14
    assert data[8:12] == b".FIT"


def test_header_and_file_crc_are_valid():
    data = _minimal_course()
    assert fit_crc16(data[:12]) == struct.unpack("<H", data[12:14])[0]
    assert fit_crc16(data[:-2]) == struct.unpack("<H", data[-2:])[0]


def test_declared_data_size_matches_actual():
    data = _minimal_course()
    assert struct.unpack("<I", data[4:8])[0] == len(data) - 14 - 2


def test_decode_reencode_is_byte_identical_fields():
    data = _minimal_course()
    dec = decode(data)
    fid = dec.of("file_id")[0]
    assert fid.get(0) == 6 and fid.get(1) == 255
    rec = dec.of("record")[0]
    assert abs(rec.get(0) - semicircles(35.5)) == 0
    assert abs(rec.get(1) - semicircles(-82.5)) == 0


def test_none_valued_fields_are_omitted_not_written_as_invalid():
    enc = FitEncoder()
    enc.write("record", {253: 1, 0: semicircles(1.0), 1: None, 2: None})
    dec = decode(enc.getvalue())
    rec = dec.of("record")[0]
    assert set(rec.fields) == {253, 0}


def test_definition_is_reused_when_layout_is_stable():
    enc = FitEncoder()
    for _ in range(5):
        enc.write("record", {253: 1, 0: 2, 1: 3})
    dec = decode(enc.getvalue())
    assert len(dec.of("record")) == 5


def test_definition_is_reissued_when_field_set_changes():
    enc = FitEncoder()
    enc.write("record", {253: 1, 0: 2})
    enc.write("record", {253: 1, 0: 2, 2: 3000})  # altitude appears -> new definition
    dec = decode(enc.getvalue())
    recs = dec.of("record")
    assert recs[0].get(2) is None and recs[1].get(2) == 3000
