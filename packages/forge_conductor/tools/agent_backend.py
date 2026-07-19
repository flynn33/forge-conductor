"""MCP tools for agent backend mode (host vs grok)."""

from __future__ import annotations

from typing import Any


def register(mcp: Any) -> None:
    from forge_conductor.server import TOOL_NAMES

    @mcp.tool(
        description=(
            "Agent backend status: mode=host|grok, generation, policy, worker health. "
            "Call after session_bootstrap. When mode=grok, offload via agent_run_start is MANDATORY."
        )
    )
    def agent_backend_status() -> dict[str, Any]:
        from forge_conductor.agent_backend import status_payload
        from forge_conductor.config import get_home

        return status_payload(get_home())

    @mcp.tool(
        description=(
            "Switch agent backend: mode='host' (local Qwen runs agents) or mode='grok' "
            "(external Grok runs agents; local model is router only). "
            "Notifies LM Studio presets/prompts. Operator or model may call."
        )
    )
    def agent_backend_set(
        mode: str,
        reason: str | None = None,
        notify: bool = True,
    ) -> dict[str, Any]:
        from forge_conductor.agent_backend import set_mode, status_payload
        from forge_conductor.config import get_home
        from forge_conductor.server import get_ctx

        try:
            ctx = get_ctx()
            by = f"mcp:{ctx.client_id[:8]}" if ctx else "mcp"
            st = set_mode(
                mode,
                home=get_home(),
                changed_by=by,
                reason=reason,
                notify=bool(notify),
            )
            out = status_payload(get_home())
            out["set_result"] = {
                "mode": st.get("mode"),
                "generation": st.get("generation"),
                "notify_result": st.get("notify_result"),
            }
            out["ok"] = True
            out["message"] = (
                f"Agent backend set to {st.get('mode')} (generation={st.get('generation')}). "
                "Open a NEW LM Studio chat so the system prompt refreshes; "
                "enforcement is active immediately via MCP middleware."
            )
            return out
        except Exception as exc:  # noqa: BLE001
            return {"ok": False, "error": str(exc), "retryable": True}

    @mcp.tool(
        description="Ping Grok agent worker (heartbeat + API key configured)."
    )
    def agent_backend_worker_ping() -> dict[str, Any]:
        from forge_conductor.agent_backend import worker_ping
        from forge_conductor.config import get_home

        return worker_ping(get_home())

    TOOL_NAMES.update(
        {
            "agent_backend_status",
            "agent_backend_set",
            "agent_backend_worker_ping",
        }
    )
