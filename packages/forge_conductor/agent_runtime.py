"""Active agent run state, soft tool preference, run lifecycle helpers."""

from __future__ import annotations

import json
import threading
from dataclasses import dataclass, field
from typing import Any

from forge_conductor.agents_loader import AgentSpec, load_agents, recommend_agent
from forge_conductor.errors import ToolError, tool_error_payload

_lock = threading.Lock()


@dataclass
class ActiveAgentBinding:
    session_id: str
    agent_id: str
    goal: str = ""
    tools_primary: list[str] = field(default_factory=list)
    tools_forbidden: list[str] = field(default_factory=list)
    output_schema: list[str] = field(default_factory=list)
    done_definition: list[str] = field(default_factory=list)
    cwd: str | None = None


# client_id → binding
_ACTIVE: dict[str, ActiveAgentBinding] = {}


def set_active(client_id: str | None, binding: ActiveAgentBinding | None) -> None:
    if not client_id:
        return
    with _lock:
        if binding is None:
            _ACTIVE.pop(client_id, None)
        else:
            _ACTIVE[client_id] = binding


def get_active(client_id: str | None) -> ActiveAgentBinding | None:
    if not client_id:
        return None
    with _lock:
        return _ACTIVE.get(client_id)


def clear_active_session(client_id: str | None, session_id: str | None = None) -> None:
    if not client_id:
        return
    with _lock:
        cur = _ACTIVE.get(client_id)
        if cur is None:
            return
        if session_id is None or cur.session_id == session_id:
            _ACTIVE.pop(client_id, None)


def _run_key(session_id: str) -> str:
    return f"agent_run/{session_id}"


def _save_run(conn: Any, session_id: str, state: dict[str, Any]) -> None:
    from forge_conductor import store

    store.memory_set(
        conn,
        key=_run_key(session_id),
        body=json.dumps(state, sort_keys=True),
        tags=["agent_run", state.get("agent_id") or ""],
    )


def _load_run(conn: Any, session_id: str) -> dict[str, Any] | None:
    from forge_conductor import store

    row = store.memory_get(conn, _run_key(session_id))
    if not row:
        return None
    try:
        return json.loads(row["body"])
    except (json.JSONDecodeError, TypeError, KeyError):
        return None


def build_context_payload(spec: AgentSpec, *, full_body: bool = True) -> dict[str, Any]:
    """Structured playbook + instructions for the host model."""
    data = {
        "ok": True,
        "id": spec.id,
        "display_name": spec.display_name,
        "description": spec.description,
        "source": spec.source,
        "tools": list(spec.tools),
        "playbook": spec.playbook(),
        "token_policy": (
            "This host uses a large context window. Do NOT conserve tokens by "
            "skipping specialists. Prefer agent_run_start / agent_context over "
            "token thrift. Sub-agent quality > short prompts."
        ),
        "usage": (
            "You are now the host-driven specialist. Apply body as role instructions, "
            "prefer tools_primary, avoid tools_forbidden unless necessary (soft preference). "
            "Work until done_definition; then agent_run_complete with a report matching output_schema."
        ),
    }
    if full_body:
        data["body"] = spec.body
    return data


def run_start(
    conn: Any,
    *,
    agent_id: str,
    goal: str,
    client_id: str | None = None,
    home: Any = None,
    cwd: str | None = None,
) -> dict[str, Any]:
    """Start session + bind active playbook + persist run state."""
    from forge_conductor import audit
    from forge_conductor import store
    from forge_conductor.tool_resilience import prune_stale_agent_sessions

    agents = load_agents(home)
    spec = agents.get(agent_id)
    if spec is None:
        raise ToolError(
            "agent_not_found",
            f"Unknown agent '{agent_id}'",
            retryable=True,
            detail={"available": sorted(agents.keys())},
        )

    prune_stale_agent_sessions(conn, max_age_sec=86_400)
    row = store.agent_session_start(conn, agent_id=agent_id, client_id=client_id)

    # SUPER agents: inject full RAM orchestration context (project, memory, prior runs)
    super_context: dict[str, Any] | None = None
    suggested_chain: list[dict[str, str]] = []
    try:
        from forge_conductor.ram_orchestration import ensure_orchestration, get_orchestration

        orch = get_orchestration()
        if orch is None:
            from forge_conductor.config import get_home

            orch = ensure_orchestration(conn, home or get_home())
        super_context = orch.build_super_context(
            agent_id=agent_id, goal=goal or "", cwd=cwd
        )
        suggested_chain = list(super_context.get("suggested_chain") or [])
        orch.refresh_session(row)
    except Exception:
        super_context = None

    # Backend dispatch: host (local model) vs grok (external worker)
    executor = "host"
    try:
        from forge_conductor.agent_backend import get_mode

        executor = get_mode(home)
    except Exception:
        executor = "host"

    binding = ActiveAgentBinding(
        session_id=row["id"],
        agent_id=agent_id,
        goal=goal or "",
        tools_primary=list(spec.tools),
        tools_forbidden=list(spec.tools_forbidden),
        output_schema=list(spec.output_schema),
        done_definition=list(spec.done_definition),
        cwd=cwd,
    )
    set_active(client_id, binding)

    state = {
        "session_id": row["id"],
        "agent_id": agent_id,
        "goal": goal or "",
        "cwd": cwd,
        "status": "running",
        "executor": executor,
        "checklist": [
            {"item": d, "done": False} for d in (spec.done_definition or [])
        ],
        "first_moves": list(spec.first_moves),
        "output_schema": list(spec.output_schema),
    }
    job_meta: dict[str, Any] | None = None
    if executor == "grok":
        try:
            from forge_conductor.agent_jobs import enqueue_agent_job

            job_meta = enqueue_agent_job(
                conn,
                session_id=row["id"],
                agent_id=agent_id,
                goal=goal or "",
                payload={
                    "cwd": cwd,
                    "super_context": super_context,
                    "tools_primary": list(spec.tools),
                    "tools_forbidden": list(spec.tools_forbidden),
                    "output_schema": list(spec.output_schema),
                },
                owner_client_id=client_id,
            )
            state["job_id"] = job_meta.get("id")
            state["executor"] = "grok"
        except Exception as exc:  # noqa: BLE001
            state["executor"] = "host"
            executor = "host"
            state["grok_enqueue_error"] = str(exc)

    _save_run(conn, row["id"], state)

    if client_id is not None:
        audit.append(
            conn,
            tool="agent_run_start",
            args={
                "session_id": row["id"],
                "agent_id": agent_id,
                "goal": goal,
                "agent_session_id": row["id"],
                "executor": executor,
            },
            status="ok",
            client_id=client_id,
            mutating=True,
        )

    ctx = build_context_payload(spec, full_body=True)

    if executor == "grok":
        return {
            "ok": True,
            "super_mode": True,
            "executor": "grok",
            "mode": "grok",
            "session": row,
            "session_id": row["id"],
            "goal": goal or "",
            "cwd": cwd,
            "job": job_meta,
            "super_context": super_context,
            "suggested_chain": suggested_chain,
            "poll": "agent_run_status",
            "next": [
                "EXECUTOR=GROK BUILD — do NOT run the playbook yourself.",
                f"Poll agent_run_status(session_id='{row['id']}') until status completed/failed.",
                "Then summarize the report for the user.",
                "Do not call fs_write/shell/git mutators; middleware will block them.",
            ],
            "host_must_not_execute_playbook": True,
            "soft_tool_preference": False,
            "message": (
                "Agent job queued for Grok Build (operator session). "
                "You are the local router only."
            ),
        }

    next_steps = [
        "You are a SUPER agent — read super_context before acting",
        "Adopt agent.body + playbook as role instructions",
        "Use related_memory / handoff / active_project (do not re-discover blindly)",
        "Execute first_moves (adapt to goal)",
        "Prefer tools_primary; avoid tools_forbidden unless essential",
        "When done_definition met: agent_run_complete(session_id, report={...output_schema})",
    ]
    if suggested_chain:
        nxt = suggested_chain[0]
        next_steps.append(
            f"MANDATORY HANDOFF after complete: {nxt.get('call')} — {nxt.get('why')}"
        )

    return {
        "ok": True,
        "super_mode": True,
        "executor": "host",
        "mode": "host",
        "session": row,
        "goal": goal or "",
        "cwd": cwd,
        "agent": ctx,
        "super_context": super_context,
        "first_moves": list(spec.first_moves),
        "done_definition": list(spec.done_definition),
        "output_schema": list(spec.output_schema),
        "tools_primary": list(spec.tools),
        "tools_forbidden": list(spec.tools_forbidden),
        "handoff": list(spec.handoff),
        "suggested_chain": suggested_chain,
        "token_policy": ctx["token_policy"],
        "next": next_steps,
        "soft_tool_preference": True,
    }


def run_status(conn: Any, *, session_id: str, client_id: str | None = None) -> dict[str, Any]:
    from forge_conductor import store

    session = store.agent_session_get(conn, session_id)
    state = _load_run(conn, session_id)
    binding = get_active(client_id)
    job = None
    try:
        from forge_conductor.agent_jobs import get_job_for_session

        job = get_job_for_session(conn, session_id)
    except Exception:
        job = None
    terminal = None
    if session:
        terminal = session.get("status") in ("completed", "ended", "failed", "closed")
    return {
        "ok": True,
        "session": session,
        "run": state,
        "job": job,
        "executor": (state or {}).get("executor") or (job or {}).get("payload", {}).get("executor"),
        "terminal": bool(terminal)
        or (job is not None and job.get("status") in ("completed", "failed")),
        "active_binding": (
            {
                "session_id": binding.session_id,
                "agent_id": binding.agent_id,
                "goal": binding.goal,
            }
            if binding
            else None
        ),
    }


def run_complete(
    conn: Any,
    *,
    session_id: str,
    report: dict[str, Any] | str | None = None,
    client_id: str | None = None,
) -> dict[str, Any]:
    from forge_conductor import audit
    from forge_conductor import store

    session = store.agent_session_get(conn, session_id)
    if session is None:
        raise ToolError(
            "session_not_found",
            f"Unknown session {session_id}",
            retryable=True,
        )

    state = _load_run(conn, session_id) or {}
    schema = list(state.get("output_schema") or [])
    missing: list[str] = []
    report_obj: dict[str, Any]
    if report is None:
        report_obj = {}
    elif isinstance(report, str):
        report_obj = {"summary": report}
    else:
        report_obj = dict(report)

    for key in schema:
        if key not in report_obj or report_obj.get(key) in (None, "", [], {}):
            missing.append(key)

    summary = json.dumps(
        {
            "goal": state.get("goal"),
            "report": report_obj,
            "missing_schema_keys": missing,
        },
        sort_keys=True,
    )[:4000]

    row = store.agent_session_end(conn, session_id=session_id, summary=summary)
    state["status"] = "completed"
    state["report"] = report_obj
    state["missing_schema_keys"] = missing
    _save_run(conn, session_id, state)
    clear_active_session(client_id, session_id)

    if client_id is not None:
        audit.append(
            conn,
            tool="agent_run_complete",
            args={
                "session_id": session_id,
                "agent_id": session.get("agent_id"),
                "agent_session_id": session_id,
                "missing_schema_keys": missing,
            },
            status="ok" if not missing else "warn",
            client_id=client_id,
            mutating=True,
        )

    auto_hand = None
    try:
        from forge_conductor.continuity_auto import auto_handoff, note_tool

        note_tool(
            "agent_run_complete",
            {"session_id": session_id, "agent_id": session.get("agent_id")},
        )
        auto_hand = auto_handoff(reason="agent_run_complete")
    except Exception:
        auto_hand = None

    suggested_chain: list[dict[str, str]] = []
    try:
        from forge_conductor.ram_orchestration import get_orchestration

        orch = get_orchestration()
        if orch is not None:
            orch.refresh_session(row)
            sc = orch.build_super_context(
                agent_id=str(session.get("agent_id") or ""),
                goal=str(state.get("goal") or ""),
                cwd=state.get("cwd"),
            )
            suggested_chain = list(sc.get("suggested_chain") or [])
    except Exception:
        suggested_chain = []

    next_call = None
    if suggested_chain:
        next_call = suggested_chain[0].get("call")

    return {
        "ok": True,
        "super_mode": True,
        "session": row,
        "report": report_obj,
        "schema_complete": len(missing) == 0,
        "missing_schema_keys": missing,
        "message": (
            "Run complete."
            if not missing
            else f"Run complete with missing report keys: {missing}. Prefer filling output_schema next time."
        ),
        "handoff_hint": "Follow suggested_chain — do not freestyle host writes that belong to the next specialist.",
        "suggested_chain": suggested_chain,
        "next_call": next_call,
        "auto_handoff": auto_hand,
    }


def soft_tool_preference(
    tool: str, client_id: str | None
) -> dict[str, Any] | None:
    """Return a soft warning dict if tool conflicts with active agent, else None."""
    binding = get_active(client_id)
    if binding is None:
        return None

    forbidden = set(binding.tools_forbidden or [])
    primary = set(binding.tools_primary or [])

    # Always allow agent_* lifecycle tools + continuity/orchestration
    if tool.startswith("agent_") or tool in (
        "session_bootstrap",
        "forge_status",
        "inventory_tools",
        "precommit_gate",
        "recommend_tools",
        "project_current",
        "project_focus",
        "handoff_save",
        "handoff_load",
        "memory_get",
        "memory_search",
        "memory_set",
        "memory_stats",
        "orchestration_status",
        "orchestration_flush",
        "agent_chain_recommend",
    ):
        return None

    if tool in forbidden:
        return {
            "forge_soft_preference": "forbidden",
            "severity": "warn",
            "agent_id": binding.agent_id,
            "session_id": binding.session_id,
            "message": (
                f"Active agent '{binding.agent_id}' lists '{tool}' as tools_forbidden. "
                f"Prefer tools_primary={list(binding.tools_primary)[:8]}. "
                "Continue only if essential; explain why."
            ),
            "tools_primary": list(binding.tools_primary),
            "tools_forbidden": list(binding.tools_forbidden),
        }

    if primary and tool not in primary:
        # Soft prefer — not an error
        return {
            "forge_soft_preference": "off_primary",
            "severity": "info",
            "agent_id": binding.agent_id,
            "session_id": binding.session_id,
            "message": (
                f"Active agent '{binding.agent_id}' prefers tools_primary; "
                f"'{tool}' is outside that list. OK if needed for the goal."
            ),
            "tools_primary": list(binding.tools_primary),
        }
    return None


def annotate_result_with_preference(result: Any, pref: dict[str, Any] | None) -> Any:
    """Attach soft preference warning onto ToolResult or dict without failing the call."""
    if not pref:
        return result
    try:
        from fastmcp.tools.base import ToolResult

        if isinstance(result, ToolResult):
            sc = result.structured_content
            if isinstance(sc, dict):
                sc = {**sc, "agent_tool_preference": pref}
            else:
                sc = {"result": sc, "agent_tool_preference": pref}
            meta = dict(result.meta or {})
            meta["agent_tool_preference"] = pref
            return ToolResult(
                content=result.content,
                structured_content=sc,
                meta=meta,
                is_error=result.is_error,
            )
    except Exception:
        pass
    if isinstance(result, dict):
        out = dict(result)
        out["agent_tool_preference"] = pref
        return out
    return result
