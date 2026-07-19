"""Session bootstrap + tool inventory (replaces standalone tool-inventory MCP)."""

from __future__ import annotations

from typing import Any

AUTO_RULES: list[str] = [
    "Call session_bootstrap first in every new chat (do not wait to be asked).",
    "SUPER AGENTS: Entire orchestration is RAM-resident. agent_run_start returns super_context "
    "(project, handoff, related_memory, prior_runs, suggested_chain). USE IT — do not re-discover blindly.",
    "CONTINUITY (critical): session_bootstrap returns active_project + handoff from RAM memory. "
    "On EVERY new chat: read continuity.active_project and continuity.handoff before asking "
    "which project this is. Resume that work unless the user clearly switches.",
    "When you know the project/repo: call project_focus(name, path, summary) immediately.",
    "Before context fills, chat ends, or user says 'new chat': call handoff_save(summary, next_steps, "
    "working_files=..., blockers=...). This is how you remember across chats.",
    "SPECIALIST INTEGRITY: While an agent run is active, do NOT freestyle host writes that belong "
    "to another specialist. Plan NEVER writes files. After agent_run_complete, call next_call / "
    "suggested_chain (e.g. docs for ROADMAP.md, implement for code).",
    "For multi-step goals: agent_chain_recommend(task=...) then execute the chain in order.",
    "Persist durable project facts with memory_set keys like project/{slug}/decisions, "
    "project/{slug}/status, project/{slug}/todo (tags include project slug).",
    "FAIL FORWARD: On ANY error (tool, MCP, Jinja, timeout, not found), call "
    "fail_forward(error=<message>, last_tool=<name>, goal=<user goal>) and follow "
    "fallback_tools / fallback_servers / host_steps. Do not stop the user goal after one failure.",
    "If the chat UI stalls or you see Jinja / No user query / applyPromptTemplate 400: "
    "call host_hygiene() then fail_forward; continue with tools after remediation.",
    "LARGE CONTEXT POLICY: This host is configured for large context. Token conservation "
    "is LESS important than using the right sub-agent. Do NOT skip agent_run_start / "
    "agent_context to save tokens.",
    "Non-trivial work (codebase map, multi-file change, design, review, debug, commit): "
    "MUST call agent_run_start(agent_id=..., goal=...) BEFORE mutating tools "
    "(fs_write/fs_edit/git_commit). Trivial one-liners may skip agents.",
    "Use agent_recommend(task=...) if unsure which specialist to pick.",
    "While an agent run is active: prefer tools_primary; avoid tools_forbidden "
    "(soft preference warnings are intentional).",
    "Finish specialist work with agent_run_complete(session_id, report matching output_schema).",
    "Use tools from forge-conductor (primary) or forge-conductor-fallback if primary is dead.",
    "Do not invent tools like /build or run_javascript.",
    "If a tool fails twice, STOP looping and report the error in plain text.",
    "If you see Not connected / Connection closed: STOP all tools immediately and tell the user "
    "to toggle primary OFF/ON or enable forge-conductor-fallback.",
    "Never repeat the identical tool call more than twice in a row.",
    "exit_code!=0 is a command failure (try another approach), not a reason to spam retries.",
    "Code execution: python_exec / python_eval (not JavaScript).",
    "Builds: vs_msbuild / vs_build_script / shell_exec with timeout_sec=300 for long cmake.",
    "GitHub PRs: gh_pr_create (head=branch name, not commit SHA); set path= to local repo.",
    "Before commit: agent_run_start(agent_id='precommit-audit', goal=...) or precommit_gate "
    "until OK_TO_COMMIT=yes.",
    "Prefer shell_which and vs_toolchain over recursive where /r across the whole disk.",
]

TASK_MAP: list[dict[str, str]] = [
    {
        "task": "discover tools / start session",
        "tools": "session_bootstrap, forge_status, project_current, agent_list, agent_recommend",
    },
    {
        "task": "resume after new chat / full context",
        "tools": "session_bootstrap (read continuity), project_current, handoff_load, memory_search",
    },
    {
        "task": "switch or declare project",
        "tools": "project_focus(name, path, summary), memory_set, handoff_save",
    },
    {
        "task": "save progress for next chat",
        "tools": "handoff_save, memory_set, memory_flush",
    },
    {
        "task": "any non-trivial specialist work",
        "tools": "agent_run_start(agent_id, goal), then tools_primary, then agent_run_complete",
    },
    {
        "task": "pre-commit audit",
        "tools": "agent_run_start(agent_id='precommit-audit', goal=...), git_status, git_diff",
    },
    {
        "task": "git status/diff/commit",
        "tools": "git_status, git_diff, git_add, git_commit, git_push, git_pull",
    },
    {
        "task": "pull request",
        "tools": "gh_pr_create, gh_pr_list, gh_pr_view, gh_whoami (push branch first)",
    },
    {
        "task": "Visual Studio / MSBuild",
        "tools": "vs_list, vs_toolchain, vs_msbuild, vs_build_script",
    },
    {
        "task": "Python code",
        "tools": "python_info, python_eval, python_exec, python_run_file",
    },
    {
        "task": "filesystem / shell",
        "tools": "fs_read, fs_write, fs_list, shell_exec",
    },
    {
        "task": "memory across sessions (RAM corpus)",
        "tools": "memory_set, memory_get, memory_search, memory_list, memory_stats, project_focus, handoff_save",
    },
    {
        "task": "RAM orchestration / super agents",
        "tools": "orchestration_status, orchestration_flush, agent_chain_recommend, agent_run_start",
    },
    {
        "task": "specialists (host-driven roles)",
        "tools": "agent_run_start/complete, agent_context, agent_recommend, agent_chain_recommend, agent_session_*",
    },
]


def register(mcp: Any) -> None:
    from forge_conductor.server import TOOL_NAMES, get_ctx

    @mcp.tool
    def session_bootstrap() -> dict[str, Any]:
        """AUTO session start. Call FIRST every chat. Includes RAM continuity snapshot."""
        from forge_conductor.server import TOOL_NAMES as TN
        from forge_conductor.agents_loader import ROUTE_HINTS, load_agents
        from forge_conductor.config import get_home

        from forge_conductor.resilience import recovery_rules, resilience_snapshot
        from forge_conductor.memory_ram import continuity_snapshot, ensure_bank, get_bank

        ctx = get_ctx()
        agents = load_agents(get_home())
        snap = resilience_snapshot()

        continuity: dict[str, Any] | None = None
        orchestration = None
        try:
            if ctx is not None:
                bank = get_bank() or ensure_bank(ctx.conn, ctx.home)
                continuity = continuity_snapshot(bank)
                from forge_conductor.ram_orchestration import (
                    ensure_orchestration,
                    get_orchestration,
                )

                orch = get_orchestration() or ensure_orchestration(ctx.conn, ctx.home)
                orchestration = {
                    "stats": orch.stats(),
                    "super_policy": orch.super_policy,
                    "agent_ids": sorted(orch.agents.keys()),
                }
        except Exception as exc:  # noqa: BLE001 — bootstrap must never fail
            continuity = {"ok": False, "error": str(exc)}
            orchestration = {"ok": False, "error": str(exc)}

        active_name = None
        if isinstance(continuity, dict) and continuity.get("active_project"):
            try:
                import json

                active_name = json.loads(continuity["active_project"]["body"]).get("name")
            except Exception:  # noqa: BLE001
                active_name = None

        agent_backend = None
        try:
            from forge_conductor.agent_backend import policy_banner, status_payload

            agent_backend = status_payload(get_home())
            ab_policy = policy_banner(get_home())
        except Exception as exc:  # noqa: BLE001
            agent_backend = {"ok": False, "error": str(exc)}
            ab_policy = {"mode": "host", "policy": "UNKNOWN"}

        mode = (ab_policy or {}).get("mode") or "host"
        if mode == "grok":
            message = (
                "Bootstrap complete. AGENT BACKEND=GROK (MANDATORY OFFLOAD). "
                "You are the LOCAL ROUTER only. Non-trivial work → agent_run_start ONLY; "
                "poll agent_run_status. Do NOT fs_write/shell/git yourself. "
                "CONTINUITY loaded. memory_*/handoff_* allowed."
            )
            mandatory_loop = [
                "session_bootstrap (this call) → read agent_backend.policy",
                "if active_project set: resume it",
                "agent_recommend → agent_run_start(agent_id, goal)  [GROK executes]",
                "poll agent_run_status until terminal",
                "summarize report for user — do not re-implement",
                "handoff_save before chat end",
            ]
        else:
            message = (
                "Bootstrap complete. SUPER AGENTS + RAM ORCHESTRATION online. "
                "AGENT BACKEND=HOST. CONTINUITY loaded. "
                "Non-trivial work → agent_run_start (super_context injected) or "
                "agent_chain_recommend for multi-step. Plan never writes files → docs|implement."
            )
            mandatory_loop = [
                "session_bootstrap (this call) → read continuity block",
                "if active_project set: resume it (do not re-ask project path unless needed)",
                "agent_recommend or route_hints → agent_run_start(agent_id, goal)",
                "work with tools_primary until done_definition",
                "handoff_save before chat end / context full",
                "agent_run_complete(session_id, report)",
                "before commit: agent_run_start(precommit-audit) → OK_TO_COMMIT=yes",
                "git_commit / gh_pr_create only after audit",
            ]

        return {
            "ok": True,
            "server": "forge-conductor",
            "transport": "stdio",
            "super_mode": True,
            "agent_backend": agent_backend,
            "message": message,
            "token_policy": {
                "large_context": True,
                "prefer_sub_agents_over_token_savings": True,
                "rule": (
                    "Ignoring sub-agents to save tokens is incorrect on this host. "
                    "Load full playbooks via agent_run_start / agent_context. "
                    "When agent_backend.mode=grok, offload is MANDATORY."
                ),
            },
            "auto_rules": AUTO_RULES + recovery_rules(),
            "tool_count": len(TN),
            "tools": sorted(TN),
            "agents": [
                a.card()
                for a in sorted(agents.values(), key=lambda x: x.id)
            ],
            "route_hints": ROUTE_HINTS,
            "task_map": TASK_MAP,
            "mandatory_loop": mandatory_loop,
            "continuity": continuity,
            "orchestration": orchestration,
            "active_project_name": active_name,
            "client_id": ctx.client_id if ctx else None,
            "home": str(get_home()),
            "resilience": snap,
            "failover": {
                "primary_plugin": "mcp/forge-conductor",
                "fallback_plugin": "mcp/forge-conductor-fallback",
                "ram_memory_plugin": "mcp/ram-memory",
                "when": "Not connected / Connection closed / repeated MCP timeouts",
            },
        }

    @mcp.tool
    def inventory_tools() -> dict[str, Any]:
        """Refresh tool list mid-session if the model feels lost."""
        return session_bootstrap()

    @mcp.tool
    def precommit_gate() -> dict[str, Any]:
        """Mandatory pre-commit procedure. Call before any commit or PR."""
        return {
            "ok": True,
            "gate": "precommit-audit",
            "instructions": [
                "1. agent_run_start(agent_id='precommit-audit', goal='pre-commit audit') "
                "or agent_context(agent_id='precommit-audit')",
                "2. Follow that agent: git_status + git_diff + structured report",
                "3. If OK_TO_COMMIT=no: fix blockers and re-run",
                "4. If OK_TO_COMMIT=yes: agent_run_complete then git_add/git_commit / gh_pr_create",
            ],
            "preferred_call": "agent_run_start(agent_id='precommit-audit', goal='Audit staged and unstaged changes for commit readiness')",
            "token_policy": "Do not skip precommit specialist to save tokens.",
        }

    @mcp.tool
    def recommend_tools(task: str = "") -> dict[str, Any]:
        """Suggest tools and the best sub-agent for a free-text task."""
        from forge_conductor.agents_loader import recommend_agent
        from forge_conductor.config import get_home

        rec = recommend_agent(task, get_home())
        return {
            "ok": True,
            "task": task,
            "agent": rec,
            "next": rec.get("call"),
            "note": "Call agent_run_start next for non-trivial work (large context host).",
            "task_map": TASK_MAP,
        }

    TOOL_NAMES.update(
        {
            "session_bootstrap",
            "inventory_tools",
            "precommit_gate",
            "recommend_tools",
        }
    )
