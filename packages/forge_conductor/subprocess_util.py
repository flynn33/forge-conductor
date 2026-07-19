"""Safe subprocess helpers for MCP tools (timeouts, no interactive hang)."""

from __future__ import annotations

import os
import subprocess
import sys
from typing import Any

# Windows: do not flash consoles; avoid waiting on UI.
_CREATE_NO_WINDOW = 0x08000000 if sys.platform == "win32" else 0

# Keep under typical host MCP tool timeouts (~60s).
DEFAULT_SUBPROCESS_TIMEOUT_SEC = 30.0
MAX_CAPTURE_CHARS = 200_000


def noninteractive_env(extra: dict[str, str] | None = None) -> dict[str, str]:
    """Environment that avoids git/ssh credential prompts and pagers."""
    env = os.environ.copy()
    env.setdefault("GIT_TERMINAL_PROMPT", "0")
    env.setdefault("GIT_PAGER", "cat")
    env.setdefault("PAGER", "cat")
    env.setdefault("GCM_INTERACTIVE", "never")
    env.setdefault("GIT_OPTIONAL_LOCKS", "0")
    # Prefer no editor popups for git commit templates etc.
    env.setdefault("GIT_EDITOR", "true")
    env.setdefault("EDITOR", "true")
    if extra:
        env.update(extra)
    return env


def _truncate(text: str, limit: int = MAX_CAPTURE_CHARS) -> tuple[str, bool]:
    if text is None:
        return "", False
    if len(text) <= limit:
        return text, False
    return text[:limit] + f"\n...[truncated {len(text) - limit} chars]", True


def run_capture(
    args: str | list[str],
    *,
    cwd: str | None = None,
    timeout_sec: float | None = None,
    env: dict[str, str] | None = None,
    shell: bool | None = None,
    max_timeout_sec: float | None = None,
) -> dict[str, Any]:
    """Run a command with capture, hard timeout, and non-interactive env.

    Returns dict with stdout, stderr, exit_code, timed_out, duration_ms, truncated.
    Never raises TimeoutExpired — returns timed_out=True instead.

    *max_timeout_sec* defaults to 55s (MCP host headroom). Build/package tools
    may raise the cap (e.g. 600) for long MSBuild runs.
    """
    import time

    timeout = (
        float(timeout_sec)
        if timeout_sec is not None
        else DEFAULT_SUBPROCESS_TIMEOUT_SEC
    )
    cap = float(max_timeout_sec) if max_timeout_sec is not None else 55.0
    cap = max(1.0, min(cap, 3600.0))
    timeout = max(1.0, min(timeout, cap))

    if shell is None:
        shell = isinstance(args, str)
    run_env = noninteractive_env(env)
    kwargs: dict[str, Any] = {
        "args": args,
        "shell": shell,
        "cwd": cwd,
        "env": run_env,
        "capture_output": True,
        "text": True,
        "timeout": timeout,
        "stdin": subprocess.DEVNULL,
    }
    if _CREATE_NO_WINDOW:
        kwargs["creationflags"] = _CREATE_NO_WINDOW

    t0 = time.perf_counter()
    try:
        completed = subprocess.run(**kwargs)
        duration_ms = int((time.perf_counter() - t0) * 1000)
        stdout, t1 = _truncate(completed.stdout or "")
        stderr, t2 = _truncate(completed.stderr or "")
        return {
            "stdout": stdout,
            "stderr": stderr,
            "exit_code": completed.returncode,
            "timed_out": False,
            "duration_ms": duration_ms,
            "truncated": t1 or t2,
            "timeout_sec": timeout,
        }
    except subprocess.TimeoutExpired as exc:
        duration_ms = int((time.perf_counter() - t0) * 1000)
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode("utf-8", errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", errors="replace")
        stdout, t1 = _truncate(stdout)
        stderr, t2 = _truncate(stderr)
        return {
            "stdout": stdout,
            "stderr": stderr,
            "exit_code": None,
            "timed_out": True,
            "duration_ms": duration_ms,
            "truncated": t1 or t2,
            "timeout_sec": timeout,
            "error": f"Command timed out after {timeout}s",
        }
