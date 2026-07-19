"""Git tools via subprocess: service layer + FastMCP registration."""

from __future__ import annotations

import shutil
from pathlib import Path
from typing import Any

from forge_conductor.errors import ToolError
from forge_conductor.subprocess_util import run_capture

# Git porcelain should return quickly; never hang MCP hosts.
_GIT_TIMEOUT_SEC = 25.0


def _git_bin() -> str:
    path = shutil.which("git")
    if path is None:
        raise ToolError(
            "git_not_found",
            "git executable not found on PATH",
            retryable=False,
        )
    return path


def _run_git(
    args: list[str],
    *,
    cwd: str | Path | None = None,
    check: bool = False,
    timeout_sec: float = _GIT_TIMEOUT_SEC,
) -> dict[str, Any]:
    """Run git with *args*; hard timeout; non-interactive env (no pager/prompt)."""
    git = _git_bin()
    # Disable pager via -c as well as env (env alone is not always enough).
    full = [git, "-c", "core.pager=", "-c", "color.ui=false", *args]
    completed = run_capture(
        full,
        cwd=str(cwd) if cwd is not None else None,
        timeout_sec=timeout_sec,
        shell=False,
    )
    if completed.get("timed_out"):
        raise ToolError(
            "timeout",
            completed.get("error")
            or f"git {' '.join(args)} timed out after {timeout_sec}s",
            retryable=True,
            detail={"args": args, "cwd": str(cwd) if cwd else None},
        )
    result: dict[str, Any] = {
        "stdout": completed.get("stdout") or "",
        "stderr": completed.get("stderr") or "",
        "exit_code": completed.get("exit_code"),
        "args": args,
        "duration_ms": completed.get("duration_ms"),
        "truncated": completed.get("truncated"),
    }
    if check and result["exit_code"] not in (0, None):
        raise ToolError(
            "git_failed",
            f"git {' '.join(args)} failed (exit {result['exit_code']}): "
            f"{(result['stderr'] or result['stdout'] or '').strip()}",
            retryable=False,
            detail={"args": args, "exit_code": result["exit_code"]},
        )
    return result


def _audit_mutating(tool: str, args: dict[str, Any], *, client_id: str | None) -> None:
    if client_id is None:
        return
    from forge_conductor import audit
    from forge_conductor.server import get_ctx

    ctx = get_ctx()
    if ctx is None:
        return
    audit.append(
        ctx.conn,
        tool=tool,
        args=args,
        status="ok",
        client_id=client_id,
        mutating=True,
    )


def svc_status(cwd: str | None = None) -> dict[str, Any]:
    """Return git status porcelain + branch summary."""
    porcelain = _run_git(["status", "--porcelain"], cwd=cwd)
    branch = _run_git(["status", "-sb"], cwd=cwd)
    return {
        "cwd": str(Path(cwd).resolve()) if cwd else str(Path.cwd()),
        "porcelain": porcelain["stdout"],
        "branch_header": (branch["stdout"].splitlines() or [""])[0],
        "exit_code": porcelain["exit_code"],
        "stderr": porcelain["stderr"] or branch["stderr"],
        "clean": porcelain["exit_code"] == 0 and not (porcelain["stdout"] or "").strip(),
    }


def svc_diff(
    cwd: str | None = None,
    *,
    staged: bool = False,
    path: str | None = None,
) -> dict[str, Any]:
    """Return git diff (working tree or staged)."""
    args = ["diff"]
    if staged:
        args.append("--cached")
    if path:
        args.extend(["--", path])
    result = _run_git(args, cwd=cwd)
    return {
        "cwd": str(Path(cwd).resolve()) if cwd else str(Path.cwd()),
        "diff": result["stdout"],
        "exit_code": result["exit_code"],
        "stderr": result["stderr"],
        "staged": staged,
    }


def svc_log(
    cwd: str | None = None,
    *,
    max_count: int = 20,
    oneline: bool = True,
) -> dict[str, Any]:
    """Return recent commit log."""
    args = ["log", f"-n{max_count}"]
    if oneline:
        args.append("--oneline")
    result = _run_git(args, cwd=cwd)
    return {
        "cwd": str(Path(cwd).resolve()) if cwd else str(Path.cwd()),
        "log": result["stdout"],
        "exit_code": result["exit_code"],
        "stderr": result["stderr"],
    }


def svc_branch(cwd: str | None = None, *, all_branches: bool = False) -> dict[str, Any]:
    """List branches."""
    args = ["branch"]
    if all_branches:
        args.append("-a")
    result = _run_git(args, cwd=cwd)
    lines = [ln.strip() for ln in (result["stdout"] or "").splitlines() if ln.strip()]
    current = None
    names: list[str] = []
    for ln in lines:
        if ln.startswith("* "):
            name = ln[2:].strip()
            current = name
            names.append(name)
        else:
            names.append(ln.lstrip("* ").strip())
    return {
        "cwd": str(Path(cwd).resolve()) if cwd else str(Path.cwd()),
        "branches": names,
        "current": current,
        "raw": result["stdout"],
        "exit_code": result["exit_code"],
        "stderr": result["stderr"],
    }


def svc_show(
    rev: str = "HEAD",
    cwd: str | None = None,
    *,
    path: str | None = None,
) -> dict[str, Any]:
    """Show a revision (or file at revision)."""
    args = ["show", rev]
    if path:
        args.extend(["--", path])
    result = _run_git(args, cwd=cwd)
    return {
        "cwd": str(Path(cwd).resolve()) if cwd else str(Path.cwd()),
        "rev": rev,
        "output": result["stdout"],
        "exit_code": result["exit_code"],
        "stderr": result["stderr"],
    }


def svc_add(
    paths: list[str] | str | None = None,
    cwd: str | None = None,
    *,
    all_files: bool = False,
    client_id: str | None = None,
) -> dict[str, Any]:
    """Stage paths (or all with all_files=True)."""
    args = ["add"]
    if all_files:
        args.append("-A")
    elif paths is None:
        args.append(".")
    elif isinstance(paths, str):
        args.append(paths)
    else:
        args.extend(paths)
    result = _run_git(args, cwd=cwd)
    out = {
        "cwd": str(Path(cwd).resolve()) if cwd else str(Path.cwd()),
        "exit_code": result["exit_code"],
        "stdout": result["stdout"],
        "stderr": result["stderr"],
    }
    if result["exit_code"] == 0:
        _audit_mutating("git_add", {"paths": paths, "all_files": all_files, "cwd": cwd}, client_id=client_id)
    return out


def svc_commit(
    message: str,
    cwd: str | None = None,
    *,
    allow_empty: bool = False,
    client_id: str | None = None,
) -> dict[str, Any]:
    """Create a commit with *message*."""
    args = ["commit", "-m", message]
    if allow_empty:
        args.append("--allow-empty")
    result = _run_git(args, cwd=cwd)
    out = {
        "cwd": str(Path(cwd).resolve()) if cwd else str(Path.cwd()),
        "exit_code": result["exit_code"],
        "stdout": result["stdout"],
        "stderr": result["stderr"],
        "message": message,
    }
    if result["exit_code"] == 0:
        _audit_mutating(
            "git_commit",
            {"message": message, "cwd": cwd},
            client_id=client_id,
        )
    return out


def svc_stash(
    action: str = "push",
    cwd: str | None = None,
    *,
    message: str | None = None,
    client_id: str | None = None,
) -> dict[str, Any]:
    """Stash operations: push, pop, list, apply, drop."""
    action = (action or "push").lower()
    if action == "list":
        args = ["stash", "list"]
    elif action == "pop":
        args = ["stash", "pop"]
    elif action == "apply":
        args = ["stash", "apply"]
    elif action == "drop":
        args = ["stash", "drop"]
    else:
        args = ["stash", "push"]
        if message:
            args.extend(["-m", message])
    result = _run_git(args, cwd=cwd)
    out = {
        "cwd": str(Path(cwd).resolve()) if cwd else str(Path.cwd()),
        "action": action,
        "exit_code": result["exit_code"],
        "stdout": result["stdout"],
        "stderr": result["stderr"],
    }
    if action in {"push", "pop", "apply", "drop"} and result["exit_code"] == 0:
        _audit_mutating(
            "git_stash",
            {"action": action, "message": message, "cwd": cwd},
            client_id=client_id,
        )
    return out


def _client_id_from_ctx() -> str | None:
    from forge_conductor.server import get_ctx

    ctx = get_ctx()
    return ctx.client_id if ctx is not None else None


def register(mcp: Any) -> None:
    """Register git tools on *mcp* and record names in TOOL_NAMES."""
    from forge_conductor.server import TOOL_NAMES

    @mcp.tool
    def git_status(cwd: str | None = None) -> dict[str, Any]:
        """Return git working tree status."""
        return svc_status(cwd=cwd)

    @mcp.tool
    def git_diff(
        cwd: str | None = None,
        staged: bool = False,
        path: str | None = None,
    ) -> dict[str, Any]:
        """Return git diff for working tree or staged changes."""
        return svc_diff(cwd=cwd, staged=staged, path=path)

    @mcp.tool
    def git_log(
        cwd: str | None = None,
        max_count: int = 20,
        oneline: bool = True,
    ) -> dict[str, Any]:
        """Return recent git commit log."""
        return svc_log(cwd=cwd, max_count=max_count, oneline=oneline)

    @mcp.tool
    def git_branch(cwd: str | None = None, all_branches: bool = False) -> dict[str, Any]:
        """List git branches."""
        return svc_branch(cwd=cwd, all_branches=all_branches)

    @mcp.tool
    def git_show(
        rev: str = "HEAD",
        cwd: str | None = None,
        path: str | None = None,
    ) -> dict[str, Any]:
        """Show a git revision (commit/tree/blob)."""
        return svc_show(rev=rev, cwd=cwd, path=path)

    @mcp.tool
    def git_add(
        paths: list[str] | str | None = None,
        cwd: str | None = None,
        all_files: bool = False,
    ) -> dict[str, Any]:
        """Stage files for commit."""
        return svc_add(
            paths=paths,
            cwd=cwd,
            all_files=all_files,
            client_id=_client_id_from_ctx(),
        )

    @mcp.tool
    def git_commit(
        message: str,
        cwd: str | None = None,
        allow_empty: bool = False,
    ) -> dict[str, Any]:
        """Create a git commit."""
        return svc_commit(
            message=message,
            cwd=cwd,
            allow_empty=allow_empty,
            client_id=_client_id_from_ctx(),
        )

    @mcp.tool
    def git_stash(
        action: str = "push",
        cwd: str | None = None,
        message: str | None = None,
    ) -> dict[str, Any]:
        """Git stash: push, pop, list, apply, or drop."""
        return svc_stash(
            action=action,
            cwd=cwd,
            message=message,
            client_id=_client_id_from_ctx(),
        )

    TOOL_NAMES.update(
        {
            "git_status",
            "git_diff",
            "git_log",
            "git_branch",
            "git_show",
            "git_add",
            "git_commit",
            "git_stash",
        }
    )
