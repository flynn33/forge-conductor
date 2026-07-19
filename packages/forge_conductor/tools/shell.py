"""Shell tools: service layer + FastMCP registration."""

from __future__ import annotations

import os
import shutil
from typing import Any

from forge_conductor.subprocess_util import (
    DEFAULT_SUBPROCESS_TIMEOUT_SEC,
    run_capture,
)


def _default_timeout_sec() -> float:
    from forge_conductor.server import get_ctx

    ctx = get_ctx()
    if ctx is not None and isinstance(ctx.config, dict):
        shell_cfg = ctx.config.get("shell") or {}
        if isinstance(shell_cfg, dict) and "default_timeout_sec" in shell_cfg:
            return float(shell_cfg["default_timeout_sec"])
    try:
        from forge_conductor.config import load_config

        cfg = load_config()
        return float(
            (cfg.get("shell") or {}).get(
                "default_timeout_sec", DEFAULT_SUBPROCESS_TIMEOUT_SEC
            )
        )
    except Exception:
        return DEFAULT_SUBPROCESS_TIMEOUT_SEC


def _audit_exec(
    args: dict[str, Any],
    *,
    status: str,
    client_id: str | None,
    duration_ms: int | None = None,
    error: str | None = None,
) -> None:
    if client_id is None:
        return
    from forge_conductor import audit
    from forge_conductor.server import get_ctx

    ctx = get_ctx()
    if ctx is None:
        return
    audit.append(
        ctx.conn,
        tool="shell_exec",
        args=args,
        status=status,
        client_id=client_id,
        duration_ms=duration_ms,
        mutating=True,
        error=error,
    )


def svc_exec(
    command: str | list[str],
    *,
    cwd: str | None = None,
    timeout_sec: float | None = None,
    env: dict[str, str] | None = None,
    client_id: str | None = None,
) -> dict[str, Any]:
    """Run a shell command; capture stdout/stderr/exit code.

    *command* may be a string (run via shell) or an argv list (no shell).
    Always uses a hard timeout (default 30s, max 55s) so MCP hosts do not hang.
    """
    timeout = timeout_sec if timeout_sec is not None else _default_timeout_sec()
    cmd_repr: str | list[str] = command
    audit_args: dict[str, Any] = {
        "command": cmd_repr if isinstance(cmd_repr, str) else list(cmd_repr),
        "cwd": cwd,
        "timeout_sec": timeout,
    }

    # Allow long builds when caller sets timeout_sec (default still short for
    # interactive probes). Cap at 600s for MSBuild/cmake; host may still cancel.
    max_to = 600.0 if (timeout_sec is not None and float(timeout_sec) > 55) else 55.0
    result = run_capture(
        command,
        cwd=cwd,
        timeout_sec=timeout,
        env=env,
        max_timeout_sec=max_to,
    )

    if result.get("timed_out"):
        from forge_conductor.errors import ToolError, tool_error_payload

        err = ToolError(
            "timeout",
            result.get("error") or f"Command timed out after {timeout}s",
            retryable=True,
            detail={"timeout_sec": result.get("timeout_sec"), "command": cmd_repr},
        )
        payload = tool_error_payload(err)
        out = {
            **payload,
            "stdout": result.get("stdout") or "",
            "stderr": result.get("stderr") or "",
            "exit_code": None,
            "timed_out": True,
            "duration_ms": result.get("duration_ms"),
            "truncated": result.get("truncated"),
            "error": err.message,
        }
        _audit_exec(
            audit_args,
            status="error",
            client_id=client_id,
            duration_ms=out["duration_ms"],
            error=out["error"],
        )
        return out

    exit_code = result.get("exit_code")
    out = {
        "stdout": result.get("stdout") or "",
        "stderr": result.get("stderr") or "",
        "exit_code": exit_code,
        "timed_out": False,
        "duration_ms": result.get("duration_ms"),
        "truncated": result.get("truncated"),
    }
    _audit_exec(
        {**audit_args, "exit_code": exit_code},
        status="ok" if exit_code == 0 else "error",
        client_id=client_id,
        duration_ms=out["duration_ms"],
        error=None if exit_code == 0 else f"exit_code={exit_code}",
    )
    return out


def svc_which(name: str) -> dict[str, Any]:
    """Resolve an executable on PATH."""
    path = shutil.which(name)
    if path is None:
        return {"name": name, "path": None, "found": False}
    return {"name": name, "path": path, "found": True}


def svc_env_get(key: str) -> dict[str, Any]:
    """Get an environment variable value (null if missing)."""
    if key not in os.environ:
        return {"key": key, "value": None, "found": False}
    return {"key": key, "value": os.environ[key], "found": True}


def _client_id_from_ctx() -> str | None:
    from forge_conductor.server import get_ctx

    ctx = get_ctx()
    return ctx.client_id if ctx is not None else None


def register(mcp: Any) -> None:
    """Register shell tools on *mcp* and record names in TOOL_NAMES."""
    from forge_conductor.server import TOOL_NAMES

    def _safe_exec(**kwargs: Any) -> dict[str, Any]:
        from forge_conductor.errors import tool_error_payload

        try:
            return svc_exec(**kwargs)
        except Exception as exc:  # noqa: BLE001
            return tool_error_payload(exc)

    @mcp.tool(
        description=(
            "Execute a local shell command. Prefer cwd= for directory instead of "
            "embedding cd. Default timeout ~30s (max 55s). For long builds pass "
            "timeout_sec up to 600. Returns stdout, stderr, exit_code, timed_out. "
            "exit_code!=0 is a command failure, not an MCP disconnect."
        )
    )
    def shell_exec(
        command: str | list[str],
        cwd: str | None = None,
        timeout_sec: float | None = None,
    ) -> dict[str, Any]:
        return _safe_exec(
            command=command,
            cwd=cwd,
            timeout_sec=timeout_sec,
            client_id=_client_id_from_ctx(),
        )

    @mcp.tool
    def shell_which(name: str) -> dict[str, Any]:
        """Resolve an executable name on PATH."""
        return svc_which(name)

    @mcp.tool
    def shell_env_get(key: str) -> dict[str, Any]:
        """Get the value of an environment variable."""
        return svc_env_get(key)

    TOOL_NAMES.update(
        {
            "shell_exec",
            "shell_which",
            "shell_env_get",
        }
    )
