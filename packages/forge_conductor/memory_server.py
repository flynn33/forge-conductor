"""Standalone RAM Memory MCP server (stdio) for LM Studio visibility.

Shares the same RamMemoryBank + store.sqlite + memory_corpus.json as
forge-conductor. Appears as a separate toggle: mcp/ram-memory.
"""

from __future__ import annotations

import logging
import os
import sys
import uuid
from pathlib import Path
from typing import Any

from fastmcp import FastMCP

from forge_conductor import __version__

TOOL_NAMES: set[str] = set()
_ctx: Any = None


def get_ctx() -> Any:
    return _ctx


def build_memory_mcp() -> FastMCP:
    """Register only memory / project / handoff tools."""
    TOOL_NAMES.clear()
    mcp = FastMCP(
        name="ram-memory",
        version=__version__,
        # Human-facing identity for hosts that show server name
    )

    from forge_conductor.tools import memory as memory_tools

    # Reuse the same tool registrations (writes TOOL_NAMES via memory.register)
    # memory.register imports get_ctx from forge_conductor.server — patch below.
    memory_tools.register(mcp)

    # Override TOOL_NAMES tracking: memory.register updates server.TOOL_NAMES
    from forge_conductor.server import TOOL_NAMES as SERVER_TOOL_NAMES

    TOOL_NAMES.update(SERVER_TOOL_NAMES)

    @mcp.tool
    def ram_status() -> dict[str, Any]:
        """RAM Memory MCP health: note count, bytes, backup paths, loaded flag."""
        from forge_conductor.memory_ram import ensure_bank, get_bank
        from forge_conductor.config import get_home

        bank = get_bank()
        if bank is None and _ctx is not None:
            bank = ensure_bank(_ctx.conn, _ctx.home)
        stats = bank.stats() if bank is not None else {"loaded": False}
        return {
            "ok": True,
            "server": "ram-memory",
            "version": __version__,
            "role": "RAM Memory MCP (full corpus in process RAM; disk backup)",
            "home": str(get_home()),
            "tool_count": len(TOOL_NAMES),
            "tools": sorted(TOOL_NAMES),
            "memory": stats,
            "shared_with": "forge-conductor (same store.sqlite + memory_corpus.json)",
            "hint": (
                "Use project_focus / handoff_save / memory_* here for continuity. "
                "Same corpus as forge-conductor memory tools."
            ),
        }

    TOOL_NAMES.add("ram_status")
    try:
        SERVER_TOOL_NAMES.add("ram_status")
    except Exception:
        pass

    return mcp


def run_memory_stdio() -> None:
    """Initialize shared store, load full corpus into RAM, serve on stdio."""
    global _ctx

    logging.basicConfig(level=logging.ERROR, stream=sys.stderr)
    for name in ("mcp", "mcp.server", "fastmcp", "uvicorn", "httpx"):
        logging.getLogger(name).setLevel(logging.ERROR)

    from forge_conductor.config import ensure_home, load_config
    from forge_conductor.memory_ram import ensure_bank
    from forge_conductor.store import connect, migrate
    from forge_conductor.server import RuntimeContext
    import forge_conductor.server as server_mod

    home = ensure_home()
    conn = connect()
    migrate(conn)
    bank = ensure_bank(conn, home)
    try:
        from forge_conductor.ram_orchestration import ensure_orchestration

        ensure_orchestration(conn, home)
    except Exception:
        pass
    try:
        load_stats = bank.stats() if bank is not None else {}
    except Exception:
        load_stats = {}
    config = load_config()
    client_id = str(uuid.uuid4())

    # Presence heartbeat so telemetry dashboard lists ram-memory as a live MCP.
    # Use a longer presence TTL so dashboard doesn't flap if reclaim races.
    from forge_conductor.coordinator import Coordinator

    coord_cfg = config.get("coordinator") or {}
    lease_ttl = int(coord_cfg.get("lease_ttl_sec", 60))
    presence_ttl = max(int(coord_cfg.get("presence_ttl_sec", 30)), 90)
    coordinator = Coordinator(
        conn,
        client_id=client_id,
        lease_ttl_sec=lease_ttl,
        presence_ttl_sec=presence_ttl,
    )
    role_cwd = str(home / "mcp-role" / "memory")
    try:
        Path(role_cwd).mkdir(parents=True, exist_ok=True)
    except OSError:
        role_cwd = str(home)
    # Always register presence (dashboard depends on it)
    try:
        coordinator.register_presence(
            host_kind="mcp/ram-memory",
            pid=os.getpid(),
            cwd=role_cwd,
        )
        coordinator.start_heartbeat()
    except Exception as exc:  # noqa: BLE001
        try:
            log_dir = home / "logs"
            log_dir.mkdir(parents=True, exist_ok=True)
            with (log_dir / "ram-memory.log").open("a", encoding="utf-8") as fh:
                fh.write(f"presence_register_failed: {exc}\n")
        except OSError:
            pass

    # Share RuntimeContext so memory tools' get_ctx() works
    _ctx = RuntimeContext(
        conn=conn,
        client_id=client_id,
        config=config,
        home=home,
        coordinator=coordinator,
    )
    server_mod._ctx = _ctx  # noqa: SLF001 — intentional shared ctx for tools

    # Continuity atexit / LM Studio folder focus
    try:
        from forge_conductor.continuity_auto import start_background_tasks

        start_background_tasks()
    except Exception:
        pass

    # Log load to home (not stdout — stdio is MCP)
    try:
        log_dir = home / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        with (log_dir / "ram-memory.log").open("a", encoding="utf-8") as fh:
            fh.write(
                f"start pid={os.getpid()} notes={load_stats.get('note_count')} "
                f"load_ms={load_stats.get('load_ms')} approx_bytes={load_stats.get('approx_bytes')}\n"
            )
    except OSError:
        pass

    mcp = build_memory_mcp()
    try:
        mcp.run(transport="stdio", show_banner=False)
    except TypeError:
        mcp.run(transport="stdio")
