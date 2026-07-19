"""RAM-resident memory corpus with durable disk backup.

Design goals (this rig has ~128 GB RAM):
- Entire memory_notes corpus stays in process memory after load.
- All reads/search hit RAM (no per-call SQLite row scans).
- Mutations write-through to SQLite immediately (durability).
- Full JSON snapshot written to disk as a second backup.
- Cheap generation check keeps dual MCP processes coherent.
"""

from __future__ import annotations

import json
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# Canonical keys for cross-chat continuity
KEY_ACTIVE_PROJECT = "project/active"
KEY_CONTINUITY_LATEST = "continuity/latest"


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _normalize_tags(tags: list[str] | None) -> list[str]:
    if not tags:
        return []
    out: list[str] = []
    seen: set[str] = set()
    for t in tags:
        s = str(t).strip()
        if not s or s in seen:
            continue
        seen.add(s)
        out.append(s)
    return out


def _note_bytes(note: dict[str, Any]) -> int:
    return len((note.get("key") or "").encode("utf-8")) + len(
        (note.get("body") or "").encode("utf-8")
    )


class RamMemoryBank:
    """In-process full-corpus memory; SQLite + JSON on disk are backups."""

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._notes: dict[str, dict[str, Any]] = {}
        self._conn: sqlite3.Connection | None = None
        self._home: Path | None = None
        self._json_backup: Path | None = None
        self._loaded = False
        self._load_ms: float = 0.0
        self._mutations = 0
        self._disk_gen: tuple[int, str] = (0, "")
        self._writes_since_snapshot = 0
        # Snapshot every mutation while small; every N after growth
        self._snapshot_every = 1

    # ── lifecycle ──────────────────────────────────────────────────────

    def attach(self, conn: sqlite3.Connection, home: Path) -> dict[str, Any]:
        """Bind to SQLite + home; load entire corpus into RAM."""
        with self._lock:
            self._conn = conn
            self._home = Path(home)
            self._json_backup = self._home / "memory_corpus.json"
            return self.reload(reason="attach")

    def reload(self, *, reason: str = "manual") -> dict[str, Any]:
        """Load all notes from SQLite into RAM (replaces corpus)."""
        import time

        with self._lock:
            if self._conn is None:
                raise RuntimeError("RamMemoryBank not attached")
            t0 = time.perf_counter()
            rows = self._conn.execute(
                "SELECT key, body, tags_json, created_at, updated_at "
                "FROM memory_notes ORDER BY key"
            ).fetchall()
            notes: dict[str, dict[str, Any]] = {}
            for row in rows:
                tags_raw = row["tags_json"] if "tags_json" in row.keys() else row[2]
                try:
                    tags = json.loads(tags_raw) if tags_raw else []
                except (json.JSONDecodeError, TypeError):
                    tags = []
                if not isinstance(tags, list):
                    tags = []
                key = row["key"] if "key" in row.keys() else row[0]
                notes[key] = {
                    "key": key,
                    "body": row["body"] if "body" in row.keys() else row[1],
                    "tags": tags,
                    "created_at": row["created_at"] if "created_at" in row.keys() else row[3],
                    "updated_at": row["updated_at"] if "updated_at" in row.keys() else row[4],
                }
            self._notes = notes
            self._disk_gen = self._read_disk_gen_unlocked()
            self._loaded = True
            self._load_ms = (time.perf_counter() - t0) * 1000.0
            # Keep snapshot cadence cheap for large corpora
            n = len(self._notes)
            self._snapshot_every = 1 if n < 200 else 10 if n < 2000 else 50
            self._write_json_snapshot_unlocked()
            return {
                "ok": True,
                "reason": reason,
                "note_count": n,
                "load_ms": round(self._load_ms, 3),
                "approx_bytes": self._approx_bytes_unlocked(),
            }

    def _read_disk_gen_unlocked(self) -> tuple[int, str]:
        assert self._conn is not None
        row = self._conn.execute(
            "SELECT COUNT(*) AS c, COALESCE(MAX(updated_at), '') AS m FROM memory_notes"
        ).fetchone()
        if row is None:
            return (0, "")
        c = int(row["c"] if "c" in row.keys() else row[0])
        m = str(row["m"] if "m" in row.keys() else row[1] or "")
        return (c, m)

    def _ensure_fresh_unlocked(self) -> None:
        """If another process mutated SQLite, reload corpus into RAM."""
        if self._conn is None or not self._loaded:
            return
        gen = self._read_disk_gen_unlocked()
        if gen != self._disk_gen:
            self.reload(reason="stale_gen")

    def _approx_bytes_unlocked(self) -> int:
        return sum(_note_bytes(n) for n in self._notes.values())

    def _write_json_snapshot_unlocked(self) -> None:
        if self._json_backup is None:
            return
        payload = {
            "version": 1,
            "saved_at": _utc_now_iso(),
            "note_count": len(self._notes),
            "notes": [self._notes[k] for k in sorted(self._notes.keys())],
        }
        tmp = self._json_backup.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(self._json_backup)
        self._writes_since_snapshot = 0

    def _maybe_snapshot_unlocked(self) -> None:
        self._writes_since_snapshot += 1
        if self._writes_since_snapshot >= self._snapshot_every:
            self._write_json_snapshot_unlocked()

    def _persist_set_unlocked(self, note: dict[str, Any]) -> None:
        assert self._conn is not None
        tags_json = json.dumps(list(note.get("tags") or []))
        self._conn.execute(
            """
            INSERT INTO memory_notes (key, body, tags_json, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                body = excluded.body,
                tags_json = excluded.tags_json,
                updated_at = excluded.updated_at
            """,
            (
                note["key"],
                note["body"],
                tags_json,
                note["created_at"],
                note["updated_at"],
            ),
        )
        self._conn.commit()
        self._disk_gen = self._read_disk_gen_unlocked()

    def _persist_delete_unlocked(self, key: str) -> None:
        assert self._conn is not None
        self._conn.execute("DELETE FROM memory_notes WHERE key = ?", (key,))
        self._conn.commit()
        self._disk_gen = self._read_disk_gen_unlocked()

    # ── CRUD (RAM) ─────────────────────────────────────────────────────

    def set(
        self,
        key: str,
        body: str,
        tags: list[str] | None = None,
    ) -> dict[str, Any]:
        key = (key or "").strip()
        if not key:
            raise ValueError("memory key must be non-empty")
        now = _utc_now_iso()
        tags_n = _normalize_tags(tags)
        with self._lock:
            self._ensure_fresh_unlocked()
            existing = self._notes.get(key)
            created = existing["created_at"] if existing else now
            note = {
                "key": key,
                "body": body if body is not None else "",
                "tags": tags_n,
                "created_at": created,
                "updated_at": now,
            }
            self._notes[key] = note
            self._persist_set_unlocked(note)
            self._mutations += 1
            self._maybe_snapshot_unlocked()
            return dict(note)

    def get(self, key: str) -> dict[str, Any] | None:
        with self._lock:
            self._ensure_fresh_unlocked()
            note = self._notes.get(key)
            return dict(note) if note else None

    def list(self) -> list[dict[str, Any]]:
        with self._lock:
            self._ensure_fresh_unlocked()
            return [dict(self._notes[k]) for k in sorted(self._notes.keys())]

    def list_recent(self, limit: int = 20) -> list[dict[str, Any]]:
        limit = max(1, min(int(limit), 500))
        with self._lock:
            self._ensure_fresh_unlocked()
            items = sorted(
                self._notes.values(),
                key=lambda n: n.get("updated_at") or "",
                reverse=True,
            )
            return [dict(n) for n in items[:limit]]

    def list_prefix(self, prefix: str) -> list[dict[str, Any]]:
        prefix = prefix or ""
        with self._lock:
            self._ensure_fresh_unlocked()
            keys = sorted(k for k in self._notes if k.startswith(prefix))
            return [dict(self._notes[k]) for k in keys]

    def delete(self, key: str) -> bool:
        with self._lock:
            self._ensure_fresh_unlocked()
            existed = key in self._notes
            if existed:
                del self._notes[key]
            self._persist_delete_unlocked(key)
            if existed:
                self._mutations += 1
                self._maybe_snapshot_unlocked()
            return existed

    def search(self, query: str, *, limit: int = 50) -> list[dict[str, Any]]:
        q = (query or "").strip().lower()
        limit = max(1, min(int(limit), 500))
        with self._lock:
            self._ensure_fresh_unlocked()
            if not q:
                return []
            hits: list[dict[str, Any]] = []
            for key in sorted(self._notes.keys()):
                note = self._notes[key]
                blob = f"{key}\n{note.get('body') or ''}\n{' '.join(note.get('tags') or [])}".lower()
                if q in blob:
                    hits.append(dict(note))
                    if len(hits) >= limit:
                        break
            return hits

    def stats(self) -> dict[str, Any]:
        with self._lock:
            approx = self._approx_bytes_unlocked() if self._loaded else 0
            return {
                "backend": "ram+sqlite+json",
                "loaded": self._loaded,
                "note_count": len(self._notes),
                "approx_bytes": approx,
                "approx_kb": round(approx / 1024.0, 2),
                "load_ms": round(self._load_ms, 3),
                "mutations": self._mutations,
                "disk_gen": {"count": self._disk_gen[0], "max_updated_at": self._disk_gen[1]},
                "json_backup": str(self._json_backup) if self._json_backup else None,
                "snapshot_every": self._snapshot_every,
            }

    def flush_backup(self) -> dict[str, Any]:
        """Force JSON corpus snapshot to disk."""
        with self._lock:
            self._ensure_fresh_unlocked()
            self._write_json_snapshot_unlocked()
            return {
                "ok": True,
                "path": str(self._json_backup) if self._json_backup else None,
                "note_count": len(self._notes),
            }


# Process singleton — attached in server.run_stdio / tests
_BANK: RamMemoryBank | None = None
_BANK_LOCK = threading.Lock()


def get_bank() -> RamMemoryBank | None:
    return _BANK


def set_bank(bank: RamMemoryBank | None) -> None:
    global _BANK
    with _BANK_LOCK:
        _BANK = bank


def ensure_bank(conn: sqlite3.Connection, home: Path) -> RamMemoryBank:
    """Return process bank, attaching/loading if needed."""
    global _BANK
    with _BANK_LOCK:
        if _BANK is None:
            _BANK = RamMemoryBank()
            _BANK.attach(conn, home)
        elif not _BANK._loaded:  # noqa: SLF001 — intentional re-attach path
            _BANK.attach(conn, home)
        return _BANK


def continuity_snapshot(bank: RamMemoryBank) -> dict[str, Any]:
    """Compact continuity payload for session_bootstrap / project_current."""
    active = bank.get(KEY_ACTIVE_PROJECT)
    handoff = bank.get(KEY_CONTINUITY_LATEST)
    projects = bank.list_prefix("project/")
    # Exclude project/active from project cards list detail if desired
    project_cards = [
        p
        for p in projects
        if p["key"] != KEY_ACTIVE_PROJECT and not p["key"].startswith("project/active")
    ]
    recent = [
        r
        for r in bank.list_recent(12)
        if not r["key"].startswith("agent_run/")
    ]
    return {
        "active_project": active,
        "handoff": handoff,
        "project_cards": project_cards[:20],
        "recent_notes": [
            {
                "key": r["key"],
                "tags": r.get("tags") or [],
                "updated_at": r.get("updated_at"),
                "body_preview": (r.get("body") or "")[:280],
            }
            for r in recent
        ],
        "memory_stats": bank.stats(),
        "protocol": {
            "keys": {
                "active_project": KEY_ACTIVE_PROJECT,
                "handoff": KEY_CONTINUITY_LATEST,
                "project_card": "project/{slug}",
            },
            "on_new_chat": [
                "session_bootstrap (includes this continuity block)",
                "Read active_project + handoff before asking what project this is",
                "Continue prior goal unless user redirects",
            ],
            "during_work": [
                "project_focus when switching repos/projects",
                "memory_set durable facts under project/{slug}/...",
                "handoff_save before context fills or chat ends",
            ],
        },
    }
