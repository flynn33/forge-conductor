"""RAM orchestration tools: status, flush, super chain recommend."""

from __future__ import annotations

from typing import Any


def register(mcp: Any) -> None:
    from forge_conductor.server import TOOL_NAMES, get_ctx

    @mcp.tool
    def orchestration_status() -> dict[str, Any]:
        """RAM orchestration layer stats: agents, sessions, docs, memory, backup paths."""
        from forge_conductor.ram_orchestration import ensure_orchestration, get_orchestration

        ctx = get_ctx()
        if ctx is None:
            raise RuntimeError("Runtime context not initialized")
        orch = get_orchestration() or ensure_orchestration(ctx.conn, ctx.home)
        return {"ok": True, "super_mode": True, **orch.stats()}

    @mcp.tool
    def orchestration_flush() -> dict[str, Any]:
        """Force full RAM orchestration + memory backup to disk JSON/SQLite."""
        from forge_conductor.ram_orchestration import ensure_orchestration, get_orchestration

        ctx = get_ctx()
        if ctx is None:
            raise RuntimeError("Runtime context not initialized")
        orch = get_orchestration() or ensure_orchestration(ctx.conn, ctx.home)
        return orch.flush_backup()

    @mcp.tool
    def orchestration_reload() -> dict[str, Any]:
        """Reload agents/sessions/docs/audit from disk into RAM (after custom agent edits)."""
        from forge_conductor.ram_orchestration import ensure_orchestration, get_orchestration

        ctx = get_ctx()
        if ctx is None:
            raise RuntimeError("Runtime context not initialized")
        orch = get_orchestration() or ensure_orchestration(ctx.conn, ctx.home)
        return {"ok": True, **orch.reload(reason="tool_reload")}

    @mcp.tool
    def agent_chain_recommend(task: str) -> dict[str, Any]:
        """Recommend a SUPER multi-agent chain for a task (primary + ordered handoffs)."""
        from forge_conductor.ram_orchestration import ensure_orchestration, get_orchestration

        ctx = get_ctx()
        if ctx is None:
            raise RuntimeError("Runtime context not initialized")
        orch = get_orchestration() or ensure_orchestration(ctx.conn, ctx.home)
        return orch.recommend_chain(task)

    TOOL_NAMES.update(
        {
            "orchestration_status",
            "orchestration_flush",
            "orchestration_reload",
            "agent_chain_recommend",
        }
    )
