"""Agent playbooks, run lifecycle, recommend, soft preference."""

from __future__ import annotations

import pytest

from forge_conductor.agent_runtime import (
    get_active,
    run_complete,
    run_start,
    soft_tool_preference,
)
from forge_conductor.agents_loader import load_agents, parse_agent_markdown, recommend_agent
from forge_conductor.store import connect, migrate


def test_playbook_defaults_on_builtin(tmp_path, monkeypatch):
    monkeypatch.setenv("FORGE_CONDUCTOR_HOME", str(tmp_path))
    (tmp_path / "agents").mkdir()
    agents = load_agents(tmp_path)
    assert "explore" in agents
    ex = agents["explore"]
    assert ex.first_moves
    assert "fs_write" in ex.tools_forbidden
    card = ex.card()
    assert card["id"] == "explore"
    assert "when_to_use" in card


def test_frontmatter_override_playbook():
    text = """---
id: explore
display_name: Explore
description: d
tools: [fs_read]
when_to_use: [custom when]
first_moves: [custom move]
tools_forbidden: [fs_delete]
---
body here
"""
    spec = parse_agent_markdown(text, source="custom")
    assert spec.when_to_use == ["custom when"]
    assert spec.first_moves == ["custom move"]
    assert spec.tools_forbidden == ["fs_delete"]


def test_recommend_agent():
    r = recommend_agent("map this unfamiliar codebase")
    assert r["ok"] is True
    assert r["agent_id"] == "explore"
    r2 = recommend_agent("fix a bug in the auth code")
    assert r2["agent_id"] in ("implement", "debug", "security")


def test_run_start_complete_and_soft_preference(tmp_path, monkeypatch):
    monkeypatch.setenv("FORGE_CONDUCTOR_HOME", str(tmp_path))
    (tmp_path / "agents").mkdir()
    conn = connect(str(tmp_path / "store.sqlite"))
    migrate(conn)
    client = "test-client"
    out = run_start(
        conn,
        agent_id="explore",
        goal="Map the repo",
        client_id=client,
        home=tmp_path,
    )
    assert out["ok"] is True
    sid = out["session"]["id"]
    assert get_active(client) is not None
    assert get_active(client).agent_id == "explore"

    warn = soft_tool_preference("fs_write", client)
    assert warn is not None
    assert warn["severity"] == "warn"

    ok_tool = soft_tool_preference("fs_read", client)
    # fs_read is primary for explore — no forbidden warn
    assert ok_tool is None or ok_tool.get("severity") != "warn"

    done = run_complete(
        conn,
        session_id=sid,
        report={
            "layout": "ok",
            "entry_points": "ok",
            "build_test_run": "unknown",
            "dependencies_config": "n/a",
            "risks": "none",
            "next_agent": "plan",
        },
        client_id=client,
    )
    assert done["ok"] is True
    assert done["schema_complete"] is True
    assert get_active(client) is None
