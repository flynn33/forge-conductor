"""Tool resilience middleware + agent recover helpers."""
from __future__ import annotations

import pytest
from forge_conductor.errors import ToolError
from forge_conductor.tool_resilience import (
    ToolCircuit,
    _is_retryable,
    prune_stale_agent_sessions,
    recover_agent_session,
)
from forge_conductor.store import connect, migrate, agent_session_start, agent_session_list


def test_circuit_opens_and_resets():
    c = ToolCircuit(fail_threshold=2, cooldown_sec=0.05)
    assert c.allow("x")
    assert not c.record_failure("x")
    assert c.record_failure("x")  # opens
    assert not c.allow("x")
    import time
    time.sleep(0.08)
    assert c.allow("x")


def test_retryable_classification():
    assert _is_retryable(ToolError("a", "b", retryable=True))
    assert not _is_retryable(ToolError("a", "b", retryable=False))
    assert _is_retryable(TimeoutError("t"))
    assert not _is_retryable(FileNotFoundError("f"))


def test_agent_recover_and_prune(tmp_path, monkeypatch):
    monkeypatch.setenv("FORGE_CONDUCTOR_HOME", str(tmp_path))
    # minimal home agents dir empty — use builtin via worktree? load_agents needs home
    (tmp_path / "agents").mkdir()
    conn = connect()
    migrate(conn)
    # start with known builtin by writing a fake agent
    (tmp_path / "agents" / "explore.md").write_text(
        "---\nid: explore\ndisplay_name: Explore\ndescription: d\ntools: []\n---\nbody\n",
        encoding="utf-8",
    )
    r = recover_agent_session(conn, agent_id="explore", client_id="c1", home=tmp_path)
    assert r.get("ok") is True
    assert r.get("session")
    # prune nothing young
    closed = prune_stale_agent_sessions(conn, max_age_sec=999999)
    assert closed == []
