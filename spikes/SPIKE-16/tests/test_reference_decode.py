"""The decoder must handle real Garmin files, not just our own output — that is
what makes the round-trip test meaningful."""

import os

from fitdec import decode

CORPUS = os.path.join(os.path.dirname(__file__), "..", "..", "fit_files")


def _fit_files():
    return [os.path.join(CORPUS, f) for f in sorted(os.listdir(CORPUS)) if f.endswith(".fit")]


def test_every_reference_file_decodes_with_valid_crcs():
    for path in _fit_files():
        dec = decode(open(path, "rb").read())
        assert dec.file_crc_ok, path
        assert dec.header_crc_ok in (True, None), path
        assert dec.messages, path


def test_reference_files_contain_the_message_types_the_writer_uses():
    seen = set()
    for path in _fit_files():
        seen |= {m.num for m in decode(open(path, "rb").read()).messages}
    # record(20), event(21), lap(19), file_id(0), file_creator(49) all appear
    for num in (20, 21, 19):
        assert num in seen


def test_decoder_rejects_a_truncated_file():
    raw = open(_fit_files()[0], "rb").read()
    try:
        decode(raw[: len(raw) // 2])
    except Exception:
        return
    raise AssertionError("expected a truncated file to fail decoding")
