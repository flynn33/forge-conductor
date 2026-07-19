"""Host-driven agent catalog, sessions, and run lifecycle tools."""

from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any

from forge_conductor import audit
from forge_conductor import store
from forge_conductor.agent_runtime import (
    build_context_payload,
    clear_active_session,
    run_complete,
    run_start,
    run_status,
    set_active,
    ActiveAgentBinding,
)
from forge_conductor.agents_loader import AgentSpec, load_agents, recommend_agent
from forge_conductor.config import get_home
from forge_conductor.errors import ToolError


def _home(home: Path | str | None = None) -> Path:
    return Path(home) if home is not None else get_home()


def _resolve_agent_id(
    agent_id: str | None = None,
    *,
    id: str | None = None,
    name: str | None = None,
) -> str:
    """Accept agent_id, id, or name (Claude often passes id/name)."""
    for candidate in (agent_id, id, name):
        if candidate is not None and str(candidate).strip():
            return str(candidate).strip()
    raise ToolError(
        code="missing_agent_id",
        message="Provide agent_id (preferred), or id / name. Example: agent_id='explore'.",
        retryable=True,
        detail={"accepted_params": ["agent_id", "id", "name"]},
    )


def _spec_or_none(home: Path | str | None, agent_id: str) -> AgentSpec | None:
    return load_agents(_home(home)).get(agent_id)


def _require_spec(home: Path | str | None, agent_id: str) -> AgentSpec:
    spec = _spec_or_none(home, agent_id)
    if spec is None:
        available = sorted(load_agents(_home(home)).keys())
        raise ToolError(
            code="agent_not_found",
            message=f"Unknown agent '{agent_id}'. Use agent_list to see ids.",
            retryable=True,
            detail={"agent_id": agent_id, "available": available},
        )
    return spec


def svc_list(home: Path | str | None = None) -> list[dict[str, Any]]:
    """List agents as compact cards (playbook summary, no full body)."""
    agents = load_agents(_home(home))
    return [agents[aid].card() for aid in sorted(agents)]


def svc_get(home: Path | str | None, agent_id: str) -> dict[str, Any]:
    """Return full agent spec including body + playbook."""
    return _require_spec(home, agent_id).to_dict(include_body=True)


def svc_context(home: Path | str | None, agent_id: str) -> dict[str, Any]:
    """Return host-facing playbook + full body (large-context friendly)."""
    spec = _require_spec(home, agent_id)
    return build_context_payload(spec, full_body=True)


def svc_session_start(
    conn: sqlite3.Connection,
    *,
    agent_id: str,
    client_id: str | None = None,
    home: Path | str | None = None,
) -> dict[str, Any]:
    """Start an agent session in the shared store. Validates agent exists."""
    spec = _require_spec(home, agent_id)
    row = store.agent_session_start(conn, agent_id=agent_id, client_id=client_id)
    # Bind soft preference even for legacy session_start
    set_active(
        client_id,
        ActiveAgentBinding(
            session_id=row["id"],
            agent_id=agent_id,
            tools_primary=list(spec.tools),
            tools_forbidden=list(spec.tools_forbidden),
            output_schema=list(spec.output_schema),
            done_definition=list(spec.done_definition),
        ),
    )
    if client_id is not None:
        audit.append(
            conn,
            tool="agent_session_start",
            args={
                "session_id": row["id"],
                "agent_id": agent_id,
                "agent_session_id": row["id"],
            },
            status="ok",
            client_id=client_id,
            mutating=True,
        )
    return {
        "ok": True,
        "session": row,
        "agent": svc_context(home, agent_id),
        "next": (
            "Prefer agent_run_start(goal=...) for structured runs. "
            "Or apply agent.body, use tools_primary, then agent_session_end / agent_run_complete."
        ),
        "token_policy": (
            "Large context host: do not skip sub-agents to save tokens."
        ),
    }


def svc_session_end(
    conn: sqlite3.Connection,
    *,
    session_id: str,
    summary: str | None = None,
    client_id: str | None = None,
) -> dict[str, Any]:
    """End an agent session with optional summary."""
    try:
        row = store.agent_session_end(conn, session_id=session_id, summary=summary)
    except KeyError as exc:
        raise ToolError(
            code="session_not_found",
            message=str(exc),
            retryable=True,
            detail={"session_id": session_id},
        ) from exc
    clear_active_session(client_id, session_id)
    if client_id is not None:
        audit.append(
            conn,
            tool="agent_session_end",
            args={
                "session_id": session_id,
                "summary": summary,
                "agent_session_id": session_id,
            },
            status="ok",
            client_id=client_id,
            mutating=True,
        )
    return {"ok": True, "session": row}


def svc_session_list(
    conn: sqlite3.Connection,
    *,
    agent_id: str | None = None,
    status: str | None = None,
) -> list[dict[str, Any]]:
    """List agent sessions, optionally filtered."""
    return store.agent_session_list(conn, agent_id=agent_id, status=status)


def register(mcp: Any) -> None:
    """Register agent tools (and optional resources/prompts) on *mcp*."""
    from forge_conductor.errors import tool_error_payload
    from forge_conductor.server import TOOL_NAMES, get_ctx
    from forge_conductor.tool_resilience import (
        prune_stale_agent_sessions,
        recover_agent_session,
    )

    def _home_from_ctx() -> Path | None:
        ctx = get_ctx()
        return ctx.home if ctx is not None else None

    def _safe(fn, *args, **kwargs):  # type: ignore[no-untyped-def]
        try:
            return fn(*args, **kwargs)
        except Exception as exc:  # noqa: BLE001
            payload = tool_error_payload(exc)
            payload["ok"] = False
            payload["forge_recovery"] = True
            return payload

    @mcp.tool(
        description=(
            "List host-driven specialists (cards: when_to_use, handoff, tools). "
            "Non-trivial work: agent_run_start(agent_id, goal) — do not skip agents to save tokens."
        )
    )
    def agent_list() -> list[dict[str, Any]] | dict[str, Any]:
        return _safe(svc_list, _home_from_ctx())

    @mcp.tool(
        description=(
            "Recommend the best specialist for a free-text task. "
            "Then call agent_run_start with that agent_id."
        )
    )
    def agent_recommend(task: str) -> dict[str, Any]:
        return _safe(recommend_agent, task, _home_from_ctx())

    @mcp.tool(
        description=(
            "Get full agent spec + playbook by agent_id. "
            "Prefer agent_run_start for real work."
        )
    )
    def agent_get(
        agent_id: str | None = None,
        id: str | None = None,
        name: str | None = None,
    ) -> dict[str, Any]:
        def _run() -> dict[str, Any]:
            aid = _resolve_agent_id(agent_id, id=id, name=name)
            return svc_get(_home_from_ctx(), aid)

        return _safe(_run)

    @mcp.tool(
        description=(
            "Load full specialist playbook + body (when_to_use, first_moves, "
            "done_definition, output_schema, tools_primary/forbidden). "
            "Large context: always load full body — do not skip for token savings. "
            "For multi-step work prefer agent_run_start(agent_id, goal)."
        )
    )
    def agent_context(
        agent_id: str | None = None,
        id: str | None = None,
        name: str | None = None,
    ) -> dict[str, Any]:
        def _run() -> dict[str, Any]:
            aid = _resolve_agent_id(agent_id, id=id, name=name)
            return svc_context(_home_from_ctx(), aid)

        return _safe(_run)

    @mcp.tool(
        description=(
            "PREFERRED for non-trivial work. Start a specialist RUN: session + full "
            "playbook + first_moves + soft tool preference. "
            "Params: agent_id (explore|plan|implement|review|...), goal=what to achieve. "
            "This host has large context — use sub-agents; do not avoid this call to save tokens. "
            "Finish with agent_run_complete(session_id, report)."
        )
    )
    def agent_run_start(
        goal: str,
        agent_id: str | None = None,
        id: str | None = None,
        name: str | None = None,
        cwd: str | None = None,
    ) -> dict[str, Any]:
        def _run() -> dict[str, Any]:
            ctx = get_ctx()
            if ctx is None:
                raise ToolError(
                    code="no_runtime",
                    message="Runtime context not initialized (server not serving).",
                    retryable=True,
                )
            aid = _resolve_agent_id(agent_id, id=id, name=name)
            return run_start(
                ctx.conn,
                agent_id=aid,
                goal=goal,
                client_id=ctx.client_id,
                home=ctx.home,
                cwd=cwd,
            )

        return _safe(_run)

    @mcp.tool(description="Status of an agent run/session (checklist + binding).")
    def agent_run_status(session_id: str) -> dict[str, Any]:
        def _run() -> dict[str, Any]:
            ctx = get_ctx()
            if ctx is None:
                raise ToolError(
                    code="no_runtime",
                    message="Runtime context not initialized.",
                    retryable=True,
                )
            return run_status(
                ctx.conn, session_id=session_id, client_id=ctx.client_id
            )

        return _safe(_run)

    @mcp.tool(
        description=(
            "Complete an agent run. Pass report object with keys from output_schema "
            "(or a summary string). Closes session and clears soft tool preference."
        )
    )
    def agent_run_complete(
        session_id: str,
        report: dict[str, Any] | str | None = None,
    ) -> dict[str, Any]:
        def _run() -> dict[str, Any]:
            ctx = get_ctx()
            if ctx is None:
                raise ToolError(
                    code="no_runtime",
                    message="Runtime context not initialized.",
                    retryable=True,
                )
            return run_complete(
                ctx.conn,
                session_id=session_id,
                report=report,
                client_id=ctx.client_id,
            )

        return _safe(_run)

    @mcp.tool(
        description=(
            "Start a multi-turn agent session ledger (legacy). "
            "Prefer agent_run_start(goal=...) for structured runs."
        )
    )
    def agent_session_start(
        agent_id: str | None = None,
        id: str | None = None,
        name: str | None = None,
    ) -> dict[str, Any]:
        def _run() -> dict[str, Any]:
            ctx = get_ctx()
            if ctx is None:
                raise ToolError(
                    code="no_runtime",
                    message="Runtime context not initialized (server not serving).",
                    retryable=True,
                )
            prune_stale_agent_sessions(ctx.conn, max_age_sec=86_400)
            aid = _resolve_agent_id(agent_id, id=id, name=name)
            try:
                return svc_session_start(
                    ctx.conn,
                    agent_id=aid,
                    client_id=ctx.client_id,
                    home=ctx.home,
                )
            except Exception:
                return recover_agent_session(
                    ctx.conn,
                    agent_id=aid,
                    client_id=ctx.client_id,
                    home=ctx.home,
                )

        return _safe(_run)

    @mcp.tool(
        description=(
            "Close an agent session. Prefer agent_run_complete when you started with agent_run_start."
        )
    )
    def agent_session_end(
        session_id: str,
        summary: str | None = None,
    ) -> dict[str, Any]:
        def _run() -> dict[str, Any]:
            ctx = get_ctx()
            if ctx is None:
                raise ToolError(
                    code="no_runtime",
                    message="Runtime context not initialized (server not serving).",
                    retryable=True,
                )
            return svc_session_end(
                ctx.conn,
                session_id=session_id,
                summary=summary,
                client_id=ctx.client_id,
            )

        return _safe(_run)

    @mcp.tool(description="List agent sessions from the shared ledger.")
    def agent_session_list(
        agent_id: str | None = None,
        status: str | None = None,
    ) -> list[dict[str, Any]] | dict[str, Any]:
        def _run() -> list[dict[str, Any]]:
            ctx = get_ctx()
            if ctx is None:
                raise ToolError(
                    code="no_runtime",
                    message="Runtime context not initialized (server not serving).",
                    retryable=True,
                )
            prune_stale_agent_sessions(ctx.conn, max_age_sec=86_400)
            return svc_session_list(ctx.conn, agent_id=agent_id, status=status)

        return _safe(_run)

    @mcp.tool(
        description=(
            "Recover or re-open an agent session after failure. "
            "Or use agent_run_start for a fresh structured run."
        )
    )
    def agent_session_recover(
        session_id: str | None = None,
        agent_id: str | None = None,
        id: str | None = None,
        name: str | None = None,
    ) -> dict[str, Any]:
        def _run() -> dict[str, Any]:
            ctx = get_ctx()
            if ctx is None:
                raise ToolError(
                    code="no_runtime",
                    message="Runtime context not initialized (server not serving).",
                    retryable=True,
                )
            aid = None
            try:
                if agent_id or id or name:
                    aid = _resolve_agent_id(agent_id, id=id, name=name)
            except ToolError:
                aid = agent_id
            return recover_agent_session(
                ctx.conn,
                session_id=session_id,
                agent_id=aid,
                client_id=ctx.client_id,
                home=ctx.home,
            )

        return _safe(_run)

    TOOL_NAMES.update(
        {
            "agent_list",
            "agent_recommend",
            "agent_get",
            "agent_context",
            "agent_run_start",
            "agent_run_status",
            "agent_run_complete",
            "agent_session_start",
            "agent_session_end",
            "agent_session_list",
            "agent_session_recover",
        }
    )

    try:
        _register_resources_and_prompts(mcp)
    except Exception:
        pass


def _register_resources_and_prompts(mcp: Any) -> None:
    """Register agent://{id} resources and forge-{id} prompts if supported."""
    from forge_conductor.agents_loader import _load_builtins

    @mcp.resource("agent://{agent_id}")
    def agent_resource(agent_id: str) -> str:
        """Markdown body for a built-in or custom agent."""
        from forge_conductor.server import get_ctx

        ctx = get_ctx()
        home = ctx.home if ctx is not None else None
        try:
            spec = _require_spec(home, agent_id)
        except ToolError:
            return f"# Unknown agent\n\nNo agent with id `{agent_id}`. Call agent_list."
        tools_line = ", ".join(spec.tools) if spec.tools else "(none)"
        pb = spec.playbook()
        return (
            f"# {spec.display_name}\n\n"
            f"**id:** {spec.id}\n\n"
            f"**description:** {spec.description}\n\n"
            f"**tools_primary:** {tools_line}\n\n"
            f"**when_to_use:** {', '.join(pb.get('when_to_use') or [])}\n\n"
            f"**first_moves:** {', '.join(pb.get('first_moves') or [])}\n\n"
            f"{spec.body}"
        )

    for agent_id, spec in sorted(_load_builtins().items()):
        prompt_name = f"forge-{agent_id}"
        description = spec.description
        body = (
            f"You are the {spec.display_name} specialist (Forge-Conductor).\n\n"
            f"{spec.description}\n\n"
            f"Playbook first_moves: {', '.join(spec.first_moves)}\n\n"
            f"{spec.body}"
        )

        def _register_one(
            name: str = prompt_name,
            desc: str = description,
            text: str = body,
        ) -> None:
            @mcp.prompt(name=name, description=desc)
            def _prompt() -> str:
                return text

        _register_one()
