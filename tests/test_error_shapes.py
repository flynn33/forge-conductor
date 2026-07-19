"""Tests for structured ToolError payloads across tool packs."""

from __future__ import annotations

import sys
from pathlib import Path

from forge_conductor.errors import ToolError, tool_error_payload
from forge_conductor.tools import filesystem as fs
from forge_conductor.tools import research as res
from forge_conductor.tools import shell as sh


def test_tool_error_payload_shape():
    exc = ToolError(
        "example",
        "something went wrong",
        retryable=True,
        detail={"k": 1},
    )
    payload = tool_error_payload(exc)
    assert payload == {
        "code": "example",
        "message": "something went wrong",
        "retryable": True,
        "detail": {"k": 1},
    }


def test_tool_error_payload_generic_exception():
    payload = tool_error_payload(RuntimeError("boom"))
    assert payload["code"] == "error"
    assert payload["message"] == "boom"
    assert payload["retryable"] is False
    assert payload["detail"] == {}


def test_shell_timeout_structured_error(forge_home):
    result = sh.svc_exec(
        [sys.executable, "-c", "import time; time.sleep(5)"],
        timeout_sec=0.3,
    )
    assert result["timed_out"] is True
    assert result["code"] == "timeout"
    assert result["retryable"] is True
    assert "timed out" in result["message"].lower()
    assert "detail" in result


def test_fs_read_missing_file_structured_error(tmp_path: Path, forge_home):
    missing = tmp_path / "does-not-exist-xyz.txt"
    result = fs.svc_read(str(missing))
    assert result["code"] == "not_found"
    assert result["retryable"] is False
    assert "message" in result
    assert result["detail"]["path"]


def test_web_search_unconfigured_uses_tool_error_shape(forge_home, monkeypatch):
    monkeypatch.delenv("FORGE_SEARCH_API_KEY", raising=False)
    result = res.svc_web_search(
        "query",
        config={"search_provider": "none", "api_key_env": "FORGE_SEARCH_API_KEY"},
    )
    assert result["code"] == "provider_unconfigured"
    assert result["retryable"] is False
    assert isinstance(result.get("detail"), dict)
    assert "message" in result
