"""Tests for host-driven agent catalog and session ledger."""

from forge_conductor.agents_loader import load_agents
from forge_conductor.config import ensure_home
from forge_conductor.store import connect, migrate
from forge_conductor.tools import agents as agent_tools


def test_load_builtins(forge_home):
    ensure_home()
    agents = load_agents(forge_home)
    assert "explore" in agents
    assert len(agents) >= 11
    explore = agents["explore"]
    assert explore.id == "explore"
    assert explore.display_name
    assert explore.description
    assert isinstance(explore.tools, list)
    assert explore.body
    assert explore.source == "builtin"

    required = {
        "explore",
        "implement",
        "review",
        "debug",
        "test",
        "docs",
        "plan",
        "security",
        "refactor",
        "release",
        "research",
    }
    assert required <= set(agents)


def test_custom_replaces_builtin(forge_home):
    ensure_home()
    custom = """\
---
id: explore
display_name: Custom Explore
description: Fully replaced explore agent.
tools: [fs_list]
---

# Custom Explore

Custom body for explore.
"""
    (forge_home / "agents" / "explore.md").write_text(custom, encoding="utf-8")
    agents = load_agents(forge_home)
    explore = agents["explore"]
    assert explore.display_name == "Custom Explore"
    assert explore.description == "Fully replaced explore agent."
    assert explore.tools == ["fs_list"]
    assert "Custom body for explore" in explore.body
    assert explore.source == "custom"
    # Other builtins still present
    assert "implement" in agents
    assert agents["implement"].source == "builtin"


def test_session_lifecycle(forge_home):
    ensure_home()
    conn = connect()
    migrate(conn)

    started = agent_tools.svc_session_start(
        conn,
        agent_id="explore",
        client_id="client-1",
        home=forge_home,
    )
    assert started["ok"] is True
    session = started["session"]
    assert session["agent_id"] == "explore"
    assert session["status"] == "open"
    assert session["id"]
    session_id = session["id"]
    assert started["agent"]["id"] == "explore"
    assert started["agent"]["body"]

    listed = agent_tools.svc_session_list(conn)
    assert any(s["id"] == session_id for s in listed)

    ended = agent_tools.svc_session_end(
        conn,
        session_id=session_id,
        summary="Mapped the codebase entry points.",
    )
    assert ended["ok"] is True
    assert ended["session"]["id"] == session_id
    assert ended["session"]["status"] == "closed"
    assert ended["session"]["summary"] == "Mapped the codebase entry points."

    listed_after = agent_tools.svc_session_list(conn)
    row = next(s for s in listed_after if s["id"] == session_id)
    assert row["status"] == "closed"
    assert row["summary"] == "Mapped the codebase entry points."


def test_agent_list_get_context(forge_home):
    ensure_home()
    agents = agent_tools.svc_list(forge_home)
    assert any(a["id"] == "explore" for a in agents)

    got = agent_tools.svc_get(forge_home, "explore")
    assert got is not None
    assert got["id"] == "explore"
    assert "body" in got

    ctx = agent_tools.svc_context(forge_home, "explore")
    assert ctx is not None
    assert ctx["id"] == "explore"
    assert ctx["body"]
    assert "tools" in ctx
    assert "display_name" in ctx
    assert ctx.get("ok") is True


def test_agent_not_found_is_tool_error(forge_home):
    from forge_conductor.errors import ToolError

    ensure_home()
    try:
        agent_tools.svc_get(forge_home, "no-such-agent")
        raise AssertionError("expected ToolError")
    except ToolError as exc:
        assert exc.code == "agent_not_found"


def test_resolve_agent_id_aliases():
    from forge_conductor.errors import ToolError

    assert agent_tools._resolve_agent_id(None, id="explore") == "explore"
    assert agent_tools._resolve_agent_id(None, name="review") == "review"
    assert agent_tools._resolve_agent_id("debug") == "debug"
    try:
        agent_tools._resolve_agent_id(None)
        raise AssertionError("expected ToolError")
    except ToolError as exc:
        assert exc.code == "missing_agent_id"


def test_session_end_unknown_is_tool_error(forge_home):
    from forge_conductor.errors import ToolError

    ensure_home()
    conn = connect()
    migrate(conn)
    try:
        agent_tools.svc_session_end(conn, session_id="missing-session")
        raise AssertionError("expected ToolError")
    except ToolError as exc:
        assert exc.code == "session_not_found"
