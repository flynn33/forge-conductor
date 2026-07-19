"""Automatic cross-chat continuity (project focus + handoff + bootstrap inject).

Runs inside Forge so the host model does not have to remember the protocol.
"""

from __future__ import annotations

import json
import os
import re
import threading
import time
from collections import deque
from pathlib import Path
from typing import Any

from forge_conductor.memory_ram import (
    KEY_ACTIVE_PROJECT,
    KEY_CONTINUITY_LATEST,
    continuity_snapshot,
    ensure_bank,
    get_bank,
)

# Tools whose args often carry a workspace path
_PATH_ARG_KEYS = (
    "path",
    "cwd",
    "project",
    "file",
    "directory",
    "dir",
    "root",
    "repo",
    "target",
    "src",
    "dst",
    "source",
    "destination",
)

_SKIP_AUTO_HANDOFF_TOOLS = {
    "handoff_save",
    "handoff_load",
    "memory_flush",
    "memory_stats",
    "project_current",
    "forge_status",
    "session_bootstrap",
    "inventory_tools",
}

_lock = threading.RLock()
_bootstrap_seen = False
_tool_events: deque[dict[str, Any]] = deque(maxlen=40)
_last_handoff_ts = 0.0
_last_focus_slug: str | None = None
_tool_count_since_handoff = 0
_started = False

# Auto handoff cadence
HANDOFF_EVERY_TOOLS = 8
HANDOFF_MIN_INTERVAL_SEC = 90.0


def _now() -> float:
    return time.time()


def _bank_for_ctx() -> Any | None:
    try:
        from forge_conductor.server import get_ctx

        ctx = get_ctx()
        if ctx is None:
            return get_bank()
        return get_bank() or ensure_bank(ctx.conn, ctx.home)
    except Exception:
        return get_bank()


def mark_bootstrap() -> None:
    global _bootstrap_seen
    with _lock:
        _bootstrap_seen = True


def bootstrap_seen() -> bool:
    with _lock:
        return _bootstrap_seen


def note_tool(tool: str, arguments: Any = None) -> None:
    with _lock:
        _tool_events.append(
            {
                "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "tool": tool,
                "args_preview": _args_preview(arguments),
            }
        )


def _args_preview(arguments: Any, limit: int = 180) -> str:
    try:
        if arguments is None:
            return ""
        if hasattr(arguments, "model_dump"):
            arguments = arguments.model_dump()
        elif hasattr(arguments, "dict"):
            arguments = arguments.dict()
        text = json.dumps(arguments, default=str, ensure_ascii=False)
        return text[:limit]
    except Exception:
        return str(arguments)[:limit]


def _extract_paths(arguments: Any) -> list[str]:
    paths: list[str] = []
    try:
        if arguments is None:
            return paths
        if hasattr(arguments, "model_dump"):
            arguments = arguments.model_dump()
        elif hasattr(arguments, "dict"):
            arguments = arguments.dict()
        if not isinstance(arguments, dict):
            return paths
        for k, v in arguments.items():
            kl = str(k).lower()
            if kl in _PATH_ARG_KEYS or kl.endswith("_path") or kl.endswith("_dir"):
                if isinstance(v, str) and v.strip():
                    paths.append(v.strip())
            elif isinstance(v, str) and len(v) > 2 and (":\\" in v or v.startswith("/")):
                # Absolute-ish path heuristic
                if any(x in v for x in ("\\", "/")) and not v.startswith("http"):
                    paths.append(v)
    except Exception:
        return paths
    return paths


def _git_root(start: Path) -> Path | None:
    try:
        p = start.expanduser()
        if p.is_file():
            p = p.parent
        p = p.resolve()
    except Exception:
        return None
    for cur in [p, *p.parents]:
        try:
            if (cur / ".git").exists():
                return cur
        except Exception:
            continue
        # don't walk forever on weird mounts
        if len(cur.parts) <= 1:
            break
    return None


def _slugify(name: str) -> str:
    s = (name or "").strip().lower()
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return s or "unnamed"


def _active_slug(bank: Any) -> str | None:
    row = bank.get(KEY_ACTIVE_PROJECT)
    if not row:
        return None
    try:
        return _slugify(json.loads(row["body"]).get("name") or "")
    except Exception:
        return None


def auto_project_focus_from_path(path: str, *, reason: str = "path") -> dict[str, Any] | None:
    """If path maps to a git repo (or known root), set project/active when changed."""
    global _last_focus_slug
    bank = _bank_for_ctx()
    if bank is None:
        return None
    try:
        p = Path(path)
    except Exception:
        return None
    root = _git_root(p)
    if root is None:
        # still allow direct known folders
        if p.is_dir():
            root = p.resolve()
        else:
            return None

    name = root.name
    slug = _slugify(name)
    cur = _active_slug(bank)
    if cur == slug and _last_focus_slug == slug:
        return None

    # Prefer richer summary if card already exists
    existing = bank.get(f"project/{slug}")
    summary = f"Auto-focused from {reason}: {root}"
    notes = "Set automatically by Forge continuity_auto (path activity)."
    if existing:
        try:
            card = json.loads(existing["body"])
            summary = card.get("summary") or summary
            notes = card.get("notes") or notes
            name = card.get("name") or name
        except Exception:
            pass

    try:
        from forge_conductor.config import get_home
        from forge_conductor.server import get_ctx
        from forge_conductor.store import connect, migrate
        from forge_conductor.tools import memory as mem

        ctx = get_ctx()
        if ctx is not None:
            conn = ctx.conn
            client_id = ctx.client_id or "continuity-auto"
            ensure_bank(conn, ctx.home)
        else:
            conn = connect()
            migrate(conn)
            ensure_bank(conn, get_home())
            client_id = "continuity-auto"

        result = mem.svc_project_focus(
            conn,
            name=name,
            path=str(root),
            summary=summary,
            notes=notes,
            client_id=client_id,
        )
        with _lock:
            _last_focus_slug = slug
        return {"auto_project_focus": result, "reason": reason}
    except Exception as exc:
        return {"auto_project_focus_error": str(exc), "path": str(root)}


def _summarize_recent() -> tuple[str, str, str]:
    with _lock:
        events = list(_tool_events)
    if not events:
        return (
            "Session active; no tool events recorded yet.",
            "Continue from continuity/latest and active project.",
            "",
        )
    tools = [e["tool"] for e in events[-12:]]
    summary = (
        f"Auto-handoff after tools: {', '.join(tools[-8:])}. "
        f"Recent activity count={len(events)}."
    )
    next_steps = (
        "On new chat: session_bootstrap (continuity is auto-injected). "
        "Resume active_project; continue unfinished tool goals."
    )
    files = []
    for e in events:
        prev = e.get("args_preview") or ""
        # crude path scrape
        for m in re.findall(r"[A-Za-z]:\\\\[^\\\"']+|/[^\s\\\"']+", prev):
            files.append(m.replace("\\\\", "\\"))
    working = "; ".join(dict.fromkeys(files) )[:500]
    return summary, next_steps, working


def auto_handoff(reason: str = "activity") -> dict[str, Any] | None:
    """Persist continuity/latest from recent tool activity."""
    global _last_handoff_ts, _tool_count_since_handoff
    bank = _bank_for_ctx()
    if bank is None:
        return None

    summary, next_steps, working = _summarize_recent()
    project = ""
    active = bank.get(KEY_ACTIVE_PROJECT)
    if active:
        try:
            project = json.loads(active["body"]).get("name") or ""
        except Exception:
            project = ""

    try:
        from forge_conductor.server import get_ctx
        from forge_conductor.tools import memory as mem

        ctx = get_ctx()
        if ctx is None:
            return None
        result = mem.svc_handoff_save(
            ctx.conn,
            summary=f"[{reason}] {summary}",
            next_steps=next_steps,
            blockers="",
            working_files=working,
            project=project,
            extra="auto=true",
            client_id=ctx.client_id or "continuity-auto",
        )
        with _lock:
            _last_handoff_ts = _now()
            _tool_count_since_handoff = 0
        return result
    except Exception as exc:
        return {"ok": False, "error": str(exc), "reason": reason}


def maybe_auto_handoff(tool: str) -> dict[str, Any] | None:
    if tool in _SKIP_AUTO_HANDOFF_TOOLS:
        return None
    global _tool_count_since_handoff
    with _lock:
        _tool_count_since_handoff += 1
        count = _tool_count_since_handoff
        elapsed = _now() - _last_handoff_ts
    if count >= HANDOFF_EVERY_TOOLS and elapsed >= HANDOFF_MIN_INTERVAL_SEC:
        return auto_handoff(reason=f"every_{HANDOFF_EVERY_TOOLS}_tools")
    return None


def _inject_into_result(result: Any, extra: dict[str, Any]) -> Any:
    """Attach forge_auto_continuity onto structured tool results when possible."""
    if not extra:
        return result
    try:
        from fastmcp.tools.base import ToolResult
    except Exception:
        ToolResult = None  # type: ignore[misc, assignment]

    sc = getattr(result, "structured_content", None)
    if isinstance(sc, dict):
        sc2 = dict(sc)
        sc2["forge_auto_continuity"] = extra
        if ToolResult is not None and isinstance(result, ToolResult):
            return ToolResult(
                content=getattr(result, "content", None),
                structured_content=sc2,
                meta=getattr(result, "meta", None),
                is_error=getattr(result, "is_error", False),
            )
        return result

    # plain dict returned by some paths
    if isinstance(result, dict):
        out = dict(result)
        out["forge_auto_continuity"] = extra
        return out
    return result


def process_tool_result(tool: str, arguments: Any, result: Any) -> Any:
    """Main hook after a successful (or soft) tool call."""
    global _bootstrap_seen
    note_tool(tool, arguments)
    extra: dict[str, Any] = {"tool": tool, "auto": True}

    if tool in ("session_bootstrap", "inventory_tools"):
        mark_bootstrap()
        extra["bootstrap"] = "explicit"
        # still refresh auto handoff clock lightly
        return _inject_into_result(result, extra)

    bank = _bank_for_ctx()
    injected = False
    with _lock:
        seen = _bootstrap_seen
    if not seen and bank is not None:
        # Virtual bootstrap: inject continuity so new chats don't start blank
        try:
            snap = continuity_snapshot(bank)
            extra["bootstrap"] = "auto_injected"
            extra["continuity"] = {
                "active_project": snap.get("active_project"),
                "handoff": snap.get("handoff"),
                "active_project_name": None,
                "protocol": snap.get("protocol"),
                "memory_stats": snap.get("memory_stats"),
            }
            if snap.get("active_project"):
                try:
                    extra["continuity"]["active_project_name"] = json.loads(
                        snap["active_project"]["body"]
                    ).get("name")
                except Exception:
                    pass
            injected = True
            mark_bootstrap()
        except Exception as exc:
            extra["bootstrap_error"] = str(exc)

    # Auto project from paths in args
    focus_info = None
    for path in _extract_paths(arguments):
        focus_info = auto_project_focus_from_path(path, reason=f"tool:{tool}")
        if focus_info:
            break
    if focus_info:
        extra["project"] = focus_info

    # Periodic auto handoff
    hand = maybe_auto_handoff(tool)
    if hand:
        extra["handoff_saved"] = {
            "ok": hand.get("ok", True) if isinstance(hand, dict) else True,
            "archive_key": hand.get("archive_key") if isinstance(hand, dict) else None,
        }

    if injected or focus_info or hand:
        return _inject_into_result(result, extra)
    return result


def start_background_tasks() -> None:
    """Idempotent: atexit handoff + optional LM Studio project dir focus."""
    global _started, _last_handoff_ts
    with _lock:
        if _started:
            return
        _started = True
        _last_handoff_ts = _now()

    import atexit

    def _on_exit() -> None:
        try:
            auto_handoff(reason="mcp_process_exit")
            bank = _bank_for_ctx()
            if bank is not None:
                bank.flush_backup()
        except Exception:
            pass

    atexit.register(_on_exit)

    # Best-effort: LM Studio selected conversation directory → project focus
    try:
        cfg = Path.home() / ".lmstudio" / ".internal" / "conversation-config.json"
        if cfg.is_file():
            data = json.loads(cfg.read_text(encoding="utf-8"))
            selected_dir = data.get("selectedDirectory") or ""
            # Optional: FORGE_PROJECTS_ROOT/<folder> when LM Studio folder name matches a checkout
            projects_root = os.environ.get("FORGE_PROJECTS_ROOT") or ""
            if selected_dir and selected_dir not in (".", "") and projects_root:
                candidate = Path(projects_root) / selected_dir
                if candidate.is_dir():
                    auto_project_focus_from_path(str(candidate), reason="lmstudio_folder")
    except Exception:
        pass

    # Ensure handoff exists so first inject is never empty
    try:
        bank = _bank_for_ctx()
        if bank is not None and bank.get(KEY_CONTINUITY_LATEST) is None:
            auto_handoff(reason="startup_seed")
    except Exception:
        pass
