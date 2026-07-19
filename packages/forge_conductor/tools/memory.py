"""Memory tools: RAM-first corpus + project continuity + FastMCP registration."""

from __future__ import annotations

import json
import re
import sqlite3
from typing import Any

from forge_conductor import audit
from forge_conductor import store
from forge_conductor.memory_ram import (
    KEY_ACTIVE_PROJECT,
    KEY_CONTINUITY_LATEST,
    RamMemoryBank,
    continuity_snapshot,
    ensure_bank,
    get_bank,
)


def _bank(conn: sqlite3.Connection | None = None) -> RamMemoryBank:
    """Return attached RAM bank; attach from runtime ctx/home if needed."""
    bank = get_bank()
    if bank is not None and bank.stats().get("loaded"):
        return bank
    from forge_conductor.config import get_home
    from forge_conductor.server import get_ctx

    ctx = get_ctx()
    c = conn
    if c is None:
        c = ctx.conn if ctx is not None else store.connect()
        if ctx is None:
            store.migrate(c)
    home = ctx.home if ctx is not None else get_home()
    return ensure_bank(c, home)


def svc_set(
    conn: sqlite3.Connection,
    key: str,
    body: str,
    tags: list[str] | None = None,
    *,
    client_id: str | None = None,
) -> dict[str, Any]:
    """Insert or update a memory note in RAM + disk; audit when client_id set."""
    row = _bank(conn).set(key=key, body=body, tags=tags)
    if client_id is not None:
        audit.append(
            conn,
            tool="memory_set",
            args={"key": key, "body": body, "tags": list(tags) if tags is not None else []},
            status="ok",
            client_id=client_id,
            mutating=True,
        )
    return row


def svc_get(conn: sqlite3.Connection, key: str) -> dict[str, Any] | None:
    """Return a memory note by key from RAM, or None if missing."""
    return _bank(conn).get(key)


def svc_list(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    """List all memory notes from RAM ordered by key."""
    return _bank(conn).list()


def svc_delete(
    conn: sqlite3.Connection,
    key: str,
    *,
    client_id: str | None = None,
) -> bool:
    """Delete a memory note from RAM + disk; audit when client_id set."""
    deleted = _bank(conn).delete(key)
    if client_id is not None:
        audit.append(
            conn,
            tool="memory_delete",
            args={"key": key, "deleted": deleted},
            status="ok",
            client_id=client_id,
            mutating=True,
        )
    return deleted


def svc_search(conn: sqlite3.Connection, query: str) -> list[dict[str, Any]]:
    """Search memory notes in RAM by key/body/tags substring."""
    return _bank(conn).search(query)


def _slugify(name: str) -> str:
    s = (name or "").strip().lower()
    s = re.sub(r"[^a-z0-9]+", "-", s)
    s = s.strip("-")
    return s or "unnamed"


def svc_project_focus(
    conn: sqlite3.Connection,
    *,
    name: str,
    path: str = "",
    summary: str = "",
    notes: str = "",
    client_id: str | None = None,
) -> dict[str, Any]:
    """Set active project card + project/active pointer."""
    slug = _slugify(name)
    card = {
        "name": name.strip(),
        "slug": slug,
        "path": path.strip(),
        "summary": summary.strip(),
        "notes": notes.strip(),
    }
    body = json.dumps(card, ensure_ascii=False, indent=2)
    tags = ["project", "continuity", slug]
    card_row = svc_set(
        conn,
        key=f"project/{slug}",
        body=body,
        tags=tags,
        client_id=client_id,
    )
    active_row = svc_set(
        conn,
        key=KEY_ACTIVE_PROJECT,
        body=body,
        tags=["project", "active", "continuity", slug],
        client_id=client_id,
    )
    return {"ok": True, "slug": slug, "project": card, "card": card_row, "active": active_row}


def svc_project_current(conn: sqlite3.Connection) -> dict[str, Any]:
    """Return active project + continuity snapshot from RAM."""
    bank = _bank(conn)
    snap = continuity_snapshot(bank)
    return {"ok": True, **snap}


def svc_handoff_save(
    conn: sqlite3.Connection,
    *,
    summary: str,
    next_steps: str,
    blockers: str = "",
    working_files: str = "",
    project: str = "",
    extra: str = "",
    client_id: str | None = None,
) -> dict[str, Any]:
    """Persist a cross-chat handoff for the next session_bootstrap."""
    bank = _bank(conn)
    active = bank.get(KEY_ACTIVE_PROJECT)
    project_name = (project or "").strip()
    if not project_name and active:
        try:
            project_name = json.loads(active["body"]).get("name") or ""
        except (json.JSONDecodeError, TypeError, AttributeError):
            project_name = ""

    from datetime import datetime, timezone

    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    payload = {
        "saved_at": now,
        "project": project_name,
        "summary": (summary or "").strip(),
        "next_steps": (next_steps or "").strip(),
        "blockers": (blockers or "").strip(),
        "working_files": (working_files or "").strip(),
        "extra": (extra or "").strip(),
        "active_project_body": active.get("body") if active else None,
    }
    body = json.dumps(payload, ensure_ascii=False, indent=2)
    tags = ["continuity", "handoff"]
    if project_name:
        tags.append(_slugify(project_name))

    latest = svc_set(
        conn,
        key=KEY_CONTINUITY_LATEST,
        body=body,
        tags=tags,
        client_id=client_id,
    )
    # Archive copy (does not bloat bootstrap; searchable)
    archive_key = f"continuity/history/{now.replace(':', '').replace('-', '')}"
    archived = svc_set(
        conn,
        key=archive_key,
        body=body,
        tags=tags + ["history"],
        client_id=client_id,
    )
    return {"ok": True, "handoff": latest, "archive_key": archive_key, "archived": archived}


def svc_handoff_load(conn: sqlite3.Connection) -> dict[str, Any] | None:
    """Load latest continuity handoff from RAM."""
    return _bank(conn).get(KEY_CONTINUITY_LATEST)


def svc_memory_stats(conn: sqlite3.Connection) -> dict[str, Any]:
    """RAM corpus stats + backup paths."""
    bank = _bank(conn)
    return {"ok": True, **bank.stats()}


def svc_memory_flush(conn: sqlite3.Connection) -> dict[str, Any]:
    """Force JSON corpus backup to disk."""
    return _bank(conn).flush_backup()


def register(mcp: Any) -> None:
    """Register memory + project continuity tools on *mcp*."""
    from forge_conductor.server import TOOL_NAMES, get_ctx

    @mcp.tool
    def memory_set(key: str, body: str, tags: list[str] | None = None) -> dict[str, Any]:
        """Insert/update a shared RAM memory note (write-through to disk backup)."""
        ctx = get_ctx()
        if ctx is None:
            raise RuntimeError("Runtime context not initialized")
        return svc_set(
            ctx.conn,
            key=key,
            body=body,
            tags=tags,
            client_id=ctx.client_id,
        )

    @mcp.tool
    def memory_get(key: str) -> dict[str, Any] | None:
        """Get a memory note by key from the RAM corpus."""
        ctx = get_ctx()
        if ctx is None:
            raise RuntimeError("Runtime context not initialized")
        return svc_get(ctx.conn, key)

    @mcp.tool
    def memory_list() -> list[dict[str, Any]]:
        """List all memory notes currently loaded in RAM."""
        ctx = get_ctx()
        if ctx is None:
            raise RuntimeError("Runtime context not initialized")
        return svc_list(ctx.conn)

    @mcp.tool
    def memory_delete(key: str) -> bool:
        """Delete a memory note from RAM and disk backup."""
        ctx = get_ctx()
        if ctx is None:
            raise RuntimeError("Runtime context not initialized")
        return svc_delete(ctx.conn, key, client_id=ctx.client_id)

    @mcp.tool
    def memory_search(query: str) -> list[dict[str, Any]]:
        """Search RAM memory notes by key, body, or tags substring."""
        ctx = get_ctx()
        if ctx is None:
            raise RuntimeError("Runtime context not initialized")
        return svc_search(ctx.conn, query)

    @mcp.tool
    def memory_stats() -> dict[str, Any]:
        """RAM memory corpus stats (count, bytes, load_ms, backup path)."""
        ctx = get_ctx()
        if ctx is None:
            raise RuntimeError("Runtime context not initialized")
        return svc_memory_stats(ctx.conn)

    @mcp.tool
    def memory_flush() -> dict[str, Any]:
        """Force full JSON memory corpus backup to disk now."""
        ctx = get_ctx()
        if ctx is None:
            raise RuntimeError("Runtime context not initialized")
        return svc_memory_flush(ctx.conn)

    @mcp.tool
    def project_focus(
        name: str,
        path: str = "",
        summary: str = "",
        notes: str = "",
    ) -> dict[str, Any]:
        """Set the active project for cross-chat continuity (project/active + project/{slug})."""
        ctx = get_ctx()
        if ctx is None:
            raise RuntimeError("Runtime context not initialized")
        return svc_project_focus(
            ctx.conn,
            name=name,
            path=path,
            summary=summary,
            notes=notes,
            client_id=ctx.client_id,
        )

    @mcp.tool
    def project_current() -> dict[str, Any]:
        """Return active project, latest handoff, project cards, recent notes (from RAM)."""
        ctx = get_ctx()
        if ctx is None:
            raise RuntimeError("Runtime context not initialized")
        return svc_project_current(ctx.conn)

    @mcp.tool
    def handoff_save(
        summary: str,
        next_steps: str,
        blockers: str = "",
        working_files: str = "",
        project: str = "",
        extra: str = "",
    ) -> dict[str, Any]:
        """Save a chat handoff so the next new chat can resume (continuity/latest)."""
        ctx = get_ctx()
        if ctx is None:
            raise RuntimeError("Runtime context not initialized")
        return svc_handoff_save(
            ctx.conn,
            summary=summary,
            next_steps=next_steps,
            blockers=blockers,
            working_files=working_files,
            project=project,
            extra=extra,
            client_id=ctx.client_id,
        )

    @mcp.tool
    def handoff_load() -> dict[str, Any] | None:
        """Load the latest continuity handoff from RAM."""
        ctx = get_ctx()
        if ctx is None:
            raise RuntimeError("Runtime context not initialized")
        return svc_handoff_load(ctx.conn)

    TOOL_NAMES.update(
        {
            "memory_set",
            "memory_get",
            "memory_list",
            "memory_delete",
            "memory_search",
            "memory_stats",
            "memory_flush",
            "project_focus",
            "project_current",
            "handoff_save",
            "handoff_load",
        }
    )
