"""Agent job queue for Grok worker (uses store.jobs table)."""

from __future__ import annotations

import json
import sqlite3
import uuid
from datetime import datetime, timezone
from typing import Any


def _utc() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


JOB_TYPE = "agent_grok"


def enqueue_agent_job(
    conn: sqlite3.Connection,
    *,
    session_id: str,
    agent_id: str,
    goal: str,
    payload: dict[str, Any],
    owner_client_id: str | None = None,
) -> dict[str, Any]:
    jid = str(uuid.uuid4())
    now = _utc()
    body = {
        "session_id": session_id,
        "agent_id": agent_id,
        "goal": goal,
        **payload,
    }
    conn.execute(
        """
        INSERT INTO jobs (id, type, payload_json, status, owner_client_id, created_at, updated_at, result_json)
        VALUES (?, ?, ?, 'queued', ?, ?, ?, NULL)
        """,
        (jid, JOB_TYPE, json.dumps(body, default=str), owner_client_id, now, now),
    )
    conn.commit()
    return {"id": jid, "status": "queued", "session_id": session_id, "type": JOB_TYPE}


def claim_next_job(conn: sqlite3.Connection) -> dict[str, Any] | None:
    row = conn.execute(
        """
        SELECT id, type, payload_json, status, owner_client_id, created_at, updated_at, result_json
        FROM jobs
        WHERE type = ? AND status = 'queued'
        ORDER BY created_at ASC
        LIMIT 1
        """,
        (JOB_TYPE,),
    ).fetchone()
    if row is None:
        return None
    jid = row["id"] if isinstance(row, sqlite3.Row) else row[0]
    now = _utc()
    conn.execute(
        "UPDATE jobs SET status = 'running', updated_at = ? WHERE id = ? AND status = 'queued'",
        (now, jid),
    )
    conn.commit()
    # re-read
    row2 = conn.execute(
        "SELECT id, type, payload_json, status, owner_client_id, created_at, updated_at, result_json FROM jobs WHERE id = ?",
        (jid,),
    ).fetchone()
    return _row_to_dict(row2)


def complete_job(
    conn: sqlite3.Connection,
    job_id: str,
    *,
    status: str,
    result: dict[str, Any] | None = None,
) -> None:
    now = _utc()
    conn.execute(
        "UPDATE jobs SET status = ?, result_json = ?, updated_at = ? WHERE id = ?",
        (status, json.dumps(result or {}, default=str), now, job_id),
    )
    conn.commit()


def get_job(conn: sqlite3.Connection, job_id: str) -> dict[str, Any] | None:
    row = conn.execute(
        "SELECT id, type, payload_json, status, owner_client_id, created_at, updated_at, result_json FROM jobs WHERE id = ?",
        (job_id,),
    ).fetchone()
    return _row_to_dict(row) if row else None


def get_job_for_session(conn: sqlite3.Connection, session_id: str) -> dict[str, Any] | None:
    rows = conn.execute(
        """
        SELECT id, type, payload_json, status, owner_client_id, created_at, updated_at, result_json
        FROM jobs WHERE type = ? ORDER BY created_at DESC LIMIT 50
        """,
        (JOB_TYPE,),
    ).fetchall()
    for row in rows:
        d = _row_to_dict(row)
        payload = d.get("payload") or {}
        if payload.get("session_id") == session_id:
            return d
    return None


def _row_to_dict(row: Any) -> dict[str, Any]:
    if row is None:
        return {}
    if isinstance(row, sqlite3.Row):
        d = dict(row)
    else:
        keys = [
            "id",
            "type",
            "payload_json",
            "status",
            "owner_client_id",
            "created_at",
            "updated_at",
            "result_json",
        ]
        d = {k: row[i] for i, k in enumerate(keys)}
    payload = {}
    if d.get("payload_json"):
        try:
            payload = json.loads(d["payload_json"])
        except json.JSONDecodeError:
            payload = {}
    result = None
    if d.get("result_json"):
        try:
            result = json.loads(d["result_json"])
        except json.JSONDecodeError:
            result = d["result_json"]
    return {
        "id": d.get("id"),
        "type": d.get("type"),
        "status": d.get("status"),
        "payload": payload,
        "result": result,
        "owner_client_id": d.get("owner_client_id"),
        "created_at": d.get("created_at"),
        "updated_at": d.get("updated_at"),
    }
