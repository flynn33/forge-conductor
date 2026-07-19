"""Tests for agent_backend mode, host blocks, and job enqueue."""

from __future__ import annotations

import json
from pathlib import Path

import pytest


def test_load_save_mode(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("FORGE_CONDUCTOR_HOME", str(tmp_path))
    from forge_conductor.agent_backend import get_mode, load_state, set_mode

    assert get_mode() == "host"
    st = set_mode("grok", changed_by="test", notify=False)
    assert st["mode"] == "grok"
    assert int(st["generation"]) >= 1
    assert get_mode() == "grok"
    st2 = set_mode("host", changed_by="test", notify=False)
    assert st2["mode"] == "host"


def test_host_tool_block_in_grok(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("FORGE_CONDUCTOR_HOME", str(tmp_path))
    monkeypatch.delenv("FORGE_AGENT_EXECUTOR", raising=False)
    from forge_conductor.agent_backend import host_tool_allowed, set_mode

    set_mode("grok", notify=False)
    ok, msg = host_tool_allowed("fs_write")
    assert ok is False
    assert msg and "agent_run_start" in msg

    ok2, _ = host_tool_allowed("session_bootstrap")
    assert ok2 is True

    ok3, _ = host_tool_allowed("agent_run_start")
    assert ok3 is True

    ok4, _ = host_tool_allowed("memory_set")
    assert ok4 is True

    set_mode("host", notify=False)
    ok5, _ = host_tool_allowed("fs_write")
    assert ok5 is True


def test_executor_env_bypasses_block(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("FORGE_CONDUCTOR_HOME", str(tmp_path))
    monkeypatch.setenv("FORGE_AGENT_EXECUTOR", "grok")
    from forge_conductor.agent_backend import host_tool_allowed, set_mode

    set_mode("grok", notify=False)
    ok, _ = host_tool_allowed("fs_write")
    assert ok is True


def test_policy_banner_grok(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("FORGE_CONDUCTOR_HOME", str(tmp_path))
    from forge_conductor.agent_backend import policy_banner, set_mode

    set_mode("grok", notify=False)
    b = policy_banner()
    assert b["policy"] == "MANDATORY_OFFLOAD"
    assert b["mode"] == "grok"


def test_enqueue_and_claim(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("FORGE_CONDUCTOR_HOME", str(tmp_path))
    from forge_conductor.config import ensure_home
    from forge_conductor.store import connect, migrate
    from forge_conductor.agent_jobs import claim_next_job, complete_job, enqueue_agent_job

    ensure_home()
    conn = connect()
    migrate(conn)
    job = enqueue_agent_job(
        conn,
        session_id="sess-1",
        agent_id="explore",
        goal="map repo",
        payload={"super_context": {}},
    )
    assert job["status"] == "queued"
    claimed = claim_next_job(conn)
    assert claimed is not None
    assert claimed["id"] == job["id"]
    assert claimed["status"] == "running"
    complete_job(conn, job["id"], status="completed", result={"ok": True})
    claimed2 = claim_next_job(conn)
    assert claimed2 is None


def test_run_start_dispatches_grok(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("FORGE_CONDUCTOR_HOME", str(tmp_path))
    from forge_conductor.agent_backend import set_mode
    from forge_conductor.agent_runtime import run_start
    from forge_conductor.config import ensure_home
    from forge_conductor.store import connect, migrate

    ensure_home()
    # minimal agents dir uses builtins from package
    set_mode("grok", notify=False)
    conn = connect()
    migrate(conn)
    out = run_start(conn, agent_id="explore", goal="scan tree", client_id="test-client")
    assert out.get("executor") == "grok"
    assert out.get("host_must_not_execute_playbook") is True
    assert out.get("session_id") or (out.get("session") or {}).get("id")
    assert out.get("job") is not None
