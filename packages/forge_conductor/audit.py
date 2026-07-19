"""Dual-write audit log: audit.jsonl + SQLite audit_events."""

from __future__ import annotations

import hashlib
import json
import sqlite3
from datetime import datetime, timezone
from typing import Any

from forge_conductor.config import get_home


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _canonical_args_json(args: dict[str, Any] | None) -> str:
    """Canonical JSON for digests: sorted keys, compact separators."""
    return json.dumps(args if args is not None else {}, sort_keys=True, separators=(",", ":"))


def args_digest(args: dict[str, Any] | None) -> str:
    """SHA-256 hex digest of canonical JSON args."""
    payload = _canonical_args_json(args)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def append(
    conn: sqlite3.Connection,
    *,
    tool: str,
    args: dict[str, Any] | None = None,
    status: str,
    client_id: str | None = None,
    duration_ms: int | None = None,
    mutating: bool = False,
    error: str | None = None,
    timestamp: str | None = None,
) -> dict[str, Any]:
    """Append an audit event to SQLite and {home}/audit.jsonl.

    Full args are stored only when *mutating* is True; digests are always stored.
    Returns the event dict as written (with ``args`` key for convenience).
    """
    ts = timestamp if timestamp is not None else _utc_now_iso()
    args = dict(args) if args is not None else {}
    digest = args_digest(args)
    args_for_store: dict[str, Any] | None = args if mutating else None
    args_json = json.dumps(args_for_store, sort_keys=True) if args_for_store is not None else None

    event = {
        "timestamp": ts,
        "client_id": client_id,
        "tool": tool,
        "args_digest": digest,
        "args": args_for_store,
        "status": status,
        "duration_ms": duration_ms,
        "error": error,
    }

    conn.execute(
        """
        INSERT INTO audit_events (
            timestamp, client_id, tool, args_digest, args_json, status, duration_ms, error
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            ts,
            client_id,
            tool,
            digest,
            args_json,
            status,
            duration_ms,
            error,
        ),
    )
    conn.commit()

    home = get_home()
    jsonl_path = home / "audit.jsonl"
    # jsonl line uses same fields; args may be null for non-mutating
    line = json.dumps(
        {
            "timestamp": ts,
            "client_id": client_id,
            "tool": tool,
            "args_digest": digest,
            "args": args_for_store,
            "status": status,
            "duration_ms": duration_ms,
            "error": error,
        },
        sort_keys=True,
    )
    with jsonl_path.open("a", encoding="utf-8") as f:
        f.write(line + "\n")

    return event


def _row_to_event(row: sqlite3.Row) -> dict[str, Any]:
    args_raw = row["args_json"]
    if args_raw is None:
        args: dict[str, Any] | None = None
    else:
        try:
            args = json.loads(args_raw)
        except json.JSONDecodeError:
            args = None
    return {
        "timestamp": row["timestamp"],
        "client_id": row["client_id"],
        "tool": row["tool"],
        "args_digest": row["args_digest"],
        "args": args,
        "status": row["status"],
        "duration_ms": row["duration_ms"],
        "error": row["error"],
    }


def tail(conn: sqlite3.Connection, limit: int = 50) -> list[dict[str, Any]]:
    """Return the newest *limit* audit events from SQLite (newest first)."""
    if limit < 1:
        return []
    rows = conn.execute(
        """
        SELECT timestamp, client_id, tool, args_digest, args_json, status, duration_ms, error
        FROM audit_events
        ORDER BY id DESC
        LIMIT ?
        """,
        (limit,),
    ).fetchall()
    return [_row_to_event(r) for r in rows]
