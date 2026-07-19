"""Search tools: content and filename search + FastMCP registration.

Designed to finish under typical MCP host timeouts (~30–60s). Prefer git-grep/rg
when available; pure-Python walk is bounded by time and file-size caps.
"""

from __future__ import annotations

import fnmatch
import os
import re
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any

from forge_conductor.subprocess_util import run_capture

# Skip heavy/binary-ish directories by default
_DEFAULT_SKIP_DIRS = {
    ".git",
    ".hg",
    ".svn",
    "__pycache__",
    ".venv",
    "venv",
    "node_modules",
    ".tox",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".next",
    ".nuxt",
    "dist",
    "build",
    "out",
    "target",
    "bin",
    "obj",
    "coverage",
    ".cache",
    ".turbo",
    ".yarn",
    "Pods",
    "vendor",
    "third_party",
    "third-party",
    ".lmstudio",
    ".forge-conductor",
}

# Skip files larger than this (bytes) in pure-Python path
_MAX_FILE_BYTES = 1_500_000
# Soft wall-clock budget so LM Studio MCP (-32001) does not fire first
_DEFAULT_BUDGET_SEC = 20.0


def _iter_files(
    root: Path,
    *,
    skip_dirs: set[str] | None = None,
    budget_sec: float = _DEFAULT_BUDGET_SEC,
    deadline: float | None = None,
) -> list[Path]:
    skip = skip_dirs if skip_dirs is not None else _DEFAULT_SKIP_DIRS
    end = deadline if deadline is not None else (time.monotonic() + budget_sec)
    files: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        if time.monotonic() > end:
            break
        dirnames[:] = [d for d in dirnames if d not in skip]
        # Prefer deterministic smaller trees first when under budget
        for name in filenames:
            files.append(Path(dirpath) / name)
    return files


def _git_grep(
    query: str,
    root: Path,
    *,
    case_sensitive: bool,
    max_results: int,
    budget_sec: float,
) -> dict[str, Any] | None:
    """Run git-grep with stdin=DEVNULL (required under MCP stdio hosts)."""
    git = shutil.which("git")
    if not git:
        return None
    # Must be inside a git work tree. CRITICAL: never inherit MCP stdin pipe.
    chk = run_capture(
        [git, "-C", str(root), "rev-parse", "--is-inside-work-tree"],
        timeout_sec=5.0,
        max_timeout_sec=10.0,
    )
    if chk.get("timed_out") or chk.get("exit_code") not in (0,):
        return None
    if "true" not in (chk.get("stdout") or "").lower():
        return None

    args = [
        git,
        "-C",
        str(root),
        "grep",
        "-n",
        "-I",  # skip binary
        f"-m{max(1, max_results)}",
    ]
    if not case_sensitive:
        args.append("-i")
    args.extend(["-e", query, "--", "."])
    proc = run_capture(
        args,
        timeout_sec=max(5.0, float(budget_sec)),
        max_timeout_sec=max(10.0, float(budget_sec) + 5.0),
    )
    if proc.get("timed_out"):
        return None
    # git grep returns 1 when no matches
    if proc.get("exit_code") not in (0, 1):
        return None

    hits: list[dict[str, Any]] = []
    for line in (proc.get("stdout") or "").splitlines():
        # path:line:text  (Windows paths may include drive; git uses relative)
        parts = line.split(":", 2)
        if len(parts) < 3:
            continue
        rel, lineno_s, text = parts[0], parts[1], parts[2]
        try:
            lineno = int(lineno_s)
        except ValueError:
            continue
        path = str((root / rel).resolve())
        hits.append({"path": path, "line": lineno, "text": text})
        if len(hits) >= max_results:
            break
    return {
        "root": str(root),
        "query": query,
        "hits": hits,
        "truncated": len(hits) >= max_results,
        "count": len(hits),
        "engine": "git-grep",
    }


def _rg_search(
    query: str,
    root: Path,
    *,
    case_sensitive: bool,
    max_results: int,
    glob: str | None,
    budget_sec: float,
) -> dict[str, Any] | None:
    rg = shutil.which("rg")
    if not rg:
        return None
    args = [
        rg,
        "--line-number",
        "--no-heading",
        "--color",
        "never",
        "--max-count",
        str(max(1, max_results)),
        "--max-filesize",
        "1.5M",
    ]
    if not case_sensitive:
        args.append("-i")
    if glob:
        args.extend(["--glob", glob])
    args.extend(["--fixed-strings", "--", query, str(root)])
    proc = run_capture(
        args,
        timeout_sec=max(5.0, float(budget_sec)),
        max_timeout_sec=max(10.0, float(budget_sec) + 5.0),
    )
    if proc.get("timed_out"):
        return None
    if proc.get("exit_code") not in (0, 1):
        return None
    hits: list[dict[str, Any]] = []
    for line in (proc.get("stdout") or "").splitlines():
        # path:line:text
        # Windows: C:\path:12:text — split carefully from the right of line number
        m = re.match(r"^(.*):(\d+):(.*)$", line)
        if not m:
            continue
        hits.append(
            {"path": m.group(1), "line": int(m.group(2)), "text": m.group(3)}
        )
        if len(hits) >= max_results:
            break
    return {
        "root": str(root),
        "query": query,
        "hits": hits,
        "truncated": len(hits) >= max_results,
        "count": len(hits),
        "engine": "rg",
    }


def svc_search_text(
    query: str,
    root: str = ".",
    *,
    case_sensitive: bool = False,
    max_results: int = 50,
    glob: str | None = None,
    budget_sec: float = _DEFAULT_BUDGET_SEC,
) -> dict[str, Any]:
    """Search file contents under *root* for *query*.

    Strategy (fast → slow), always wall-clock bounded:
    1. ``rg`` if on PATH
    2. ``git grep`` inside a work tree (ignores untracked unless needed)
    3. Pure Python walk with size/skip caps and soft timeout
    """
    # Debug breadcrumb for MCP hang diagnosis (FORGE_SEARCH_DEBUG=1)
    _dbg = os.environ.get("FORGE_SEARCH_DEBUG", "").strip() in {"1", "true", "yes"}
    _dbg_path = Path(os.environ.get("FORGE_CONDUCTOR_HOME", str(Path.home() / ".forge-conductor"))) / "logs" / "search_debug.log"

    def _log(msg: str) -> None:
        if not _dbg:
            return
        try:
            _dbg_path.parent.mkdir(parents=True, exist_ok=True)
            with _dbg_path.open("a", encoding="utf-8") as fh:
                fh.write(f"{time.time():.3f} {msg}\n")
        except OSError:
            pass

    _log(f"enter query={query!r} root={root!r}")
    base = Path(root).expanduser().resolve()
    if not base.is_dir():
        raise NotADirectoryError(f"Not a directory: {base}")
    _log(f"resolved base={base}")

    budget = float(budget_sec) if budget_sec and budget_sec > 0 else _DEFAULT_BUDGET_SEC
    max_results = max(1, min(int(max_results), 200))

    # External engines first (respect host timeout)
    if not glob:
        # git grep does not apply name globs the same way; skip if glob set
        _log("try git-grep")
        gg = _git_grep(
            query,
            base,
            case_sensitive=case_sensitive,
            max_results=max_results,
            budget_sec=budget,
        )
        _log(f"git-grep done {gg is not None}")
        if gg is not None:
            return gg

    _log("try rg")
    rg = _rg_search(
        query,
        base,
        case_sensitive=case_sensitive,
        max_results=max_results,
        glob=glob,
        budget_sec=budget,
    )
    _log(f"rg done {rg is not None}")
    if rg is not None:
        return rg
    _log("python walk")

    flags = 0 if case_sensitive else re.IGNORECASE
    pattern = re.compile(re.escape(query), flags)

    hits: list[dict[str, Any]] = []
    deadline = time.monotonic() + budget
    timed_out = False
    files_scanned = 0

    for path in _iter_files(base, deadline=deadline):
        if time.monotonic() > deadline:
            timed_out = True
            break
        if glob and not fnmatch.fnmatch(path.name, glob):
            continue
        try:
            st = path.stat()
            if st.st_size > _MAX_FILE_BYTES or st.st_size == 0:
                continue
            # skip likely binary by extension
            if path.suffix.lower() in {
                ".png",
                ".jpg",
                ".jpeg",
                ".gif",
                ".webp",
                ".ico",
                ".pdf",
                ".zip",
                ".7z",
                ".rar",
                ".exe",
                ".dll",
                ".pdb",
                ".gguf",
                ".bin",
                ".wasm",
                ".so",
                ".dylib",
                ".o",
                ".a",
                ".lib",
                ".pyc",
                ".pyo",
            }:
                continue
            with path.open("rb") as fh:
                raw = fh.read(_MAX_FILE_BYTES + 1)
            if b"\x00" in raw[:8192]:
                continue
            text = raw.decode("utf-8", errors="replace")
        except OSError:
            continue
        files_scanned += 1
        for lineno, line in enumerate(text.splitlines(), start=1):
            if pattern.search(line):
                hits.append(
                    {
                        "path": str(path),
                        "line": lineno,
                        "text": line[:500],
                    }
                )
                if len(hits) >= max_results:
                    return {
                        "root": str(base),
                        "query": query,
                        "hits": hits,
                        "truncated": True,
                        "count": len(hits),
                        "engine": "python",
                        "files_scanned": files_scanned,
                        "timed_out": False,
                    }
        if time.monotonic() > deadline:
            timed_out = True
            break

    out: dict[str, Any] = {
        "root": str(base),
        "query": query,
        "hits": hits,
        "truncated": timed_out or len(hits) >= max_results,
        "count": len(hits),
        "engine": "python",
        "files_scanned": files_scanned,
        "timed_out": timed_out,
    }
    if timed_out:
        out["hint"] = "Search hit time budget; narrow root= or set glob= (e.g. *.md)."
    _log(f"return python count={len(hits)} timed_out={timed_out}")
    return out


def svc_search_files(
    pattern: str,
    root: str = ".",
    *,
    max_results: int = 200,
    budget_sec: float = _DEFAULT_BUDGET_SEC,
) -> dict[str, Any]:
    """Find files whose names match *pattern* (glob, e.g. ``*.py`` or ``*foo*``)."""
    base = Path(root).expanduser().resolve()
    if not base.is_dir():
        raise NotADirectoryError(f"Not a directory: {base}")

    deadline = time.monotonic() + float(budget_sec)
    matches: list[str] = []
    timed_out = False
    for path in _iter_files(base, deadline=deadline):
        if time.monotonic() > deadline:
            timed_out = True
            break
        rel = str(path.relative_to(base)).replace("\\", "/")
        if fnmatch.fnmatch(path.name, pattern) or fnmatch.fnmatch(rel, pattern):
            matches.append(str(path))
            if len(matches) >= max_results:
                return {
                    "root": str(base),
                    "pattern": pattern,
                    "matches": matches,
                    "truncated": True,
                    "count": len(matches),
                    "timed_out": False,
                }
    return {
        "root": str(base),
        "pattern": pattern,
        "matches": matches,
        "truncated": timed_out or len(matches) >= max_results,
        "count": len(matches),
        "timed_out": timed_out,
    }


def register(mcp: Any) -> None:
    """Register search tools on *mcp* and record names in TOOL_NAMES."""
    from forge_conductor.server import TOOL_NAMES

    @mcp.tool
    def search_text(
        query: str,
        root: str = ".",
        case_sensitive: bool = False,
        max_results: int = 50,
        glob: str = "",
    ) -> dict[str, Any]:
        """Search file contents under root for a text query.

        Prefer a narrow root (subfolder) or glob (e.g. ``*.md``) on large repos.
        Uses git-grep/rg when available; always time-bounded for MCP hosts.
        """
        # Avoid Optional/None defaults — some FastMCP/host paths mishandle nullables.
        glob_arg = glob.strip() or None
        return svc_search_text(
            query,
            root=root,
            case_sensitive=case_sensitive,
            max_results=max_results,
            glob=glob_arg,
        )

    @mcp.tool
    def search_files(
        pattern: str,
        root: str = ".",
        max_results: int = 200,
    ) -> dict[str, Any]:
        """Find files by name/glob pattern under root (time-bounded)."""
        return svc_search_files(pattern, root=root, max_results=max_results)

    TOOL_NAMES.update(
        {
            "search_text",
            "search_files",
        }
    )
