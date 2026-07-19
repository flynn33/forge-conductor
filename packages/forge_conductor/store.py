"""SQLite persistence: schema migrations and memory helpers."""

from __future__ import annotations

import json
import sqlite3
import uuid
from datetime import datetime, timezone
from typing import Any

from forge_conductor.config import get_home

SCHEMA_VERSION = 2

_CREATE_STATEMENTS = [
    """
    CREATE TABLE IF NOT EXISTS schema_version (
        version INTEGER NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS memory_notes (
        key TEXT PRIMARY KEY,
        body TEXT NOT NULL,
        tags_json TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS agent_sessions (
        id TEXT PRIMARY KEY,
        agent_id TEXT NOT NULL,
        client_id TEXT,
        status TEXT NOT NULL,
        summary TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS jobs (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        payload_json TEXT,
        status TEXT NOT NULL,
        owner_client_id TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        result_json TEXT
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS leases (
        key TEXT PRIMARY KEY,
        owner_client_id TEXT NOT NULL,
        expires_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS presence (
        client_id TEXT PRIMARY KEY,
        host_kind TEXT,
        pid INTEGER,
        cwd TEXT,
        last_heartbeat TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS audit_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT NOT NULL,
        client_id TEXT,
        tool TEXT NOT NULL,
        args_digest TEXT,
        args_json TEXT,
        status TEXT,
        duration_ms INTEGER,
        error TEXT
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS documents (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        source TEXT,
        created_at TEXT NOT NULL
    )
    """,
]


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def connect(path: str | None = None) -> sqlite3.Connection:
    """Open the store database under FORGE home (or *path*).

    Enables WAL journaling and foreign keys.
    """
    db_path = path if path is not None else str(get_home() / "store.sqlite")
    # check_same_thread=False: coordinator heartbeat runs on a daemon thread.
    # Callers must serialize access (Coordinator holds a lock for all ops).
    conn = sqlite3.connect(db_path, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA foreign_keys=ON;")
    return conn


def migrate(conn: sqlite3.Connection) -> None:
    """Apply schema migrations idempotently; set schema_version to current."""
    for stmt in _CREATE_STATEMENTS:
        conn.execute(stmt)

    row = conn.execute("SELECT version FROM schema_version LIMIT 1").fetchone()
    if row is None:
        conn.execute(
            "INSERT INTO schema_version (version) VALUES (?)",
            (SCHEMA_VERSION,),
        )
    else:
        conn.execute(
            "UPDATE schema_version SET version = ?",
            (SCHEMA_VERSION,),
        )
    conn.commit()


def _row_to_memory(row: sqlite3.Row) -> dict[str, Any]:
    tags_raw = row["tags_json"]
    try:
        tags = json.loads(tags_raw) if tags_raw else []
    except json.JSONDecodeError:
        tags = []
    return {
        "key": row["key"],
        "body": row["body"],
        "tags": tags,
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


def memory_set(
    conn: sqlite3.Connection,
    *,
    key: str,
    body: str,
    tags: list[str] | None = None,
) -> dict[str, Any]:
    """Insert or update a memory note. Returns the stored row."""
    tags = list(tags) if tags is not None else []
    tags_json = json.dumps(tags)
    now = _utc_now_iso()
    existing = conn.execute(
        "SELECT created_at FROM memory_notes WHERE key = ?",
        (key,),
    ).fetchone()
    if existing is None:
        conn.execute(
            """
            INSERT INTO memory_notes (key, body, tags_json, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            (key, body, tags_json, now, now),
        )
    else:
        conn.execute(
            """
            UPDATE memory_notes
            SET body = ?, tags_json = ?, updated_at = ?
            WHERE key = ?
            """,
            (body, tags_json, now, key),
        )
    conn.commit()
    row = memory_get(conn, key)
    assert row is not None
    return row


def memory_get(conn: sqlite3.Connection, key: str) -> dict[str, Any] | None:
    """Return a memory note by key, or None if missing."""
    row = conn.execute(
        "SELECT key, body, tags_json, created_at, updated_at FROM memory_notes WHERE key = ?",
        (key,),
    ).fetchone()
    if row is None:
        return None
    return _row_to_memory(row)


def memory_list(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    """List all memory notes ordered by key."""
    rows = conn.execute(
        "SELECT key, body, tags_json, created_at, updated_at FROM memory_notes ORDER BY key"
    ).fetchall()
    return [_row_to_memory(r) for r in rows]


def memory_delete(conn: sqlite3.Connection, key: str) -> bool:
    """Delete a memory note by key. Returns True if a row was deleted."""
    cur = conn.execute("DELETE FROM memory_notes WHERE key = ?", (key,))
    conn.commit()
    return cur.rowcount > 0


def memory_search(conn: sqlite3.Connection, query: str) -> list[dict[str, Any]]:
    """Search notes where body or key matches *query* (SQL LIKE, case-insensitive)."""
    pattern = f"%{query}%"
    rows = conn.execute(
        """
        SELECT key, body, tags_json, created_at, updated_at
        FROM memory_notes
        WHERE body LIKE ? COLLATE NOCASE OR key LIKE ? COLLATE NOCASE
        ORDER BY key
        """,
        (pattern, pattern),
    ).fetchall()
    return [_row_to_memory(r) for r in rows]


def _row_to_session(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "agent_id": row["agent_id"],
        "client_id": row["client_id"],
        "status": row["status"],
        "summary": row["summary"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


def agent_session_start(
    conn: sqlite3.Connection,
    *,
    agent_id: str,
    client_id: str | None = None,
    session_id: str | None = None,
) -> dict[str, Any]:
    """Create an open agent session. Returns the stored row."""
    sid = session_id if session_id is not None else str(uuid.uuid4())
    now = _utc_now_iso()
    conn.execute(
        """
        INSERT INTO agent_sessions (id, agent_id, client_id, status, summary, created_at, updated_at)
        VALUES (?, ?, ?, 'open', NULL, ?, ?)
        """,
        (sid, agent_id, client_id, now, now),
    )
    conn.commit()
    row = agent_session_get(conn, sid)
    assert row is not None
    return row


def agent_session_get(conn: sqlite3.Connection, session_id: str) -> dict[str, Any] | None:
    """Return a session by id, or None if missing."""
    row = conn.execute(
        """
        SELECT id, agent_id, client_id, status, summary, created_at, updated_at
        FROM agent_sessions WHERE id = ?
        """,
        (session_id,),
    ).fetchone()
    if row is None:
        return None
    return _row_to_session(row)


def agent_session_end(
    conn: sqlite3.Connection,
    *,
    session_id: str,
    summary: str | None = None,
) -> dict[str, Any]:
    """Close a session and optionally set summary. Raises KeyError if missing."""
    existing = agent_session_get(conn, session_id)
    if existing is None:
        raise KeyError(f"Unknown agent session: {session_id}")
    now = _utc_now_iso()
    conn.execute(
        """
        UPDATE agent_sessions
        SET status = 'closed', summary = ?, updated_at = ?
        WHERE id = ?
        """,
        (summary, now, session_id),
    )
    conn.commit()
    row = agent_session_get(conn, session_id)
    assert row is not None
    return row


def agent_session_list(
    conn: sqlite3.Connection,
    *,
    agent_id: str | None = None,
    status: str | None = None,
) -> list[dict[str, Any]]:
    """List sessions ordered by created_at descending, with optional filters."""
    clauses: list[str] = []
    params: list[Any] = []
    if agent_id is not None:
        clauses.append("agent_id = ?")
        params.append(agent_id)
    if status is not None:
        clauses.append("status = ?")
        params.append(status)
    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    rows = conn.execute(
        f"""
        SELECT id, agent_id, client_id, status, summary, created_at, updated_at
        FROM agent_sessions
        {where}
        ORDER BY created_at DESC
        """,
        params,
    ).fetchall()
    return [_row_to_session(r) for r in rows]


def _row_to_document(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "title": row["title"],
        "body": row["body"],
        "source": row["source"],
        "created_at": row["created_at"],
    }


def document_ingest(
    conn: sqlite3.Connection,
    *,
    title: str,
    body: str,
    source: str | None = None,
    doc_id: str | None = None,
) -> dict[str, Any]:
    """Insert a document row. Returns the stored document."""
    did = doc_id if doc_id is not None else str(uuid.uuid4())
    now = _utc_now_iso()
    conn.execute(
        """
        INSERT INTO documents (id, title, body, source, created_at)
        VALUES (?, ?, ?, ?, ?)
        """,
        (did, title, body, source, now),
    )
    conn.commit()
    row = document_get(conn, did)
    assert row is not None
    return row


def document_get(conn: sqlite3.Connection, doc_id: str) -> dict[str, Any] | None:
    """Return a document by id, or None if missing."""
    row = conn.execute(
        """
        SELECT id, title, body, source, created_at
        FROM documents WHERE id = ?
        """,
        (doc_id,),
    ).fetchone()
    if row is None:
        return None
    return _row_to_document(row)


def document_search(
    conn: sqlite3.Connection,
    query: str,
    *,
    limit: int = 50,
) -> list[dict[str, Any]]:
    """Search documents where title or body matches *query* (SQL LIKE, case-insensitive)."""
    pattern = f"%{query}%"
    rows = conn.execute(
        """
        SELECT id, title, body, source, created_at
        FROM documents
        WHERE title LIKE ? COLLATE NOCASE OR body LIKE ? COLLATE NOCASE
        ORDER BY created_at DESC
        LIMIT ?
        """,
        (pattern, pattern, limit),
    ).fetchall()
    return [_row_to_document(r) for r in rows]
