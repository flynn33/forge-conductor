"""Redundancy and fallback helpers for multi-host MCP reliability.

Layers (outer → inner):
1. Dual LM Studio MCP entries (primary + fallback launcher)
2. Cascading launcher (venv exe → venv python -m → PATH)
3. Tool-level multi-engine (e.g. search: git-grep → rg → python)
4. Soft errors (never raise into FastMCP for expected misses)
5. subprocess stdin=DEVNULL (never inherit MCP JSON-RPC pipe)
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path
from typing import Any


def serve_candidates() -> list[dict[str, Any]]:
    """Ordered list of ways to start the MCP server on this machine."""
    worktree = Path(__file__).resolve().parents[2]
    venv_exe = worktree / ".venv" / "Scripts" / "forge-conductor.exe"
    venv_py = worktree / ".venv" / "Scripts" / "python.exe"
    path_exe = shutil.which("forge-conductor")
    home = Path(os.environ.get("FORGE_CONDUCTOR_HOME", Path.home() / ".forge-conductor"))

    out: list[dict[str, Any]] = []
    if venv_exe.is_file():
        out.append(
            {
                "id": "venv_exe",
                "command": str(venv_exe),
                "args": ["serve"],
                "exists": True,
            }
        )
    if venv_py.is_file():
        out.append(
            {
                "id": "venv_python_module",
                "command": str(venv_py),
                "args": ["-m", "forge_conductor", "serve"],
                "exists": True,
            }
        )
    if path_exe:
        out.append(
            {
                "id": "path_exe",
                "command": path_exe,
                "args": ["serve"],
                "exists": True,
            }
        )
    # System python module (editable install may live on PATH python)
    sys_py = shutil.which("python") or sys.executable
    if sys_py:
        out.append(
            {
                "id": "system_python_module",
                "command": sys_py,
                "args": ["-m", "forge_conductor", "serve"],
                "exists": True,
            }
        )
    # Record launcher scripts for diagnostics
    primary = home / "bin" / "forge-serve.cmd"
    fallback = home / "bin" / "forge-serve-fallback.cmd"
    out.append(
        {
            "id": "home_launcher_primary",
            "command": str(primary),
            "args": [],
            "exists": primary.is_file(),
        }
    )
    out.append(
        {
            "id": "home_launcher_fallback",
            "command": str(fallback),
            "args": [],
            "exists": fallback.is_file(),
        }
    )
    return out


def recovery_rules() -> list[str]:
    """Host-facing rules when tools fail (injected via session_bootstrap)."""
    return [
        "Primary mcp/forge-conductor AND forge-conductor-fallback both run under "
        "automatic fail-over supervisors (backend restarts on crash; host stdio stays up).",
        "Every tool call is hardened: one automatic retry for transient errors, "
        "uncaught exceptions become soft error payloads (never drop the MCP session).",
        "If a tool returns code=tool_circuit_open: wait ~30s or use a different tool.",
        "If a single tool fails twice after soft retries: STOP looping; report the error.",
        "If you see Not connected / Connection closed: STOP tools and tell the user "
        "the host dropped the outer connection — toggle plugin or use forge-conductor-fallback.",
        "Sub-agents are host-driven playbooks: non-trivial work MUST use "
        "agent_run_start(agent_id, goal) then agent_run_complete. "
        "Large context: never skip agents to save tokens. "
        "If a session fails use agent_session_recover or agent_run_start again. "
        "Stale open sessions auto-close after 24h.",
        "exit_code!=0 means the command failed — try a different approach, not infinite retries.",
        "For long builds use shell_exec(..., timeout_sec=300) — default timeout is short.",
        "Prefer vs_msbuild / vs_toolchain over shell-hunting for Visual Studio tools.",
        "Prefer shell_which(name) over 'where /r C:\\Users ...'.",
        "Prefer search_text with a narrow root= subdirectory on large repos.",
    ]


def resilience_snapshot() -> dict[str, Any]:
    """Status blob for forge_status / session_bootstrap."""
    cands = serve_candidates()
    return {
        "redundancy": {
            "launch_candidates": cands,
            "ready_count": sum(1 for c in cands if c.get("exists")),
            "dual_lmstudio_servers": [
                "forge-conductor (supervise=auto fail-over, role=primary)",
                "forge-conductor-fallback (supervise=auto fail-over, role=fallback)",
            ],
            "automatic_failover": {
                "enabled_on": ["forge-conductor", "forge-conductor-fallback"],
                "mechanism": "stdio supervisor restarts backend + replays initialize",
                "host_action": "none when only backend dies",
                "diagnostics": [
                    "~/.forge-conductor/logs/failover-diagnostics.jsonl",
                    "~/.forge-conductor/logs/tool-diagnostics.jsonl",
                    "~/.forge-conductor/logs/supervisor.log",
                ],
            },
            "tool_resilience": {
                "middleware": "ForgeToolResilienceMiddleware (all tools)",
                "retry": "1 automatic retry on retryable/transient errors",
                "soft_errors": "exceptions → ToolResult(is_error) — session stays up",
                "circuit_breaker": "8 consecutive fails → 30s pause per tool",
                "fail_forward": "error payloads include fallback_tools/servers/agents",
            },
            "fail_forward": {
                "tools": ["fail_forward", "host_hygiene"],
                "policy": "auto remediate when possible; always suggest next fallback path",
                "classes": [
                    "jinja_no_user_query",
                    "mcp_not_connected",
                    "timeout",
                    "not_found",
                    "permission",
                    "sqlite_locked",
                    "network_error",
                    "playwright_missing",
                    "tool_circuit_open",
                    "unknown_tool",
                    "agent_not_found",
                    "generic",
                ],
            },
            "agent_resilience": {
                "soft_wrappers": True,
                "agent_run_start_complete": True,
                "agent_session_recover": True,
                "soft_tool_preference": True,
                "stale_session_auto_close_sec": 86400,
                "large_context_prefer_agents": True,
            },
            "tool_fallbacks": {
                "search_text": ["git-grep", "rg", "python-walk"],
                "shell_exec": ["run_capture+DEVNULL", "timeout payload (no raise)"],
                "fs_*": ["soft not_found payloads", "exception → tool_error_payload"],
                "agents": [
                    "playbooks",
                    "agent_run_start/complete",
                    "soft tool preference",
                    "session recover",
                    "catalog reload",
                ],
            },
            "recovery_rules": recovery_rules(),
        },
        "primary_ready": any(c["id"] == "venv_exe" and c["exists"] for c in cands),
        "fallback_ready": any(
            c["id"] in {"venv_python_module", "path_exe", "system_python_module", "venv_exe"}
            and c["exists"]
            for c in cands
        ),
    }
