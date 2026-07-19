"""RAM-resident Forge orchestration layer with durable disk backup.

Loads the hot working set into process memory (this rig has ~128 GB RAM):
  - full agent catalog + playbooks (parsed)
  - agent sessions
  - documents
  - recent audit ring
  - config snapshot
  - pointer to RamMemoryBank (notes already RAM-first)

Mutations write-through to SQLite where applicable; full snapshot to
``orchestration_corpus.json`` for crash recovery / inspectability.
"""

from __future__ import annotations

import json
import re
import sqlite3
import threading
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from forge_conductor.memory_ram import (
    KEY_ACTIVE_PROJECT,
    KEY_CONTINUITY_LATEST,
    RamMemoryBank,
    continuity_snapshot,
    ensure_bank,
    get_bank,
)


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _approx_size(obj: Any) -> int:
    try:
        return len(json.dumps(obj, default=str).encode("utf-8"))
    except Exception:
        return 0


class RamOrchestration:
    """In-process orchestration state; SQLite + JSON are backups."""

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._conn: sqlite3.Connection | None = None
        self._home: Path | None = None
        self._loaded = False
        self._load_ms = 0.0
        self._mutations = 0
        self._snapshot_path: Path | None = None

        # Hot catalogs
        self.agents: dict[str, Any] = {}  # id -> card + body + playbook dict
        self.sessions: dict[str, dict[str, Any]] = {}
        self.documents: dict[str, dict[str, Any]] = {}
        self.audit_ring: deque[dict[str, Any]] = deque(maxlen=2000)
        self.config: dict[str, Any] = {}
        self.route_hints: list[dict[str, str]] = []
        self.presence: list[dict[str, Any]] = []
        self.super_policy: dict[str, Any] = {}

    def attach(self, conn: sqlite3.Connection, home: Path) -> dict[str, Any]:
        with self._lock:
            self._conn = conn
            self._home = Path(home)
            self._snapshot_path = self._home / "orchestration_corpus.json"
            # Ensure memory bank is hot first
            ensure_bank(conn, home)
            return self.reload(reason="attach")

    def reload(self, *, reason: str = "manual") -> dict[str, Any]:
        import time as _time

        from forge_conductor.agents_loader import ROUTE_HINTS, load_agents
        from forge_conductor.config import load_config

        with self._lock:
            if self._conn is None or self._home is None:
                raise RuntimeError("RamOrchestration not attached")
            t0 = _time.perf_counter()

            # Agents — full catalog in RAM
            agents = load_agents(self._home)
            hot: dict[str, Any] = {}
            for aid, spec in agents.items():
                hot[aid] = {
                    "id": spec.id,
                    "display_name": spec.display_name,
                    "description": spec.description,
                    "source": spec.source,
                    "tools": list(spec.tools),
                    "playbook": spec.playbook(),
                    "body": spec.body,
                    "card": spec.card(),
                }
            self.agents = hot
            self.route_hints = list(ROUTE_HINTS)

            # Sessions
            try:
                rows = self._conn.execute(
                    "SELECT id, agent_id, client_id, status, summary, created_at, updated_at "
                    "FROM agent_sessions ORDER BY updated_at DESC LIMIT 500"
                ).fetchall()
                self.sessions = {
                    r["id"]: {
                        "id": r["id"],
                        "agent_id": r["agent_id"],
                        "client_id": r["client_id"],
                        "status": r["status"],
                        "summary": r["summary"],
                        "created_at": r["created_at"],
                        "updated_at": r["updated_at"],
                    }
                    for r in rows
                }
            except Exception:
                self.sessions = {}

            # Documents
            try:
                rows = self._conn.execute(
                    "SELECT id, title, body, source, created_at FROM documents "
                    "ORDER BY created_at DESC LIMIT 200"
                ).fetchall()
                self.documents = {
                    r["id"]: {
                        "id": r["id"],
                        "title": r["title"],
                        "body": r["body"],
                        "source": r["source"],
                        "created_at": r["created_at"],
                    }
                    for r in rows
                }
            except Exception:
                self.documents = {}

            # Presence
            try:
                rows = self._conn.execute(
                    "SELECT client_id, host_kind, pid, cwd, last_heartbeat "
                    "FROM presence ORDER BY last_heartbeat DESC LIMIT 50"
                ).fetchall()
                self.presence = [dict(r) for r in rows]
            except Exception:
                self.presence = []

            # Audit ring from SQLite (args may be truncated)
            try:
                rows = self._conn.execute(
                    "SELECT id, timestamp, client_id, tool, status, duration_ms, error, "
                    "substr(args_json,1,400) AS args_preview "
                    "FROM audit_events ORDER BY id DESC LIMIT 500"
                ).fetchall()
                self.audit_ring.clear()
                for r in reversed(list(rows)):
                    self.audit_ring.append(dict(r))
            except Exception:
                self.audit_ring.clear()

            try:
                self.config = load_config()
            except Exception:
                self.config = {}

            self.super_policy = {
                "mode": "super_agents",
                "ram_orchestration": True,
                "rules": [
                    "Every agent_run_start receives super_context from RAM (project, handoff, memory, prior runs).",
                    "Prefer specialist chains over host freelancing (plan→docs|implement).",
                    "Plan never writes files; hand off to docs or implement.",
                    "Docs owns ROADMAP/README/runbooks on disk.",
                    "Do not skip specialists to save tokens on this host.",
                    "Persist durable findings with memory_set under project/{slug}/...",
                    "handoff_save before context fills (also auto).",
                ],
                "chains": {
                    "roadmap_or_docs_file": ["explore?", "plan?", "docs"],
                    "feature": ["explore?", "plan", "implement", "test", "review", "precommit-audit"],
                    "bug": ["debug", "implement", "test", "precommit-audit"],
                },
            }

            self._loaded = True
            self._load_ms = (_time.perf_counter() - t0) * 1000.0
            self._write_snapshot_unlocked()
            return self.stats()

    def _write_snapshot_unlocked(self) -> None:
        if self._snapshot_path is None:
            return
        bank = get_bank()
        mem_stats = bank.stats() if bank else {}
        # Compact sessions/docs for snapshot size
        payload = {
            "version": 1,
            "kind": "forge_ram_orchestration",
            "saved_at": _utc_now_iso(),
            "super_policy": self.super_policy,
            "agent_ids": sorted(self.agents.keys()),
            "agents": {
                k: {
                    "id": v["id"],
                    "display_name": v["display_name"],
                    "description": v["description"],
                    "tools": v["tools"],
                    "playbook": v["playbook"],
                    # body included — this is the point of RAM super agents
                    "body": v["body"],
                    "source": v["source"],
                }
                for k, v in self.agents.items()
            },
            "sessions": list(self.sessions.values())[:200],
            "documents": [
                {
                    "id": d["id"],
                    "title": d["title"],
                    "source": d["source"],
                    "created_at": d["created_at"],
                    "body_preview": (d.get("body") or "")[:500],
                }
                for d in list(self.documents.values())[:100]
            ],
            "presence": self.presence,
            "audit_recent": list(self.audit_ring)[-100:],
            "route_hints": self.route_hints,
            "memory_stats": mem_stats,
            "config_keys": sorted(self.config.keys()) if isinstance(self.config, dict) else [],
        }
        tmp = self._snapshot_path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(self._snapshot_path)

    def flush_backup(self) -> dict[str, Any]:
        with self._lock:
            bank = get_bank()
            mem = bank.flush_backup() if bank else {}
            self._write_snapshot_unlocked()
            return {
                "ok": True,
                "orchestration_backup": str(self._snapshot_path),
                "memory_backup": mem,
                "stats": self.stats(),
            }

    def stats(self) -> dict[str, Any]:
        with self._lock:
            bank = get_bank()
            mem = bank.stats() if bank else {"loaded": False}
            approx = (
                _approx_size(self.agents)
                + _approx_size(list(self.sessions.values())[:50])
                + _approx_size(list(self.documents.values())[:20])
                + int(mem.get("approx_bytes") or 0)
            )
            return {
                "backend": "ram-orchestration+sqlite+json",
                "loaded": self._loaded,
                "load_ms": round(self._load_ms, 3),
                "mutations": self._mutations,
                "agents": len(self.agents),
                "sessions": len(self.sessions),
                "documents": len(self.documents),
                "audit_ring": len(self.audit_ring),
                "presence": len(self.presence),
                "approx_bytes": approx,
                "approx_mb": round(approx / (1024 * 1024), 3),
                "memory": mem,
                "orchestration_backup": str(self._snapshot_path) if self._snapshot_path else None,
                "super_mode": True,
            }

    def note_audit(self, event: dict[str, Any]) -> None:
        with self._lock:
            self.audit_ring.append(event)
            self._mutations += 1

    def refresh_session(self, row: dict[str, Any]) -> None:
        with self._lock:
            if row and row.get("id"):
                self.sessions[row["id"]] = dict(row)
                self._mutations += 1

    def build_super_context(
        self,
        *,
        agent_id: str,
        goal: str,
        cwd: str | None = None,
    ) -> dict[str, Any]:
        """Rich RAM context injected into every agent run (informed super agents)."""
        with self._lock:
            bank = get_bank()
            cont = continuity_snapshot(bank) if bank else {}
            goal_l = (goal or "").lower()
            related: list[dict[str, Any]] = []
            if bank and goal.strip():
                # Pull keywords from goal for memory search
                words = [w for w in re.findall(r"[a-zA-Z0-9_\-]{4,}", goal) if w.lower() not in {
                    "this", "that", "with", "from", "into", "about", "write", "create", "make", "please"
                }]
                seen: set[str] = set()
                for w in words[:8]:
                    for hit in bank.search(w, limit=5):
                        if hit["key"] in seen or hit["key"].startswith("agent_run/"):
                            continue
                        seen.add(hit["key"])
                        related.append(
                            {
                                "key": hit["key"],
                                "tags": hit.get("tags") or [],
                                "preview": (hit.get("body") or "")[:320],
                            }
                        )
                        if len(related) >= 10:
                            break
                    if len(related) >= 10:
                        break

            # Prior agent reports from sessions + agent_run memory keys
            prior_runs: list[dict[str, Any]] = []
            for s in sorted(
                self.sessions.values(),
                key=lambda x: x.get("updated_at") or "",
                reverse=True,
            )[:12]:
                if s.get("summary"):
                    prior_runs.append(
                        {
                            "session_id": s["id"],
                            "agent_id": s["agent_id"],
                            "status": s["status"],
                            "summary_preview": (s.get("summary") or "")[:400],
                        }
                    )
            if bank:
                for note in bank.list_prefix("agent_run/")[-8:]:
                    prior_runs.append(
                        {
                            "key": note["key"],
                            "preview": (note.get("body") or "")[:300],
                            "updated_at": note.get("updated_at"),
                        }
                    )

            # Doc titles hot in RAM
            doc_hits: list[dict[str, Any]] = []
            tokens = re.findall(r"[a-zA-Z0-9_\-]{4,}", goal_l)
            for d in list(self.documents.values())[:50]:
                blob = f"{d.get('title', '')} {(d.get('body') or '')[:400]}".lower()
                if tokens and any(t in blob for t in tokens[:6]):
                    doc_hits.append({"id": d["id"], "title": d["title"]})

            agent = self.agents.get(agent_id) or {}
            chain = self._suggest_chain(agent_id, goal_l)

            return {
                "super_mode": True,
                "generated_at": _utc_now_iso(),
                "agent_id": agent_id,
                "goal": goal,
                "cwd": cwd,
                "active_project": cont.get("active_project"),
                "handoff": cont.get("handoff"),
                "related_memory": related,
                "prior_runs": prior_runs[:10],
                "related_documents": doc_hits[:8],
                "agent_card": agent.get("card"),
                "suggested_chain": chain,
                "super_policy_rules": list(self.super_policy.get("rules") or []),
                "memory_stats": bank.stats() if bank else {},
                "orchestration_stats": {
                    "agents": len(self.agents),
                    "sessions": len(self.sessions),
                    "documents": len(self.documents),
                    "audit_ring": len(self.audit_ring),
                },
                "instructions": (
                    "You are a SUPER agent with full RAM orchestration context. "
                    "Use related_memory and handoff before re-asking project path. "
                    "Stay in role (tools_primary). When done_definition met, "
                    "agent_run_complete with output_schema, then follow suggested_chain."
                ),
            }

    def _suggest_chain(self, agent_id: str, goal_l: str) -> list[dict[str, str]]:
        chain: list[dict[str, str]] = []
        write_doc = any(
            k in goal_l
            for k in (
                "roadmap",
                "readme",
                "documentation",
                "write docs",
                "docs file",
                ".md",
                "runbook",
                "changelog",
            )
        )
        code_change = any(
            k in goal_l
            for k in ("implement", "fix", "bug", "feature", "refactor", "code", "patch")
        )
        if agent_id == "plan":
            if write_doc:
                chain.append(
                    {
                        "agent_id": "docs",
                        "why": "Plan never writes files; docs writes ROADMAP/README/markdown deliverables",
                        "call": "agent_run_start(agent_id='docs', goal=...)",
                    }
                )
            elif code_change:
                chain.append(
                    {
                        "agent_id": "implement",
                        "why": "Plan complete → implement coded changes",
                        "call": "agent_run_start(agent_id='implement', goal=...)",
                    }
                )
            else:
                chain.append(
                    {
                        "agent_id": "docs",
                        "why": "Default after plan for written artifacts; use implement if code",
                        "call": "agent_run_start(agent_id='docs', goal=...)",
                    }
                )
        elif agent_id == "explore":
            chain.append(
                {
                    "agent_id": "plan" if not write_doc else "docs",
                    "why": "Explore maps; plan sequences code work, docs writes doc deliverables",
                    "call": f"agent_run_start(agent_id='{'plan' if not write_doc else 'docs'}', goal=...)",
                }
            )
        elif agent_id == "implement":
            chain.append(
                {
                    "agent_id": "test",
                    "why": "Verify after code changes",
                    "call": "agent_run_start(agent_id='test', goal=...)",
                }
            )
            chain.append(
                {
                    "agent_id": "precommit-audit",
                    "why": "Gate before commit",
                    "call": "agent_run_start(agent_id='precommit-audit', goal=...)",
                }
            )
        elif agent_id == "docs":
            chain.append(
                {
                    "agent_id": "review",
                    "why": "Optional accuracy pass on docs vs code",
                    "call": "agent_run_start(agent_id='review', goal=...)",
                }
            )
        return chain

    def recommend_chain(self, task: str) -> dict[str, Any]:
        """Smarter multi-step recommendation from RAM catalog."""
        from forge_conductor.agents_loader import recommend_agent

        base = recommend_agent(task, self._home)
        t = (task or "").lower()
        steps: list[dict[str, str]] = []
        write_doc = any(
            k in t for k in ("roadmap", "readme", "documentation", ".md", "runbook", "write a doc")
        )
        if write_doc and any(k in t for k in ("plan", "roadmap", "architecture", "multi-step")):
            steps = [
                {"agent_id": "explore", "optional": "true", "why": "Map if repo unfamiliar"},
                {"agent_id": "plan", "optional": "true", "why": "Structure content only — no file writes"},
                {"agent_id": "docs", "optional": "false", "why": "Write markdown deliverable to disk"},
            ]
            primary = "docs"
        elif any(k in t for k in ("bug", "crash", "failing", "debug")):
            steps = [
                {"agent_id": "debug", "optional": "false", "why": "Root cause"},
                {"agent_id": "implement", "optional": "false", "why": "Apply fix"},
                {"agent_id": "test", "optional": "false", "why": "Verify"},
            ]
            primary = "debug"
        else:
            primary = base.get("agent_id") or "explore"
            steps = [{"agent_id": primary, "optional": "false", "why": base.get("reason") or "router"}]
            # attach playbook handoff as next
            ag = self.agents.get(primary) or {}
            for h in (ag.get("playbook") or {}).get("handoff") or []:
                steps.append({"agent_id": h, "optional": "true", "why": f"handoff from {primary}"})

        return {
            "ok": True,
            "primary_agent_id": primary,
            "reason": base.get("reason"),
            "call": f"agent_run_start(agent_id='{primary}', goal=...)",
            "chain": steps,
            "card": (self.agents.get(primary) or {}).get("card"),
            "super_mode": True,
            "note": "Execute chain in order; skip optional steps only if already satisfied.",
        }


# Process singleton
_ORCH: RamOrchestration | None = None
_ORCH_LOCK = threading.Lock()


def get_orchestration() -> RamOrchestration | None:
    return _ORCH


def ensure_orchestration(conn: sqlite3.Connection, home: Path) -> RamOrchestration:
    global _ORCH
    with _ORCH_LOCK:
        if _ORCH is None:
            _ORCH = RamOrchestration()
            _ORCH.attach(conn, home)
        elif not _ORCH._loaded:  # noqa: SLF001
            _ORCH.attach(conn, home)
        return _ORCH


def set_orchestration(orch: RamOrchestration | None) -> None:
    global _ORCH
    with _ORCH_LOCK:
        _ORCH = orch
