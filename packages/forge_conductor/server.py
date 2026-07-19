"""FastMCP server skeleton: runtime context, tool registration, stdio serve."""

from __future__ import annotations

import os
import sqlite3
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any

from fastmcp import FastMCP

from forge_conductor import __version__

if TYPE_CHECKING:
    from forge_conductor.coordinator import Coordinator

TOOL_NAMES: set[str] = set()

_ctx: RuntimeContext | None = None


@dataclass
class RuntimeContext:
    """Process-level runtime state shared by MCP tools."""

    conn: sqlite3.Connection
    client_id: str
    config: dict[str, Any]
    home: Path
    coordinator: Coordinator | None = field(default=None)


def get_ctx() -> RuntimeContext | None:
    """Return the current runtime context, or None if not serving."""
    return _ctx


def build_mcp() -> FastMCP:
    """Create a FastMCP app and register tool packs; populate TOOL_NAMES."""
    TOOL_NAMES.clear()
    mcp = FastMCP(name="forge-conductor", version=__version__)

    from forge_conductor.tools import (
        agent_backend,
        agents,
        browser,
        coord,
        filesystem,
        git,
        github_gh,
        inventory,
        memory,
        meta,
        orchestration,
        python_exec,
        research,
        search,
        shell,
        vsbuild,
    )

    # Core packs
    memory.register(mcp)
    orchestration.register(mcp)
    meta.register(mcp)
    inventory.register(mcp)
    agent_backend.register(mcp)
    filesystem.register(mcp)
    shell.register(mcp)
    git.register(mcp)
    search.register(mcp)
    # Consolidated former standalone MCPs (single stdio surface for LM Studio)
    github_gh.register(mcp)
    vsbuild.register(mcp)
    python_exec.register(mcp)
    # Optional / heavier
    browser.register(mcp)
    research.register(mcp)
    agents.register(mcp)
    coord.register(mcp)

    # Global soft-error / retry / circuit middleware for ALL tools
    try:
        from forge_conductor.tool_resilience import install_tool_resilience

        install_tool_resilience(mcp)
    except Exception:  # noqa: BLE001 — never block serve if middleware fails
        pass

    return mcp


def run_stdio() -> None:
    """Initialize home/store/context and run the MCP server on stdio only."""
    global _ctx

    import logging
    import sys

    # Quiet stderr — hosts often treat log noise as process errors
    logging.basicConfig(level=logging.ERROR, stream=sys.stderr)
    for name in ("mcp", "mcp.server", "fastmcp", "uvicorn", "httpx"):
        logging.getLogger(name).setLevel(logging.ERROR)

    from forge_conductor.config import ensure_home, load_config
    from forge_conductor.coordinator import Coordinator
    from forge_conductor.store import connect, migrate

    home = ensure_home()
    conn = connect()
    migrate(conn)
    # RAM-first memory + full orchestration layer (agents, sessions, docs, audit).
    # SQLite + JSON corpus files are durable backups on this high-RAM rig.
    from forge_conductor.memory_ram import ensure_bank
    from forge_conductor.ram_orchestration import ensure_orchestration

    ensure_bank(conn, home)
    ensure_orchestration(conn, home)
    config = load_config()
    client_id = str(uuid.uuid4())
    coord_cfg = config.get("coordinator") or {}
    lease_ttl = int(coord_cfg.get("lease_ttl_sec", 60))
    presence_ttl = int(coord_cfg.get("presence_ttl_sec", 30))
    coordinator = Coordinator(
        conn,
        client_id=client_id,
        lease_ttl_sec=lease_ttl,
        presence_ttl_sec=presence_ttl,
    )
    if coord_cfg.get("enabled", True):
        # Tag presence for dashboard labels (primary vs fallback vs memory)
        role = (os.environ.get("FORGE_MCP_ROLE") or "primary").strip().lower()
        host_kind = f"mcp/{role}" if role else "mcp"
        role_cwd = str(home / "mcp-role" / role)
        try:
            Path(role_cwd).mkdir(parents=True, exist_ok=True)
        except OSError:
            role_cwd = str(Path.cwd())
        coordinator.register_presence(
            host_kind=host_kind,
            pid=os.getpid(),
            cwd=role_cwd,
        )
        coordinator.start_heartbeat()
    _ctx = RuntimeContext(
        conn=conn,
        client_id=client_id,
        config=config,
        home=home,
        coordinator=coordinator,
    )
    # After ctx exists: auto project focus / handoff / atexit backup
    try:
        from forge_conductor.continuity_auto import start_background_tasks

        start_background_tasks()
    except Exception:
        pass
    mcp = build_mcp()
    # Critical: never print FastMCP banner on stdout (corrupts MCP stdio).
    try:
        mcp.run(transport="stdio", show_banner=False)
    except TypeError:
        mcp.run(transport="stdio")
