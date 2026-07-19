"""Tests for git tool pack (skipped when git is not on PATH)."""

from __future__ import annotations

import shutil
import subprocess

import pytest

from forge_conductor.tools import git as git_tools

pytestmark = pytest.mark.skipif(
    shutil.which("git") is None,
    reason="git not on PATH",
)


def _git(args: list[str], cwd) -> None:
    subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        check=True,
        capture_output=True,
        text=True,
    )


def test_git_status_diff_add_commit_log_show_branch_stash(tmp_path, forge_home):
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(["init"], repo)
    _git(["config", "user.email", "test@local"], repo)
    _git(["config", "user.name", "Test User"], repo)
    # Avoid "master"/"main" surprises for branch assertions
    _git(["checkout", "-b", "main"], repo)

    f = repo / "note.txt"
    f.write_text("v1\n", encoding="utf-8")

    status = git_tools.svc_status(cwd=str(repo))
    assert status["exit_code"] == 0
    assert status["clean"] is False
    assert "note.txt" in status["porcelain"]

    # Unstaged content appears in diff
    f.write_text("v1\nchanged\n", encoding="utf-8")
    # Need an initial commit first for meaningful show later — add & commit clean baseline
    # Reset file and do full lifecycle as specified
    f.write_text("hello git\n", encoding="utf-8")

    add = git_tools.svc_add(paths="note.txt", cwd=str(repo))
    assert add["exit_code"] == 0

    commit = git_tools.svc_commit(message="initial commit", cwd=str(repo))
    assert commit["exit_code"] == 0

    status_clean = git_tools.svc_status(cwd=str(repo))
    assert status_clean["clean"] is True

    diff_clean = git_tools.svc_diff(cwd=str(repo))
    assert diff_clean["exit_code"] == 0
    assert (diff_clean["diff"] or "").strip() == ""

    log = git_tools.svc_log(cwd=str(repo), max_count=5)
    assert log["exit_code"] == 0
    assert "initial commit" in log["log"]

    show = git_tools.svc_show(rev="HEAD", cwd=str(repo))
    assert show["exit_code"] == 0
    assert "initial commit" in show["output"] or "hello git" in show["output"]

    branch = git_tools.svc_branch(cwd=str(repo))
    assert branch["exit_code"] == 0
    assert branch["current"] is not None
    assert any("main" in b or branch["current"] == b for b in branch["branches"])

    # Dirty tree then stash roundtrip
    f.write_text("hello git\nstashed change\n", encoding="utf-8")
    status_dirty = git_tools.svc_status(cwd=str(repo))
    assert status_dirty["clean"] is False

    stashed = git_tools.svc_stash(action="push", cwd=str(repo), message="wip")
    assert stashed["exit_code"] == 0
    assert git_tools.svc_status(cwd=str(repo))["clean"] is True

    listed = git_tools.svc_stash(action="list", cwd=str(repo))
    assert listed["exit_code"] == 0
    assert (listed["stdout"] or "").strip() != ""

    popped = git_tools.svc_stash(action="pop", cwd=str(repo))
    assert popped["exit_code"] == 0
    assert "stashed change" in f.read_text(encoding="utf-8")
