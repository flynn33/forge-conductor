"""GitHub CLI (gh) tools — reliable local git+PR without remote Copilot MCP."""

from __future__ import annotations

import base64
import json
import re
import shutil
import tempfile
from pathlib import Path
from typing import Any

from forge_conductor.errors import ToolError
from forge_conductor.subprocess_util import noninteractive_env, run_capture

_SHA = re.compile(r"^[0-9a-fA-F]{7,40}$")
_OWNER_REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def _gh() -> str:
    p = shutil.which("gh")
    if not p:
        raise ToolError("gh_not_found", "GitHub CLI (gh) not on PATH", retryable=False)
    return p


def _run_gh(
    args: list[str],
    *,
    cwd: str | None = None,
    timeout_sec: float = 60,
) -> dict[str, Any]:
    env = noninteractive_env(
        {
            "GH_PROMPT_DISABLED": "1",
            "GH_NO_UPDATE_NOTIFIER": "1",
            "GIT_TERMINAL_PROMPT": "0",
        }
    )
    r = run_capture(
        [_gh(), *args],
        cwd=cwd,
        timeout_sec=timeout_sec,
        max_timeout_sec=max(timeout_sec, 120),
        env=env,
        shell=False,
    )
    return r


def _run_git(
    args: list[str],
    *,
    cwd: str | None = None,
    timeout_sec: float = 60,
) -> dict[str, Any]:
    git = shutil.which("git")
    if not git:
        raise ToolError("git_not_found", "git not on PATH", retryable=False)
    return run_capture(
        [git, "-c", "core.pager=", *args],
        cwd=cwd,
        timeout_sec=timeout_sec,
        max_timeout_sec=max(timeout_sec, 180),
        env=noninteractive_env({"GIT_TERMINAL_PROMPT": "0", "GH_PROMPT_DISABLED": "1"}),
        shell=False,
    )


def register(mcp: Any) -> None:
    from forge_conductor.server import TOOL_NAMES

    @mcp.tool
    def gh_whoami() -> dict[str, Any]:
        """Authenticated GitHub user via gh (keyring). Prefer this over remote github MCP."""
        r = _run_gh(["api", "user", "--jq", "{login:.login,name:.name,id:.id}"], timeout_sec=30)
        return {
            "ok": r.get("exit_code") == 0,
            "user": (r.get("stdout") or "").strip(),
            "stderr": r.get("stderr") or "",
            "gh": _gh(),
        }

    @mcp.tool
    def git_fetch(cwd: str, remote: str = "origin") -> dict[str, Any]:
        """git fetch --prune."""
        r = _run_git(["fetch", remote, "--prune"], cwd=cwd, timeout_sec=120)
        return {"ok": r.get("exit_code") == 0, **{k: r.get(k) for k in ("stdout", "stderr", "exit_code", "timed_out")}}

    @mcp.tool
    def git_pull(cwd: str, remote: str = "origin", rebase: bool = False) -> dict[str, Any]:
        """git pull --ff-only (or --rebase)."""
        args = ["pull", "--rebase" if rebase else "--ff-only", remote]
        r = _run_git(args, cwd=cwd, timeout_sec=120)
        return {"ok": r.get("exit_code") == 0, **{k: r.get(k) for k in ("stdout", "stderr", "exit_code", "timed_out")}}

    @mcp.tool
    def git_push(
        cwd: str,
        remote: str = "origin",
        branch: str | None = None,
        set_upstream: bool = True,
        force_with_lease: bool = False,
    ) -> dict[str, Any]:
        """git push. force only via force_with_lease=true (never bare --force)."""
        args = ["push"]
        if force_with_lease:
            args.append("--force-with-lease")
        if set_upstream:
            args.append("-u")
        args.append(remote)
        if branch:
            args.append(branch)
        r = _run_git(args, cwd=cwd, timeout_sec=180)
        return {"ok": r.get("exit_code") == 0, **{k: r.get(k) for k in ("stdout", "stderr", "exit_code", "timed_out")}}

    @mcp.tool
    def git_checkout(cwd: str, ref: str, create: bool = False) -> dict[str, Any]:
        """git checkout ref, or checkout -B ref if create=true."""
        args = ["checkout", "-B" if create else "", ref]
        args = [a for a in args if a]
        if create:
            args = ["checkout", "-B", ref]
        else:
            args = ["checkout", ref]
        r = _run_git(args, cwd=cwd, timeout_sec=60)
        return {"ok": r.get("exit_code") == 0, **{k: r.get(k) for k in ("stdout", "stderr", "exit_code")}}

    @mcp.tool
    def get_repo_file(
        owner: str,
        repo: str,
        path: str = "",
        ref: str | None = None,
    ) -> dict[str, Any]:
        """Read a file or list a directory from GitHub via gh api."""
        path = (path or "").strip().lstrip("/")
        endpoint = f"repos/{owner}/{repo}/contents"
        if path:
            endpoint += f"/{path}"
        if ref:
            endpoint += f"?ref={ref}"
        r = _run_gh(["api", endpoint], timeout_sec=60)
        if r.get("exit_code") != 0:
            return {
                "ok": False,
                "stderr": r.get("stderr"),
                "stdout": r.get("stdout"),
                "exit_code": r.get("exit_code"),
            }
        try:
            data = json.loads(r.get("stdout") or "null")
        except json.JSONDecodeError:
            return {"ok": False, "error": "invalid_json", "stdout": r.get("stdout")}
        if isinstance(data, dict) and data.get("type") == "file" and data.get("encoding") == "base64":
            raw = base64.b64decode(data.get("content") or "")
            text = raw.decode("utf-8", errors="replace")
            truncated = False
            if len(text) > 100_000:
                text = text[:100_000] + "\n...[truncated]..."
                truncated = True
            return {
                "ok": True,
                "path": data.get("path") or path,
                "sha": data.get("sha"),
                "size": data.get("size"),
                "text": text,
                "truncated": truncated,
            }
        if isinstance(data, list):
            return {
                "ok": True,
                "entries": [
                    {
                        "name": i.get("name"),
                        "path": i.get("path"),
                        "type": i.get("type"),
                        "size": i.get("size"),
                    }
                    for i in data
                ],
            }
        return {"ok": True, "raw": data}

    @mcp.tool
    def gh_pr_list(
        cwd: str | None = None,
        repo: str | None = None,
        state: str = "open",
        limit: int = 20,
    ) -> dict[str, Any]:
        """List pull requests via gh pr list."""
        args = [
            "pr",
            "list",
            "--state",
            state,
            "--limit",
            str(max(1, min(int(limit), 100))),
            "--json",
            "number,title,state,headRefName,baseRefName,author,url,isDraft,updatedAt",
        ]
        if repo and _OWNER_REPO.match(repo.strip()):
            args.extend(["--repo", repo.strip()])
        r = _run_gh(args, cwd=cwd, timeout_sec=45)
        if r.get("exit_code") != 0:
            return {"ok": False, "stderr": r.get("stderr"), "stdout": r.get("stdout")}
        try:
            return {"ok": True, "pull_requests": json.loads(r.get("stdout") or "[]")}
        except json.JSONDecodeError:
            return {"ok": False, "error": "invalid_json", "stdout": r.get("stdout")}

    @mcp.tool
    def gh_pr_view(
        number: int,
        cwd: str | None = None,
        repo: str | None = None,
    ) -> dict[str, Any]:
        """View a PR by number (no 'method' parameter — simpler than remote github MCP)."""
        args = [
            "pr",
            "view",
            str(int(number)),
            "--json",
            "number,title,state,body,headRefName,baseRefName,author,url,isDraft,mergeable,additions,deletions",
        ]
        if repo and _OWNER_REPO.match(repo.strip()):
            args.extend(["--repo", repo.strip()])
        r = _run_gh(args, cwd=cwd, timeout_sec=45)
        if r.get("exit_code") != 0:
            return {"ok": False, "stderr": r.get("stderr"), "stdout": r.get("stdout")}
        try:
            return {"ok": True, "pull_request": json.loads(r.get("stdout") or "null")}
        except json.JSONDecodeError:
            return {"ok": False, "error": "invalid_json", "stdout": r.get("stdout")}

    @mcp.tool
    def gh_pr_create(
        title: str,
        body: str = "",
        cwd: str | None = None,
        repo: str | None = None,
        base: str | None = None,
        head: str | None = None,
        draft: bool = False,
        auto_push: bool = True,
    ) -> dict[str, Any]:
        """Create a PR via gh. head must be a branch name (not a commit SHA).

        Auto-rewrites SHA→branch when SHA is HEAD; auto-pushes branch by default.
        Requires cwd= local git checkout path.
        """
        steps: list[str] = []
        if not cwd or not Path(cwd).is_dir():
            return {
                "ok": False,
                "error": "cwd_required",
                "message": "Pass cwd= to the local git repo root (e.g. C:\\\\repos\\\\my-project)",
            }

        # setup-git for push credentials
        _run_gh(["auth", "setup-git"], cwd=cwd, timeout_sec=30)
        steps.append("auth_setup_git")

        br = _run_git(["branch", "--show-current"], cwd=cwd, timeout_sec=15)
        current = (br.get("stdout") or "").strip() or None
        hs = _run_git(["rev-parse", "HEAD"], cwd=cwd, timeout_sec=15)
        head_sha = (hs.get("stdout") or "").strip()

        raw = (head or "").strip() or None
        if raw and _SHA.match(raw):
            ver = _run_git(
                ["rev-parse", "--verify", f"{raw}^{{commit}}"], cwd=cwd, timeout_sec=15
            )
            full = (ver.get("stdout") or "").strip() if ver.get("exit_code") == 0 else ""
            is_head = bool(
                full
                and head_sha
                and (full == head_sha or head_sha.lower().startswith(raw.lower()))
            )
            if not is_head:
                return {
                    "ok": False,
                    "error": "invalid_head",
                    "message": "head must be a branch name, not a commit SHA. "
                    "Omit head to use current branch, or pass e.g. work/my-feature.",
                    "head": raw,
                    "current_branch": current,
                }
            if not current or current in {"main", "master", "develop", "trunk"}:
                current = f"work/pr-{head_sha[:8]}"
                co = _run_git(["checkout", "-B", current], cwd=cwd, timeout_sec=30)
                if co.get("exit_code") != 0:
                    return {
                        "ok": False,
                        "error": "branch_create_failed",
                        "stderr": co.get("stderr"),
                    }
                steps.append(f"created_branch:{current}")
            head = current
            steps.append(f"rewrote_sha_to_branch:{head}")
        elif raw:
            head = raw
        else:
            if not current:
                return {
                    "ok": False,
                    "error": "no_branch",
                    "message": "HEAD detached and no head= provided",
                }
            head = current
            steps.append(f"default_head:{head}")

        if not re.fullmatch(r"[A-Za-z0-9._/-]+", head or ""):
            return {"ok": False, "error": "invalid_head", "head": head}

        if current != head:
            co = _run_git(["checkout", "-B", head], cwd=cwd, timeout_sec=30)
            if co.get("exit_code") != 0:
                return {
                    "ok": False,
                    "error": "checkout_failed",
                    "stderr": co.get("stderr"),
                    "head": head,
                }
            steps.append(f"checkout_B:{head}")

        if not base:
            db = _run_gh(
                [
                    "repo",
                    "view",
                    "--json",
                    "defaultBranchRef",
                    "--jq",
                    ".defaultBranchRef.name",
                ],
                cwd=cwd,
                timeout_sec=30,
            )
            base = (db.get("stdout") or "").strip() or "main"
            steps.append(f"default_base:{base}")

        if auto_push:
            push = _run_git(
                ["push", "-u", "origin", f"HEAD:refs/heads/{head}"],
                cwd=cwd,
                timeout_sec=180,
            )
            steps.append("push_ok" if push.get("exit_code") == 0 else "push_failed")
            if push.get("exit_code") != 0:
                return {
                    "ok": False,
                    "error": "push_failed",
                    "stderr": push.get("stderr"),
                    "stdout": push.get("stdout"),
                    "hint": "gh auth login && gh auth setup-git",
                    "steps": steps,
                    "head": head,
                }

        args = ["pr", "create", "--base", base, "--head", head]
        if draft:
            args.append("--draft")
        if repo and _OWNER_REPO.match(repo.strip()):
            args.extend(["--repo", repo.strip()])

        title = (title or "").strip()
        if not title:
            return {"ok": False, "error": "empty_title"}
        args.extend(["--title", title])
        body_path = None
        try:
            fd, body_path = tempfile.mkstemp(prefix="forge-pr-body-", suffix=".md")
            import os as _os

            _os.close(fd)
            Path(body_path).write_text(body or "", encoding="utf-8")
            args.extend(["--body-file", body_path])
            r = _run_gh(args, cwd=cwd, timeout_sec=60)
        finally:
            if body_path:
                Path(body_path).unlink(missing_ok=True)

        out: dict[str, Any] = {
            "ok": r.get("exit_code") == 0,
            "exit_code": r.get("exit_code"),
            "stdout": r.get("stdout"),
            "stderr": r.get("stderr"),
            "head": head,
            "base": base,
            "steps": steps,
            "cwd": cwd,
        }
        if r.get("exit_code") == 0:
            lines = (r.get("stdout") or "").strip().splitlines()
            out["url"] = lines[-1] if lines else None
            return out

        err = (r.get("stderr") or "") + "\n" + (r.get("stdout") or "")
        hints = []
        if "no history in common" in err.lower():
            hints.append(
                "Branch and base share no git history. Rebuild onto origin/"
                + (base or "main")
                + "."
            )
        elif "No commits between" in err:
            hints.append("No commits between head and base on remote.")
        if "Authentication" in err or "Repository not found" in err:
            hints.append("gh auth login && gh auth setup-git")
        out["error"] = "pr_create_failed"
        out["message"] = (r.get("stderr") or r.get("stdout") or "failed")[:500]
        out["hint"] = " ".join(hints) if hints else None
        return out

    TOOL_NAMES.update(
        {
            "gh_whoami",
            "git_fetch",
            "git_pull",
            "git_push",
            "git_checkout",
            "get_repo_file",
            "gh_pr_list",
            "gh_pr_view",
            "gh_pr_create",
        }
    )
