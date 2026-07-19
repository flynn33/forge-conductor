"""Tests for shell tool pack."""

from __future__ import annotations

import sys

from forge_conductor.tools import shell as sh


def test_shell_exec_echo(forge_home):
    # Prefer list argv for portability; echo works via shell on Windows/Unix
    if sys.platform == "win32":
        result = sh.svc_exec("echo hello")
    else:
        result = sh.svc_exec(["echo", "hello"])
    assert result["timed_out"] is False
    assert result["exit_code"] == 0
    assert "hello" in (result["stdout"] or "")


def test_shell_exec_list_python(forge_home):
    result = sh.svc_exec([sys.executable, "-c", "print('py-ok')"])
    assert result["exit_code"] == 0
    assert "py-ok" in result["stdout"]


def test_shell_exec_timeout(forge_home):
    # Sleep longer than timeout
    if sys.platform == "win32":
        # powershell Start-Sleep is available; use python for portability
        result = sh.svc_exec(
            [sys.executable, "-c", "import time; time.sleep(5)"],
            timeout_sec=0.3,
        )
    else:
        result = sh.svc_exec([sys.executable, "-c", "import time; time.sleep(5)"], timeout_sec=0.3)
    assert result["timed_out"] is True
    assert result.get("error")
    assert "timed out" in result["error"].lower()


def test_shell_which_finds_python_or_cmd(forge_home):
    py = sh.svc_which("python")
    cmd = sh.svc_which("cmd") if sys.platform == "win32" else sh.svc_which("sh")
    # At least one of python or platform shell should resolve
    assert py["found"] or cmd["found"]
    if py["found"]:
        assert py["path"]
    missing = sh.svc_which("definitely-not-a-binary-xyz-12345")
    assert missing["found"] is False
    assert missing["path"] is None


def test_shell_env_get(forge_home, monkeypatch):
    monkeypatch.setenv("FORGE_SHELL_TEST_VAR", "forge-value")
    got = sh.svc_env_get("FORGE_SHELL_TEST_VAR")
    assert got["found"] is True
    assert got["value"] == "forge-value"

    missing = sh.svc_env_get("FORGE_SHELL_TEST_VAR_MISSING_XYZ")
    assert missing["found"] is False
    assert missing["value"] is None
