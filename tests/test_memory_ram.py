"""Tests for RAM-first memory bank + project continuity tools."""

from __future__ import annotations

import json
from pathlib import Path

from forge_conductor.config import ensure_home
from forge_conductor.memory_ram import (
    KEY_ACTIVE_PROJECT,
    KEY_CONTINUITY_LATEST,
    RamMemoryBank,
    continuity_snapshot,
    ensure_bank,
    set_bank,
)
from forge_conductor.store import connect, migrate
from forge_conductor.tools import memory as mem


def test_ram_bank_load_set_search_delete_and_json_backup(forge_home: Path):
    ensure_home()
    conn = connect()
    migrate(conn)
    bank = RamMemoryBank()
    stats = bank.attach(conn, forge_home)
    assert stats["ok"] is True
    assert stats["note_count"] == 0

    row = bank.set("alpha", "hello world", tags=["t1", "project"])
    assert row["key"] == "alpha"
    assert bank.get("alpha")["body"] == "hello world"
    assert any(h["key"] == "alpha" for h in bank.search("hello"))
    assert any(h["key"] == "alpha" for h in bank.list_prefix("al"))

    # SQLite write-through
    disk = conn.execute(
        "SELECT body FROM memory_notes WHERE key=?", ("alpha",)
    ).fetchone()
    assert disk is not None
    assert disk["body"] == "hello world"

    # JSON backup exists
    backup = forge_home / "memory_corpus.json"
    assert backup.is_file()
    payload = json.loads(backup.read_text(encoding="utf-8"))
    assert payload["note_count"] == 1
    assert payload["notes"][0]["key"] == "alpha"

    assert bank.delete("alpha") is True
    assert bank.get("alpha") is None
    assert conn.execute(
        "SELECT COUNT(*) AS c FROM memory_notes WHERE key=?", ("alpha",)
    ).fetchone()["c"] == 0


def test_svc_layer_uses_ram_and_audits(forge_home: Path):
    ensure_home()
    conn = connect()
    migrate(conn)
    set_bank(None)
    ensure_bank(conn, forge_home)

    mem.svc_set(conn, key="k1", body="body", tags=["t"], client_id="c1")
    assert mem.svc_get(conn, "k1")["body"] == "body"
    assert mem.svc_search(conn, "body")
    assert mem.svc_delete(conn, "k1", client_id="c1") is True


def test_project_focus_and_handoff(forge_home: Path):
    ensure_home()
    conn = connect()
    migrate(conn)
    set_bank(None)
    bank = ensure_bank(conn, forge_home)

    focused = mem.svc_project_focus(
        conn,
        name="DemoApp",
        path=r"C:\repos\demo-app",
        summary="Demo application",
        notes="sample notes",
        client_id="test",
    )
    assert focused["ok"] is True
    assert focused["slug"] == "demoapp"
    assert bank.get(KEY_ACTIVE_PROJECT) is not None
    assert bank.get("project/demoapp") is not None

    hand = mem.svc_handoff_save(
        conn,
        summary="Auditing demo-app structure",
        next_steps="Implement continuity memory; resume explore agent",
        working_files=r"C:\repos\demo-app\README.md",
        blockers="",
        project="DemoApp",
        client_id="test",
    )
    assert hand["ok"] is True
    loaded = mem.svc_handoff_load(conn)
    assert loaded is not None
    assert loaded["key"] == KEY_CONTINUITY_LATEST
    body = json.loads(loaded["body"])
    assert "Auditing demo-app" in body["summary"]

    snap = continuity_snapshot(bank)
    assert snap["active_project"] is not None
    assert snap["handoff"] is not None
    assert any(p["key"] == "project/ywe" for p in snap["project_cards"])


def test_stale_gen_reloads_from_sqlite(forge_home: Path):
    ensure_home()
    conn = connect()
    migrate(conn)
    set_bank(None)
    bank = ensure_bank(conn, forge_home)
    bank.set("local", "from-ram")

    # Simulate another process writing directly to SQLite
    from forge_conductor import store

    store.memory_set(conn, key="other-proc", body="from-disk", tags=["x"])
    # Next read should detect generation change and reload
    assert bank.get("other-proc") is not None
    assert bank.get("other-proc")["body"] == "from-disk"
