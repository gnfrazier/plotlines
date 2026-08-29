from authcheck import (
    AuthGrade,
    AuthRecords,
    dkim_selector_present,
    grade,
    notes,
    parse_dmarc,
    parse_spf,
)


def test_parse_spf_hardfail():
    r = parse_spf('"v=spf1 include:spf.mtasv.net -all"')
    assert r.present
    assert r.all_qualifier == "-"
    assert "include:spf.mtasv.net" in r.mechanisms


def test_parse_spf_softfail_and_bare_all():
    assert parse_spf("v=spf1 mx ~all").all_qualifier == "~"
    assert parse_spf("v=spf1 mx all").all_qualifier == "+"


def test_parse_spf_absent():
    assert not parse_spf("some unrelated TXT record").present


def test_parse_dmarc_full():
    r = parse_dmarc("v=DMARC1;p=reject;pct=100;rua=mailto:dmarc@plotlines.app;adkim=s;aspf=s")
    assert r.present
    assert r.policy == "reject"
    assert r.pct == 100
    assert r.rua == ["mailto:dmarc@plotlines.app"]
    assert r.adkim == "s"
    assert r.has_teeth


def test_parse_dmarc_monitoring_only_has_no_teeth():
    r = parse_dmarc("v=DMARC1; p=none; rua=mailto:d@plotlines.app")
    assert r.present
    assert not r.has_teeth


def test_parse_dmarc_partial_pct_is_not_full_enforcement():
    r = parse_dmarc("v=DMARC1; p=quarantine; pct=10")
    assert not r.has_teeth  # only 10% of failing mail is quarantined


def test_dkim_selector_present():
    assert dkim_selector_present("v=DKIM1; k=rsa; p=MIIBIjANBgkq...")
    assert not dkim_selector_present("v=DKIM1; k=rsa; p=")  # revoked / empty key
    assert not dkim_selector_present("not a dkim record")


def _records(spf, dmarc, dkim=True):
    return AuthRecords(
        domain="auth.plotlines.app",
        spf=parse_spf(spf),
        dmarc=parse_dmarc(dmarc),
        dkim_selectors={"pm": dkim},
    )


def test_grade_standard():
    r = _records("v=spf1 include:x ~all", "v=DMARC1; p=quarantine; pct=100; rua=mailto:d@x")
    assert grade(r) is AuthGrade.STANDARD


def test_grade_weak_when_dmarc_is_p_none():
    r = _records("v=spf1 include:x -all", "v=DMARC1; p=none")
    assert grade(r) is AuthGrade.WEAK


def test_grade_weak_when_spf_is_neutral():
    r = _records("v=spf1 include:x ?all", "v=DMARC1; p=reject; pct=100")
    assert grade(r) is AuthGrade.WEAK


def test_grade_missing_when_no_dkim():
    r = _records("v=spf1 include:x -all", "v=DMARC1; p=reject", dkim=False)
    assert grade(r) is AuthGrade.MISSING


def test_grade_missing_when_no_dmarc():
    r = _records("v=spf1 include:x -all", "")
    assert grade(r) is AuthGrade.MISSING


def test_notes_flag_p_none_and_missing_rua():
    r = _records("v=spf1 include:x ~all", "v=DMARC1; p=none")
    text = " ".join(notes(r))
    assert "p=none" in text
    assert "rua" in text
