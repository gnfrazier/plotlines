"""Third-party software notices — issue #267, addendum L5.

Two halves, tested together because they share one record format:
`licensing.generate` scans the running interpreter's installed distributions
and writes the `THIRD_PARTY_LICENSES` bundle at freeze time;
`licensing.software_notices` reads that same format back at runtime for the
About surface. A change to one format is a change to both, so the round trip
is the thing worth pinning, not either half in isolation.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from plotlines_core.licensing.generate import (
    _RATIONALE_BY_NAME,
    discover_distributions,
    render_bundle,
    write_bundle,
)
from plotlines_core.licensing.software_notices import (
    SoftwareNotice,
    load_software_notices,
    parse_third_party_licenses,
)


def _notice(name="widget", version="1.0", licence_id="MIT", text="some licence text"):
    return SoftwareNotice(name=name, version=version, licence_id=licence_id, text=text)


class TestRoundTrip:
    def test_a_rendered_bundle_parses_back_to_the_same_notices(self):
        notices = [
            _notice("alpha", "1.0", "MIT", "MIT licence text"),
            _notice("beta", "2.3", "BSD-3-Clause", "BSD licence text\nsecond line"),
        ]
        parsed = parse_third_party_licenses(render_bundle(notices))

        assert [n.name for n in parsed] == ["alpha", "beta"]
        assert parsed[0].version == "1.0"
        assert parsed[0].licence_id == "MIT"
        assert "MIT licence text" in parsed[0].text
        assert "second line" in parsed[1].text

    def test_a_licence_name_with_spaces_survives_the_header_quoting(self):
        notices = [_notice("pyinstaller", "6.22.3", "GNU General Public License v2 (GPLv2)")]
        parsed = parse_third_party_licenses(render_bundle(notices))

        assert parsed[0].licence_id == "GNU General Public License v2 (GPLv2)"

    def test_the_files_own_header_comment_before_the_first_record_is_discarded(self):
        raw = "Plotlines third-party software notices\nGenerated ...\n\n" + render_bundle(
            [_notice("only")]
        )
        parsed = parse_third_party_licenses(raw)
        assert len(parsed) == 1
        assert parsed[0].name == "only"

    def test_a_record_with_no_name_field_is_skipped_rather_than_raising(self):
        raw = '### NOTICE version="1.0" licence="MIT"\nsome text\n'
        assert parse_third_party_licenses(raw) == []

    def test_an_empty_bundle_parses_to_no_notices(self):
        assert parse_third_party_licenses("") == []


class TestPyInstallerRationale:
    def test_pyinstaller_carries_the_bootloader_exception_rationale(self):
        # The rationale is written explicitly ahead of PyInstaller's own
        # licence text, not left implicit in whatever COPYING.txt happens to
        # say (addendum L5, item 3).
        rationale = _RATIONALE_BY_NAME["pyinstaller"]
        notices = [_notice("pyinstaller", "6.22.3", "GPL-2.0-or-later", "the real licence text")]
        # Simulate what discover_distributions does: rationale prepended.
        notices[0] = _notice(
            "pyinstaller", "6.22.3", "GPL-2.0-or-later", rationale + "\n\n" + "the real licence text",
        )
        parsed = parse_third_party_licenses(render_bundle(notices))
        assert "bootloader" in parsed[0].text.lower()
        assert "exception" in parsed[0].text.lower()
        assert "the real licence text" in parsed[0].text

    def test_rationale_is_recorded_only_for_pyinstaller_today(self):
        # Not a blanket policy — a GPL-exception rationale is only recorded
        # where Plotlines actually relies on one. Guards against silently
        # growing this dict for every GPL-flavoured dependency without a
        # written reason.
        assert list(_RATIONALE_BY_NAME) == ["pyinstaller"]


class TestDiscoverDistributions:
    def test_finds_real_third_party_distributions_in_this_test_environment(self):
        # This test environment (core's own venv) has pytest and its
        # dependencies installed — enough to exercise the real
        # importlib.metadata path without needing a frozen build.
        notices = discover_distributions()
        names = {n.name.lower() for n in notices}
        assert "pytest" in names

    def test_excludes_plotlines_own_editable_packages(self):
        notices = discover_distributions()
        names = {n.name.lower() for n in notices}
        assert "plotlines-core" not in names
        assert "plotlines-service" not in names

    def test_every_notice_carries_a_non_empty_licence_id_and_text(self):
        for n in discover_distributions():
            assert n.licence_id.strip()
            assert n.text.strip()


class TestWriteBundle:
    def test_writes_a_non_empty_bundle_and_returns_the_package_count(self, tmp_path: Path):
        out = tmp_path / "THIRD_PARTY_LICENSES"
        count = write_bundle(out, require_pyinstaller=False)

        assert count > 0
        assert out.exists()
        assert out.stat().st_size > 0

    def test_refuses_to_write_when_no_distributions_are_found(self, tmp_path: Path, monkeypatch):
        import plotlines_core.licensing.generate as gen

        monkeypatch.setattr(gen, "discover_distributions", lambda: [])
        with pytest.raises(RuntimeError, match="no third-party distributions"):
            write_bundle(tmp_path / "THIRD_PARTY_LICENSES", require_pyinstaller=False)

    def test_requires_pyinstaller_present_unless_told_otherwise(self, tmp_path: Path, monkeypatch):
        import plotlines_core.licensing.generate as gen

        monkeypatch.setattr(gen, "discover_distributions", lambda: [_notice("not-pyinstaller")])
        with pytest.raises(RuntimeError, match="pyinstaller not found"):
            write_bundle(tmp_path / "THIRD_PARTY_LICENSES", require_pyinstaller=True)

        # Same environment, but the caller says this target doesn't embed
        # PyInstaller's bootloader (e.g. the nuitka target) — no error.
        count = write_bundle(tmp_path / "THIRD_PARTY_LICENSES", require_pyinstaller=False)
        assert count == 1


class TestLoadSoftwareNotices:
    def test_reads_a_bundle_from_an_explicit_candidate_path(self, tmp_path: Path):
        bundle = tmp_path / "THIRD_PARTY_LICENSES"
        bundle.write_text(render_bundle([_notice("alpha")]), encoding="utf-8")

        notices, found = load_software_notices([bundle])
        assert found is True
        assert [n.name for n in notices] == ["alpha"]

    def test_bundle_absent_is_reported_distinctly_from_bundle_empty(self, tmp_path: Path):
        # No candidate path exists at all — "not a frozen build", not an error.
        notices, found = load_software_notices([tmp_path / "does-not-exist"])
        assert notices == []
        assert found is False

    def test_first_readable_candidate_path_wins(self, tmp_path: Path):
        missing = tmp_path / "missing" / "THIRD_PARTY_LICENSES"
        present = tmp_path / "THIRD_PARTY_LICENSES"
        present.write_text(render_bundle([_notice("beta")]), encoding="utf-8")

        notices, found = load_software_notices([missing, present])
        assert found is True
        assert [n.name for n in notices] == ["beta"]
