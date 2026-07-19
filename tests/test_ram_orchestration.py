"""RAM orchestration layer + super agent context."""

from __future__ import annotations

import json
from pathlib import Path

from forge_conductor.agent_runtime import run_complete, run_start
from forge_conductor.agents_loader import load_agents, recommend_agent
from forge_conductor.config import ensure_home
from forge_conductor.memory_ram import ensure_bank, set_bank
from forge_conductor.ram_orchestration import (
    RamOrchestration,
    ensure_orchestration,
    set_orchestration,
)
from forge_conductor.store import connect, migrate
from forge_conductor.tools import memory as mem


def test_orch_loads_agents_and_snapshots(forge_home: Path):
    ensure_home()
    conn = connect()
    migrate(conn)
    set_bank(None)
    set_orchestration(None)
    ensure_bank(conn, forge_home)
    orch = RamOrchestration()
    stats = orch.attach(conn, forge_home)
    assert stats["loaded"] is True
    assert stats["agents"] >= 10
    assert "plan" in orch.agents
    assert "docs" in orch.agents
    snap = forge_home / "orchestration_corpus.json"
    assert snap.is_file()
    data = json.loads(snap.read_text(encoding="utf-8"))
    assert "plan" in data["agents"]
    assert data["super_policy"]["mode"] == "super_agents"


def test_super_context_and_plan_chain(forge_home: Path):
    ensure_home()
    conn = connect()
    migrate(conn)
    set_bank(None)
    set_orchestration(None)
    ensure_bank(conn, forge_home)
    mem.svc_project_focus(
        conn,
        name="DemoApp",
        path=r"C:\repos\demo-app",
        summary="Demo app",
        client_id="t",
    )
    orch = ensure_orchestration(conn, forge_home)
    sc = orch.build_super_context(
        agent_id="plan",
        goal="Write a ROADMAP.md for the project",
        cwd=r"C:\repos\demo-app",
    )
    assert sc["super_mode"] is True
    assert sc["active_project"] is not None
    assert any(s.get("agent_id") == "docs" for s in sc["suggested_chain"])


def test_recommend_roadmap_goes_docs():
    r = recommend_agent("write ROADMAP.md for the engine")
    assert r["agent_id"] == "docs"


def test_plan_forbids_fs_write(forge_home: Path):
    agents = load_agents(forge_home)
    assert "fs_write" in agents["plan"].tools_forbidden


def test_run_start_includes_super_context(forge_home: Path):
    ensure_home()
    conn = connect()
    migrate(conn)
    set_bank(None)
    set_orchestration(None)
    ensure_bank(conn, forge_home)
    ensure_orchestration(conn, forge_home)
    out = run_start(
        conn,
        agent_id="plan",
        goal="Plan a ROADMAP.md then docs will write it",
        client_id="super-test",
        home=forge_home,
    )
    assert out["super_mode"] is True
    assert out.get("super_context") is not None
    assert out.get("suggested_chain")
    done = run_complete(
        conn,
        session_id=out["session"]["id"],
        report={
            "goal": "roadmap",
            "steps": ["a"],
            "files": ["ROADMAP.md"],
            "risks": [],
            "verify": "docs writes file",
            "next_agent": "docs",
        },
        client_id="super-test",
    )
    assert done.get("next_call")
    assert "docs" in (done.get("next_call") or "")
