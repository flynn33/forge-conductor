"""Tests for automatic project focus / handoff / bootstrap inject."""

from __future__ import annotations

import json
from pathlib import Path

from forge_conductor.config import ensure_home
from forge_conductor.continuity_auto import (
    auto_handoff,
    auto_project_focus_from_path,
    bootstrap_seen,
    mark_bootstrap,
    process_tool_result,
)
from forge_conductor.memory_ram import KEY_ACTIVE_PROJECT, KEY_CONTINUITY_LATEST, ensure_bank, set_bank
from forge_conductor.store import connect, migrate


def test_auto_project_focus_from_git_path(forge_home: Path, tmp_path: Path):
    ensure_home()
    conn = connect()
    migrate(conn)
    set_bank(None)
    ensure_bank(conn, forge_home)

    repo = tmp_path / "MyBookEngine"
    (repo / ".git").mkdir(parents=True)
    (repo / "README.md").write_text("hi", encoding="utf-8")

    # Without server ctx, still works via connect()
    out = auto_project_focus_from_path(str(repo / "README.md"), reason="test")
    assert out is not None
    assert out.get("auto_project_focus", {}).get("ok") is True
    bank = ensure_bank(conn, forge_home)
    active = bank.get(KEY_ACTIVE_PROJECT)
    assert active is not None
    card = json.loads(active["body"])
    assert card["slug"] == "mybookengine"
    assert "MyBookEngine" in card["path"] or "mybookengine" in card["path"].lower()


def test_process_tool_injects_bootstrap_once(forge_home: Path):
    ensure_home()
    conn = connect()
    migrate(conn)
    set_bank(None)
    bank = ensure_bank(conn, forge_home)
    bank.set(KEY_CONTINUITY_LATEST, json.dumps({"summary": "prior work"}), tags=["handoff"])
    bank.set(
        KEY_ACTIVE_PROJECT,
        json.dumps({"name": "DemoApp", "slug": "demoapp", "path": r"C:\repos\demo-app", "summary": "x", "notes": ""}),
        tags=["project", "active"],
    )

    # reset bootstrap flag
    import forge_conductor.continuity_auto as ca

    ca._bootstrap_seen = False  # noqa: SLF001

    result = {"ok": True, "hello": 1}
    out = process_tool_result("forge_status", {}, result)
    assert isinstance(out, dict)
    fac = out.get("forge_auto_continuity")
    assert fac is not None
    assert fac.get("bootstrap") == "auto_injected"
    assert fac.get("continuity", {}).get("handoff") is not None
    assert bootstrap_seen() is True

    # second call should not re-inject bootstrap block the same way
    out2 = process_tool_result("forge_status", {}, {"ok": True})
    # may still attach minimal meta; bootstrap key should be absent or not auto_injected again
    fac2 = out2.get("forge_auto_continuity") if isinstance(out2, dict) else None
    if fac2:
        assert fac2.get("bootstrap") != "auto_injected"


def test_auto_handoff_writes_latest(forge_home: Path):
    ensure_home()
    conn = connect()
    migrate(conn)
    set_bank(None)
    ensure_bank(conn, forge_home)

    # Need runtime ctx for handoff_save client path — simulate via bank direct after note
    from forge_conductor.continuity_auto import note_tool
    from forge_conductor.server import RuntimeContext, _ctx
    import forge_conductor.server as server

    server._ctx = RuntimeContext(  # noqa: SLF001
        conn=conn,
        client_id="test-client",
        config={},
        home=forge_home,
        coordinator=None,
    )
    try:
        note_tool("fs_read", {"path": r"C:\repos\demo-app\README.md"})
        note_tool("git_status", {"cwd": r"C:\repos\demo-app"})
        out = auto_handoff(reason="test")
        assert out is not None
        assert out.get("ok") is True
        bank = ensure_bank(conn, forge_home)
        assert bank.get(KEY_CONTINUITY_LATEST) is not None
    finally:
        server._ctx = None  # noqa: SLF001
        mark_bootstrap()
