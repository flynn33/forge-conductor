"""Multi-process coordinator: presence, leases, and jobs (SQLite-backed).

v1 uses the shared SQLite store as source of truth (mode ``local`` / ``degraded``).
Leader election + localhost TCP IPC may be layered later; lease renew is implicit
via presence heartbeat and reclaim of expired rows.

All DB access is serialized with an RLock so the heartbeat daemon thread is safe.
"""

from __future__ import annotations

import json
import logging
import sqlite3
import threading
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

logger = logging.getLogger(__name__)


def _utc_now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def _to_iso(dt: datetime) -> str:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _parse_iso(value: str) -> datetime:
    """Parse store timestamps (``...Z`` or offset) into aware UTC datetimes."""
    s = value.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


class Coordinator:
    """Store-backed coordinator for a single client_id process."""

    def __init__(
        self,
        conn: sqlite3.Connection,
        client_id: str,
        lease_ttl_sec: int = 60,
        presence_ttl_sec: int = 30,
    ) -> None:
        self.conn = conn
        self.client_id = client_id
        self.lease_ttl_sec = int(lease_ttl_sec)
        self.presence_ttl_sec = int(presence_ttl_sec)
        self.mode = "local"  # SQLite-only; no leader IPC in v1
        self._lock = threading.RLock()
        self._stop = threading.Event()
        self._hb_thread: threading.Thread | None = None

    def register_presence(self, host_kind: str, pid: int, cwd: str) -> None:
        """Upsert this client's presence row."""
        now = _to_iso(_utc_now())
        with self._lock:
            self.conn.execute(
                """
                INSERT INTO presence (client_id, host_kind, pid, cwd, last_heartbeat)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(client_id) DO UPDATE SET
                    host_kind = excluded.host_kind,
                    pid = excluded.pid,
                    cwd = excluded.cwd,
                    last_heartbeat = excluded.last_heartbeat
                """,
                (self.client_id, host_kind, int(pid), cwd, now),
            )
            self.conn.commit()

    def heartbeat(self) -> None:
        """Refresh last_heartbeat for this client (no-op if not registered)."""
        now = _to_iso(_utc_now())
        with self._lock:
            self.conn.execute(
                """
                UPDATE presence
                SET last_heartbeat = ?
                WHERE client_id = ?
                """,
                (now, self.client_id),
            )
            self.conn.commit()

    def reclaim_expired(self) -> None:
        """Delete expired presence rows and leases (TTL or dead owner)."""
        now = _utc_now()
        presence_cutoff = _to_iso(now - timedelta(seconds=self.presence_ttl_sec))
        now_iso = _to_iso(now)

        with self._lock:
            self.conn.execute(
                "DELETE FROM presence WHERE last_heartbeat < ?",
                (presence_cutoff,),
            )
            self.conn.execute(
                "DELETE FROM leases WHERE expires_at < ?",
                (now_iso,),
            )
            self.conn.execute(
                """
                DELETE FROM leases
                WHERE owner_client_id NOT IN (SELECT client_id FROM presence)
                """
            )
            self.conn.execute(
                """
                UPDATE jobs
                SET status = 'open', owner_client_id = NULL, updated_at = ?
                WHERE status = 'claimed'
                  AND (
                    owner_client_id IS NULL
                    OR owner_client_id NOT IN (SELECT client_id FROM presence)
                  )
                """,
                (now_iso,),
            )
            self.conn.commit()

    def acquire_lease(self, key: str, ttl_sec: int | None = None) -> bool:
        """Acquire *key* for this client. Returns True on success."""
        ttl = self.lease_ttl_sec if ttl_sec is None else int(ttl_sec)
        self.reclaim_expired()
        now = _utc_now()
        expires = _to_iso(now + timedelta(seconds=ttl))

        with self._lock:
            try:
                self.conn.execute("BEGIN IMMEDIATE")
                row = self.conn.execute(
                    "SELECT owner_client_id, expires_at FROM leases WHERE key = ?",
                    (key,),
                ).fetchone()
                if row is None:
                    self.conn.execute(
                        """
                        INSERT INTO leases (key, owner_client_id, expires_at)
                        VALUES (?, ?, ?)
                        """,
                        (key, self.client_id, expires),
                    )
                    self.conn.commit()
                    return True

                owner = row["owner_client_id"]
                exp = _parse_iso(row["expires_at"])
                if owner == self.client_id or exp <= now:
                    self.conn.execute(
                        """
                        UPDATE leases
                        SET owner_client_id = ?, expires_at = ?
                        WHERE key = ?
                        """,
                        (self.client_id, expires, key),
                    )
                    self.conn.commit()
                    return True

                self.conn.commit()
                return False
            except sqlite3.Error:
                self.conn.rollback()
                raise

    def release_lease(self, key: str) -> bool:
        """Release *key* if held by this client. Returns True if a row was deleted."""
        with self._lock:
            cur = self.conn.execute(
                "DELETE FROM leases WHERE key = ? AND owner_client_id = ?",
                (key, self.client_id),
            )
            self.conn.commit()
            return cur.rowcount > 0

    def create_job(self, type: str, payload: dict) -> str:
        """Create an open job; returns job id."""
        job_id = str(uuid.uuid4())
        now = _to_iso(_utc_now())
        payload_json = json.dumps(payload if payload is not None else {})
        with self._lock:
            self.conn.execute(
                """
                INSERT INTO jobs (
                    id, type, payload_json, status, owner_client_id,
                    created_at, updated_at, result_json
                )
                VALUES (?, ?, ?, 'open', NULL, ?, ?, NULL)
                """,
                (job_id, type, payload_json, now, now),
            )
            self.conn.commit()
        return job_id

    def claim_job(self) -> dict[str, Any] | None:
        """Claim the oldest open job for this client, or None if none."""
        self.reclaim_expired()
        now = _to_iso(_utc_now())
        with self._lock:
            try:
                self.conn.execute("BEGIN IMMEDIATE")
                row = self.conn.execute(
                    """
                    SELECT id, type, payload_json, status, owner_client_id,
                           created_at, updated_at, result_json
                    FROM jobs
                    WHERE status = 'open'
                    ORDER BY created_at ASC
                    LIMIT 1
                    """
                ).fetchone()
                if row is None:
                    self.conn.commit()
                    return None
                job_id = row["id"]
                self.conn.execute(
                    """
                    UPDATE jobs
                    SET status = 'claimed', owner_client_id = ?, updated_at = ?
                    WHERE id = ? AND status = 'open'
                    """,
                    (self.client_id, now, job_id),
                )
                if self.conn.execute("SELECT changes()").fetchone()[0] == 0:
                    self.conn.commit()
                    return None
                self.conn.commit()
                return self._job_row(
                    self.conn.execute(
                        """
                        SELECT id, type, payload_json, status, owner_client_id,
                               created_at, updated_at, result_json
                        FROM jobs WHERE id = ?
                        """,
                        (job_id,),
                    ).fetchone()
                )
            except sqlite3.Error:
                self.conn.rollback()
                raise

    def complete_job(
        self,
        job_id: str,
        result: dict,
        failed: bool = False,
    ) -> None:
        """Mark a claimed job done or failed with *result*."""
        now = _to_iso(_utc_now())
        status = "failed" if failed else "done"
        result_json = json.dumps(result if result is not None else {})
        with self._lock:
            self.conn.execute(
                """
                UPDATE jobs
                SET status = ?, result_json = ?, updated_at = ?
                WHERE id = ?
                """,
                (status, result_json, now, job_id),
            )
            self.conn.commit()

    def status(self) -> dict[str, Any]:
        """Coordinator status snapshot for hosts and diagnostics."""
        self.reclaim_expired()
        with self._lock:
            presence_count = self.conn.execute(
                "SELECT COUNT(*) FROM presence"
            ).fetchone()[0]
            open_jobs = self.conn.execute(
                "SELECT COUNT(*) FROM jobs WHERE status = 'open'"
            ).fetchone()[0]
            claimed_jobs = self.conn.execute(
                "SELECT COUNT(*) FROM jobs WHERE status = 'claimed'"
            ).fetchone()[0]
            lease_count = self.conn.execute(
                "SELECT COUNT(*) FROM leases"
            ).fetchone()[0]
            return {
                "mode": self.mode,
                "client_id": self.client_id,
                "presence_count": int(presence_count),
                "open_jobs": int(open_jobs),
                "claimed_jobs": int(claimed_jobs),
                "lease_count": int(lease_count),
                "lease_ttl_sec": self.lease_ttl_sec,
                "presence_ttl_sec": self.presence_ttl_sec,
            }

    def start_heartbeat(self, interval_sec: float | None = None) -> None:
        """Start a daemon thread that heartbeats and reclaims expired rows."""
        if self._hb_thread is not None and self._hb_thread.is_alive():
            return
        interval = (
            float(interval_sec)
            if interval_sec is not None
            else max(1.0, self.presence_ttl_sec / 3.0)
        )
        self._stop.clear()

        def _loop() -> None:
            while not self._stop.wait(interval):
                try:
                    self.heartbeat()
                    self.reclaim_expired()
                except Exception:
                    logger.exception("coordinator heartbeat/reclaim failed")

        self._hb_thread = threading.Thread(
            target=_loop,
            name=f"forge-coord-hb-{self.client_id[:8]}",
            daemon=True,
        )
        self._hb_thread.start()

    def stop_heartbeat(self) -> None:
        """Signal the heartbeat thread to stop (tests / clean shutdown)."""
        self._stop.set()

    @staticmethod
    def _job_row(row: sqlite3.Row | None) -> dict[str, Any] | None:
        if row is None:
            return None
        try:
            payload = json.loads(row["payload_json"]) if row["payload_json"] else {}
        except json.JSONDecodeError:
            payload = {}
        try:
            result = json.loads(row["result_json"]) if row["result_json"] else None
        except json.JSONDecodeError:
            result = None
        return {
            "id": row["id"],
            "type": row["type"],
            "payload": payload,
            "status": row["status"],
            "owner_client_id": row["owner_client_id"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
            "result": result,
        }
