"""Tests for forge-conductor doctor / install CLI."""

from __future__ import annotations

import io

from forge_conductor.cli import doctor, install
from forge_conductor.config import ensure_home


def test_doctor_fails_on_corrupt_config(forge_home):
    ensure_home()
    (forge_home / "config.toml").write_text("[[[not valid", encoding="utf-8")
    buf = io.StringIO()
    code = doctor(stream=buf)
    assert code != 0
    out = buf.getvalue()
    assert "FAIL" in out or "corrupt" in out.lower() or "config" in out.lower()


def test_doctor_passes_on_clean_home(forge_home):
    ensure_home()
    buf = io.StringIO()
    code = doctor(stream=buf)
    assert code == 0
    out = buf.getvalue()
    assert "PASS" in out or "[ok]" in out


def test_install_creates_home_and_store(forge_home):
    # forge_home fixture creates empty dir; install should fill layout
    code = install()
    assert code == 0
    assert (forge_home / "config.toml").is_file()
    assert (forge_home / "agents").is_dir()
    assert (forge_home / "store.sqlite").is_file() or (forge_home / "store.sqlite").exists()
