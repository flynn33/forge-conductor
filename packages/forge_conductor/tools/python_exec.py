"""In-process + subprocess Python execution (replaces standalone python MCP)."""

from __future__ import annotations

import io
import os
import sys
import tempfile
import traceback
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import Any

from forge_conductor.subprocess_util import run_capture

_SESSION: dict[str, Any] = {"__name__": "__forge_python__"}
_MAX = 80_000


def _truncate(s: str) -> tuple[str, bool]:
    if len(s) <= _MAX:
        return s, False
    return s[:_MAX] + "\n...[truncated]...", True


def _interpreter() -> str:
    raw = os.environ.get("FORGE_PYTHON", "").strip()
    if raw and Path(raw).is_file():
        return raw
    for c in (
        r"C:\Program Files\Python312\python.exe",
        r"C:\Program Files\Python313\python.exe",
        sys.executable,
    ):
        if c and Path(c).is_file() and "WindowsApps" not in c:
            return c
    return sys.executable


def register(mcp: Any) -> None:
    from forge_conductor.server import TOOL_NAMES

    @mcp.tool
    def python_info() -> dict[str, Any]:
        """Python interpreter path/version. Prefer python_exec over inventing JS tools."""
        py = _interpreter()
        r = run_capture([py, "--version"], timeout_sec=15)
        return {
            "ok": r.get("exit_code") == 0,
            "interpreter": py,
            "version": ((r.get("stdout") or r.get("stderr") or "").strip()),
            "session_keys": sorted(k for k in _SESSION if not k.startswith("__")),
            "hint": "Use python_exec/python_eval — never invent JavaScript tools",
        }

    @mcp.tool
    def python_exec(code: str, session: bool = True, timeout_sec: float = 60) -> dict[str, Any]:
        """Execute Python code. session=true keeps variables across calls."""
        if not (code or "").strip():
            return {"ok": False, "error": "empty_code", "message": "code is required"}
        if session:
            out_buf, err_buf = io.StringIO(), io.StringIO()
            ok = True
            try:
                with redirect_stdout(out_buf), redirect_stderr(err_buf):
                    exec(code, _SESSION, _SESSION)  # noqa: S102
            except Exception:
                ok = False
                err_buf.write(traceback.format_exc())
            so, t1 = _truncate(out_buf.getvalue())
            se, t2 = _truncate(err_buf.getvalue())
            return {
                "ok": ok,
                "stdout": so,
                "stderr": se,
                "truncated": t1 or t2,
                "mode": "session",
            }
        py = _interpreter()
        with tempfile.NamedTemporaryFile(
            "w", suffix=".py", delete=False, encoding="utf-8"
        ) as f:
            f.write(code)
            tmp = f.name
        try:
            r = run_capture(
                [py, tmp],
                timeout_sec=min(float(timeout_sec), 600),
                max_timeout_sec=600,
            )
            so, t1 = _truncate(r.get("stdout") or "")
            se, t2 = _truncate(r.get("stderr") or "")
            return {
                "ok": r.get("exit_code") == 0 and not r.get("timed_out"),
                "stdout": so,
                "stderr": se,
                "exit_code": r.get("exit_code"),
                "timed_out": r.get("timed_out"),
                "truncated": t1 or t2,
                "mode": "subprocess",
            }
        finally:
            Path(tmp).unlink(missing_ok=True)

    @mcp.tool
    def python_eval(expression: str, session: bool = True) -> dict[str, Any]:
        """Evaluate a Python expression; return repr(result)."""
        if not (expression or "").strip():
            return {"ok": False, "error": "empty_expression"}
        if session:
            out_buf, err_buf = io.StringIO(), io.StringIO()
            ok = True
            result = None
            try:
                with redirect_stdout(out_buf), redirect_stderr(err_buf):
                    result = repr(eval(expression, _SESSION, _SESSION))  # noqa: S307
            except Exception:
                ok = False
                err_buf.write(traceback.format_exc())
            return {
                "ok": ok,
                "result": result,
                "stdout": out_buf.getvalue(),
                "stderr": err_buf.getvalue(),
            }
        py = _interpreter()
        r = run_capture(
            [py, "-c", f"print(repr(({expression})))"],
            timeout_sec=30,
            max_timeout_sec=60,
        )
        return {
            "ok": r.get("exit_code") == 0,
            "result": (r.get("stdout") or "").strip(),
            "stderr": r.get("stderr") or "",
        }

    @mcp.tool
    def python_run_file(
        path: str,
        args: list[str] | None = None,
        timeout_sec: float = 120,
        cwd: str | None = None,
    ) -> dict[str, Any]:
        """Run a .py file with the configured interpreter."""
        p = Path(path).expanduser()
        if not p.is_file():
            return {"ok": False, "error": "file_not_found", "path": str(p)}
        py = _interpreter()
        r = run_capture(
            [py, str(p), *(args or [])],
            cwd=cwd,
            timeout_sec=min(float(timeout_sec), 600),
            max_timeout_sec=600,
        )
        so, t1 = _truncate(r.get("stdout") or "")
        se, t2 = _truncate(r.get("stderr") or "")
        return {
            "ok": r.get("exit_code") == 0 and not r.get("timed_out"),
            "stdout": so,
            "stderr": se,
            "exit_code": r.get("exit_code"),
            "timed_out": r.get("timed_out"),
            "truncated": t1 or t2,
            "script": str(p),
        }

    @mcp.tool
    def python_repl_reset() -> dict[str, Any]:
        """Clear the in-process Python session namespace."""
        _SESSION.clear()
        _SESSION["__name__"] = "__forge_python__"
        return {"ok": True, "message": "session cleared"}

    TOOL_NAMES.update(
        {
            "python_info",
            "python_exec",
            "python_eval",
            "python_run_file",
            "python_repl_reset",
        }
    )
