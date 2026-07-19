"""Fail-forward orchestration: classify errors and return recovery actions.

Goal: never dead-end the host. Every known failure maps to:
  - automatic remediations we can run now
  - fallback tools / servers / agents
  - concrete next steps for the host model
"""

from __future__ import annotations

import json
import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable


def _home() -> Path:
    return Path(os.environ.get("FORGE_CONDUCTOR_HOME", Path.home() / ".forge-conductor"))


def _diag(event: str, **fields: Any) -> None:
    rec = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "event": event,
        "src": "fail_forward",
        **fields,
    }
    try:
        log_dir = _home() / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        with (log_dir / "failover-diagnostics.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, default=str) + "\n")
    except OSError:
        pass


@dataclass
class RecoveryPlan:
    error_class: str
    severity: str  # info | warn | error | fatal_host
    summary: str
    auto_actions: list[str] = field(default_factory=list)
    auto_results: list[dict[str, Any]] = field(default_factory=list)
    fallback_tools: list[str] = field(default_factory=list)
    fallback_servers: list[str] = field(default_factory=list)
    fallback_agents: list[str] = field(default_factory=list)
    host_steps: list[str] = field(default_factory=list)
    retryable: bool = True
    fail_forward: bool = True

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": True,
            "fail_forward": self.fail_forward,
            "error_class": self.error_class,
            "severity": self.severity,
            "summary": self.summary,
            "auto_actions": self.auto_actions,
            "auto_results": self.auto_results,
            "fallback_tools": self.fallback_tools,
            "fallback_servers": self.fallback_servers,
            "fallback_agents": self.fallback_agents,
            "host_steps": self.host_steps,
            "retryable": self.retryable,
            "policy": (
                "Fail forward: do not stop the user goal. Apply auto remediations, "
                "then try fallback_tools / fallback_servers / fallback_agents. "
                "Only stop after fallbacks are exhausted and report what failed."
            ),
        }


# --- Tool fallback chains (prefer same intent, different path) ---
TOOL_FALLBACKS: dict[str, list[str]] = {
    "search_text": ["search_files", "fs_glob", "shell_exec"],
    "search_files": ["fs_glob", "search_text", "shell_exec"],
    "fs_read": ["fs_stat", "fs_glob", "search_files"],
    "fs_write": ["fs_edit", "shell_exec"],
    "fs_edit": ["fs_write", "shell_exec"],
    "fs_list": ["fs_glob", "shell_exec"],
    "fs_glob": ["search_files", "fs_list"],
    "shell_exec": ["python_exec", "python_run_file", "fs_read"],
    "python_exec": ["python_eval", "shell_exec", "python_run_file"],
    "python_eval": ["python_exec", "shell_exec"],
    "git_status": ["shell_exec", "fs_list"],
    "git_diff": ["shell_exec", "fs_read"],
    "git_log": ["shell_exec"],
    "http_fetch": ["web_search", "shell_exec"],
    "web_search": ["http_fetch", "research"],
    "browser_navigate": ["http_fetch", "web_search"],
    "agent_run_start": ["agent_context", "agent_session_start", "agent_recommend"],
    "agent_context": ["agent_get", "agent_run_start", "agent_list"],
    "agent_session_start": ["agent_run_start", "agent_session_recover"],
    "forge_status": ["session_bootstrap", "coord_status"],
    "session_bootstrap": ["inventory_tools", "forge_status", "agent_list"],
}

AGENT_FALLBACKS: dict[str, list[str]] = {
    "implement": ["debug", "explore", "plan"],
    "explore": ["plan", "research"],
    "plan": ["explore", "implement"],
    "review": ["security", "test"],
    "debug": ["explore", "test", "implement"],
    "test": ["debug", "implement"],
    "precommit-audit": ["review", "security"],
}


# Error classifiers: (name, severity, patterns)
_CLASSIFIERS: list[tuple[str, str, list[re.Pattern[str]]]] = [
    (
        "jinja_no_user_query",
        "fatal_host",
        [
            re.compile(r"No user query found in messages", re.I),
            re.compile(r"applyPromptTemplate.*400", re.I),
            re.compile(r"Unable to generate parser for this template", re.I),
            re.compile(r"Jinja Exception", re.I),
        ],
    ),
    (
        "mcp_not_connected",
        "error",
        [
            re.compile(r"Not connected", re.I),
            re.compile(r"Connection closed", re.I),
            re.compile(r"EPIPE|broken pipe", re.I),
            re.compile(r"MCP.*disconnect", re.I),
        ],
    ),
    (
        "tool_circuit_open",
        "warn",
        [re.compile(r"tool_circuit_open", re.I), re.compile(r"temporarily paused after repeated", re.I)],
    ),
    (
        "timeout",
        "warn",
        [re.compile(r"timeout|timed[_ ]?out|TimeoutError", re.I)],
    ),
    (
        "not_found",
        "info",
        [re.compile(r"not_found|No such file|not a file|FileNotFoundError", re.I)],
    ),
    (
        "permission",
        "warn",
        [re.compile(r"PermissionError|Access is denied|permission denied", re.I)],
    ),
    (
        "sqlite_locked",
        "warn",
        [re.compile(r"database is locked|sqlite3\.OperationalError", re.I)],
    ),
    (
        "git_error",
        "warn",
        [re.compile(r"not a git repository|git.*failed|conflict", re.I)],
    ),
    (
        "network_error",
        "warn",
        [re.compile(r"httpx|ConnectError|Name or service not known|DNS|ECONNREFUSED", re.I)],
    ),
    (
        "playwright_missing",
        "warn",
        [re.compile(r"playwright|Executable doesn't exist|BrowserType\.launch", re.I)],
    ),
    (
        "unknown_tool",
        "info",
        [re.compile(r"Unknown tool|tool not found|Method not found", re.I)],
    ),
    (
        "agent_not_found",
        "info",
        [re.compile(r"Unknown agent|agent_not_found", re.I)],
    ),
]


def classify_error(text: str) -> tuple[str, str]:
    t = text or ""
    for name, sev, patterns in _CLASSIFIERS:
        if any(p.search(t) for p in patterns):
            return name, sev
    return "generic", "warn"


def fallbacks_for_tool(tool: str | None) -> list[str]:
    if not tool:
        return ["session_bootstrap", "forge_status", "fail_forward"]
    return list(TOOL_FALLBACKS.get(tool, ["shell_exec", "fs_read", "search_text", "fail_forward"]))


def fallbacks_for_agent(agent_id: str | None) -> list[str]:
    if not agent_id:
        return ["explore", "plan", "implement"]
    return list(AGENT_FALLBACKS.get(agent_id, ["explore", "implement"]))


def _run_host_hygiene() -> dict[str, Any]:
    try:
        from forge_conductor.host_hygiene import run_hygiene

        return run_hygiene()
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": str(exc)}


def _run_doctor_lite() -> dict[str, Any]:
    try:
        from forge_conductor.store import connect, migrate
        from forge_conductor.config import ensure_home

        ensure_home()
        conn = connect()
        migrate(conn)
        n = conn.execute("SELECT COUNT(*) AS n FROM presence").fetchone()["n"]
        return {"ok": True, "presence_count": n}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": str(exc)}


def recover(
    *,
    error: str | None = None,
    last_tool: str | None = None,
    last_agent: str | None = None,
    goal: str | None = None,
    auto: bool = True,
) -> dict[str, Any]:
    """Build and optionally execute a fail-forward recovery plan."""
    blob = " ".join(
        x for x in [error or "", last_tool or "", last_agent or "", goal or ""] if x
    )
    err_class, severity = classify_error(blob)
    plan = RecoveryPlan(
        error_class=err_class,
        severity=severity,
        summary=f"Classified as {err_class}",
        fallback_tools=fallbacks_for_tool(last_tool),
        fallback_servers=["forge-conductor", "forge-conductor-fallback"],
        fallback_agents=fallbacks_for_agent(last_agent),
    )

    if err_class == "jinja_no_user_query":
        plan.summary = (
            "LM Studio chat template aborted mid tool-loop (No user query found). "
            "This is a host Jinja bug, not a Forge tool failure."
        )
        plan.auto_actions = ["patch_jinja_templates", "log_diagnostics"]
        plan.host_steps = [
            "Host hygiene will patch templates automatically.",
            "If chat still stalls: start a NEW message after patch, or new chat.",
            "Reload model if LM Studio re-copied the bad GGUF template.",
            "Continue goal via tools; do not abandon the user task.",
            "Prefer single MCP plugin if dual catalogs keep blowing context.",
        ]
        plan.fallback_tools = [
            "fail_forward",
            "host_hygiene",
            "forge_status",
            "session_bootstrap",
        ] + fallbacks_for_tool(last_tool)

    elif err_class == "mcp_not_connected":
        plan.summary = "MCP connection dropped."
        plan.auto_actions = ["doctor_lite", "log_diagnostics"]
        plan.host_steps = [
            "Switch to mcp/forge-conductor-fallback if primary dead.",
            "Toggle primary plugin OFF/ON, or rely on ForgeOrchestrator keepers.",
            "Retry last tool once after reconnect.",
        ]
        plan.fallback_servers = ["forge-conductor-fallback", "forge-conductor"]

    elif err_class == "tool_circuit_open":
        plan.summary = "Tool circuit open after repeated failures."
        plan.host_steps = [
            f"Avoid {last_tool} for ~30s.",
            f"Use fallbacks: {', '.join(plan.fallback_tools[:5])}",
        ]
        plan.auto_actions = ["log_diagnostics"]

    elif err_class == "timeout":
        plan.summary = "Operation timed out."
        plan.host_steps = [
            "Retry once with longer timeout_sec if shell_exec.",
            "Narrow scope (smaller path/root).",
            f"Try fallbacks: {', '.join(plan.fallback_tools[:4])}",
        ]

    elif err_class == "not_found":
        plan.summary = "Path or resource not found."
        plan.host_steps = [
            "fs_glob / search_files from a parent directory.",
            "Verify cwd with shell_exec('cd') or fs_list.",
        ]
        plan.fallback_tools = ["fs_glob", "search_files", "fs_list", "fs_stat"]

    elif err_class == "permission":
        plan.summary = "Permission denied."
        plan.host_steps = [
            "Use a path under the user profile or repo.",
            "Do not retry the same path more than once.",
        ]
        plan.retryable = False

    elif err_class == "sqlite_locked":
        plan.summary = "SQLite store locked."
        plan.host_steps = ["Retry the same tool once after a short pause."]
        plan.auto_actions = ["log_diagnostics"]

    elif err_class == "network_error":
        plan.summary = "Network / HTTP failure."
        plan.host_steps = [
            "Retry once.",
            "Fall back to local tools (fs_*, search_*, memory_*).",
        ]
        plan.fallback_tools = ["fs_read", "search_text", "memory_search"]

    elif err_class == "playwright_missing":
        plan.summary = "Browser tooling unavailable."
        plan.host_steps = [
            "Use http_fetch / web_search instead of browser_*.",
            "Optional: playwright install chromium in the forge venv.",
        ]
        plan.fallback_tools = ["http_fetch", "web_search", "shell_exec"]

    elif err_class == "unknown_tool":
        plan.summary = "Unknown or missing tool."
        plan.host_steps = [
            "Call session_bootstrap or inventory_tools.",
            "Use only tools from the bootstrap list.",
        ]
        plan.fallback_tools = ["session_bootstrap", "inventory_tools", "forge_status"]

    elif err_class == "agent_not_found":
        plan.summary = "Unknown agent id."
        plan.host_steps = [
            "agent_list then agent_recommend(task=goal).",
            "agent_run_start with a known id (explore/plan/implement/...).",
        ]
        plan.fallback_agents = ["explore", "plan", "implement"]
        plan.fallback_tools = ["agent_list", "agent_recommend", "agent_run_start"]

    else:
        plan.summary = "Generic failure — apply generic fail-forward."
        plan.host_steps = [
            "Retry once if retryable.",
            f"Try fallback tools: {', '.join(plan.fallback_tools[:5])}",
            "If MCP flaky: use forge-conductor-fallback.",
            "If still blocked: call fail_forward again with the new error text.",
        ]
        if last_tool:
            plan.fallback_tools = fallbacks_for_tool(last_tool)
        plan.auto_actions = ["log_diagnostics"]

    if goal:
        plan.host_steps.append(f"Resume user goal: {goal}")

    # Execute automatic remediations
    if auto:
        for action in list(plan.auto_actions):
            if action == "patch_jinja_templates" or (
                err_class == "jinja_no_user_query" and action == "patch_jinja_templates"
            ):
                pass  # handled below as host_hygiene
            if action in ("patch_jinja_templates",) or err_class == "jinja_no_user_query":
                if not any(r.get("action") == "host_hygiene" for r in plan.auto_results):
                    res = _run_host_hygiene()
                    plan.auto_results.append({"action": "host_hygiene", "result": res})
                    if "host_hygiene" not in plan.auto_actions:
                        plan.auto_actions.append("host_hygiene")
            if action == "doctor_lite":
                plan.auto_results.append({"action": "doctor_lite", "result": _run_doctor_lite()})
            if action == "log_diagnostics":
                _diag(
                    "fail_forward_plan",
                    error_class=err_class,
                    last_tool=last_tool,
                    last_agent=last_agent,
                    error=(error or "")[:500],
                )
                plan.auto_results.append({"action": "log_diagnostics", "result": {"ok": True}})

        # Always hygiene on host-fatal classes
        if err_class == "jinja_no_user_query" and not any(
            r.get("action") == "host_hygiene" for r in plan.auto_results
        ):
            plan.auto_results.append({"action": "host_hygiene", "result": _run_host_hygiene()})

    _diag(
        "fail_forward",
        error_class=err_class,
        severity=severity,
        last_tool=last_tool,
        auto_actions=plan.auto_actions,
    )
    return plan.to_dict()


def attach_fail_forward(
    payload: dict[str, Any],
    *,
    last_tool: str | None = None,
    error_text: str | None = None,
) -> dict[str, Any]:
    """Annotate a tool error payload with fail-forward guidance (no auto side effects)."""
    err = error_text or payload.get("message") or payload.get("code") or ""
    plan = recover(
        error=str(err),
        last_tool=last_tool or payload.get("tool"),
        auto=False,
    )
    out = dict(payload)
    out["fail_forward"] = {
        "error_class": plan["error_class"],
        "fallback_tools": plan["fallback_tools"],
        "fallback_servers": plan["fallback_servers"],
        "fallback_agents": plan["fallback_agents"],
        "host_steps": plan["host_steps"][:6],
        "next": (
            f"Call fail_forward(error=...) for auto-remediation, or try tools: "
            f"{', '.join(plan['fallback_tools'][:4])}"
        ),
    }
    return out
