"""Meta tools: status, audit tail, config."""

from __future__ import annotations

from typing import Any

from forge_conductor import __version__, audit
from forge_conductor.config import get_home, load_config


def svc_status() -> dict[str, Any]:
    """Return process/status info: version, home, tool_count, client_id, etc."""
    from forge_conductor.resilience import resilience_snapshot
    from forge_conductor.server import TOOL_NAMES, get_ctx

    ctx = get_ctx()
    home = get_home()
    snap = resilience_snapshot()
    hygiene = None
    try:
        from forge_conductor.host_hygiene import scan_lmstudio_log_for_jinja_errors

        hygiene = scan_lmstudio_log_for_jinja_errors(limit=5)
    except Exception:
        hygiene = None
    memory_ram = None
    orchestration_ram = None
    try:
        from forge_conductor.memory_ram import ensure_bank, get_bank
        from forge_conductor.ram_orchestration import ensure_orchestration, get_orchestration

        bank = get_bank()
        if bank is None and ctx is not None:
            bank = ensure_bank(ctx.conn, ctx.home)
        memory_ram = bank.stats() if bank is not None else None
        orch = get_orchestration()
        if orch is None and ctx is not None:
            orch = ensure_orchestration(ctx.conn, ctx.home)
        orchestration_ram = orch.stats() if orch is not None else None
    except Exception:
        memory_ram = None
        orchestration_ram = None
    agent_backend = None
    try:
        from forge_conductor.agent_backend import status_payload

        agent_backend = status_payload(home)
    except Exception:
        agent_backend = None
    return {
        "version": __version__,
        "home": str(home),
        "tool_count": len(TOOL_NAMES),
        "transport": "stdio",
        "unified_surface": True,
        "super_mode": True,
        "packs": [
            "memory",
            "orchestration",
            "meta",
            "inventory",
            "agent_backend",
            "filesystem",
            "shell",
            "git",
            "github_gh",
            "vsbuild",
            "python_exec",
            "search",
            "browser",
            "research",
            "agents",
            "coord",
        ],
        "client_id": ctx.client_id if ctx is not None else None,
        "schema_ready": ctx is not None and ctx.conn is not None,
        "primary_ready": snap.get("primary_ready"),
        "fallback_ready": snap.get("fallback_ready"),
        "resilience": snap.get("redundancy"),
        "host_hygiene_hint": hygiene,
        "memory_ram": memory_ram,
        "orchestration_ram": orchestration_ram,
        "fail_forward": True,
        "agent_backend": agent_backend,
        "hint": (
            "SUPER AGENTS + agent_backend (host|grok). "
            "session_bootstrap first. agent_backend_set to switch HOST/GROK. "
            "When mode=grok: mandatory agent_run_start offload. "
            "plan never writes files → docs|implement."
        ),
    }


def svc_audit_tail(limit: int = 50) -> list[dict[str, Any]]:
    """Return the newest *limit* audit events (requires runtime context)."""
    from forge_conductor.server import get_ctx

    ctx = get_ctx()
    if ctx is None:
        raise RuntimeError("Runtime context not initialized")
    return audit.tail(ctx.conn, limit=limit)


def svc_config_get() -> dict[str, Any]:
    """Return the effective configuration (from runtime ctx or load_config)."""
    from forge_conductor.server import get_ctx

    ctx = get_ctx()
    if ctx is not None and ctx.config is not None:
        return dict(ctx.config)
    return load_config()


def register(mcp: Any) -> None:
    """Register meta tools on *mcp* and record names in TOOL_NAMES."""
    from forge_conductor.server import TOOL_NAMES

    @mcp.tool
    def forge_status() -> dict[str, Any]:
        """Return forge-conductor status (version, home, tool count, client id)."""
        return svc_status()

    @mcp.tool
    def forge_audit_tail(limit: int = 50) -> list[dict[str, Any]]:
        """Return the newest audit events (newest first)."""
        return svc_audit_tail(limit=limit)

    @mcp.tool
    def forge_config_get() -> dict[str, Any]:
        """Return the effective forge-conductor configuration."""
        return svc_config_get()

    @mcp.tool(
        description=(
            "FAIL-FORWARD recovery. Call when ANY tool/host/MCP error occurs. "
            "Classifies the error, runs automatic remediations (e.g. Jinja template patch), "
            "and returns fallback tools/servers/agents + next steps. "
            "Params: error (message text), last_tool, last_agent, goal."
        )
    )
    def fail_forward(
        error: str = "",
        last_tool: str | None = None,
        last_agent: str | None = None,
        goal: str | None = None,
    ) -> dict[str, Any]:
        from forge_conductor.fail_forward import recover

        return recover(
            error=error,
            last_tool=last_tool,
            last_agent=last_agent,
            goal=goal,
            auto=True,
        )

    @mcp.tool(
        description=(
            "Patch host landmines (LM Studio Jinja MCP abort, etc.) and report presence. "
            "Safe to call anytime; also runs automatically via ForgeOrchestrator hygiene loop."
        )
    )
    def host_hygiene() -> dict[str, Any]:
        from forge_conductor.host_hygiene import run_hygiene

        return run_hygiene()

    TOOL_NAMES.update(
        {
            "forge_status",
            "forge_audit_tail",
            "forge_config_get",
            "fail_forward",
            "host_hygiene",
        }
    )
