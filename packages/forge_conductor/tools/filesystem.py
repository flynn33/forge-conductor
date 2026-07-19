"""Filesystem tools: service layer + FastMCP registration."""

from __future__ import annotations

import shutil
from pathlib import Path
from typing import Any


def _resolve(path: str | Path) -> Path:
    """Resolve *path* (absolute or relative to cwd) without requiring existence."""
    return Path(path).expanduser().resolve()


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


def svc_read(path: str, *, encoding: str = "utf-8") -> dict[str, Any]:
    """Read a text file and return path + content.

    Missing / non-file paths return a structured error payload (do not raise).
    """
    from forge_conductor.errors import ToolError, tool_error_payload

    p = _resolve(path)
    if not p.is_file():
        return tool_error_payload(
            ToolError(
                "not_found",
                f"Not a file: {p}",
                retryable=False,
                detail={"path": str(p)},
            )
        )
    content = p.read_text(encoding=encoding)
    return {"path": str(p), "content": content, "size": len(content.encode(encoding))}


def svc_write(
    path: str,
    content: str,
    *,
    encoding: str = "utf-8",
    client_id: str | None = None,
) -> dict[str, Any]:
    """Write text content to a file (create or overwrite)."""
    p = _resolve(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding=encoding)
    result = {"path": str(p), "bytes_written": len(content.encode(encoding))}
    _audit_mutating(
        "fs_write",
        {"path": str(p), "bytes_written": result["bytes_written"]},
        client_id=client_id,
    )
    return result


def svc_edit(
    path: str,
    old: str,
    new: str,
    *,
    encoding: str = "utf-8",
    replace_all: bool = False,
    client_id: str | None = None,
) -> dict[str, Any]:
    """String-replace edit of a text file."""
    from forge_conductor.errors import ToolError, tool_error_payload

    p = _resolve(path)
    if not p.is_file():
        return tool_error_payload(
            ToolError(
                "not_found",
                f"Not a file: {p}",
                retryable=False,
                detail={"path": str(p)},
            )
        )
    text = p.read_text(encoding=encoding)
    if old not in text:
        return tool_error_payload(
            ToolError(
                "not_found",
                f"old string not found in {p}",
                retryable=False,
                detail={"path": str(p)},
            )
        )
    count = text.count(old) if replace_all else 1
    if replace_all:
        updated = text.replace(old, new)
    else:
        updated = text.replace(old, new, 1)
    p.write_text(updated, encoding=encoding)
    result = {"path": str(p), "replacements": count}
    _audit_mutating(
        "fs_edit",
        {"path": str(p), "replacements": count},
        client_id=client_id,
    )
    return result


def svc_list(path: str = ".") -> dict[str, Any]:
    """List directory entries (non-recursive).

    Missing paths return a structured error payload (never raise) so MCP hosts
    stay connected when models probe bad paths.
    """
    from forge_conductor.errors import ToolError, tool_error_payload

    p = _resolve(path)
    if not p.is_dir():
        return tool_error_payload(
            ToolError(
                "not_found",
                f"Not a directory: {p}",
                retryable=False,
                detail={"path": str(p)},
            )
        )
    entries: list[dict[str, Any]] = []
    for child in sorted(p.iterdir(), key=lambda c: c.name.lower()):
        entries.append(
            {
                "name": child.name,
                "path": str(child),
                "is_dir": child.is_dir(),
                "is_file": child.is_file(),
            }
        )
    return {"path": str(p), "entries": entries}


def svc_glob(pattern: str, root: str = ".") -> dict[str, Any]:
    """Glob files under *root* matching *pattern* (recursive ** supported)."""
    from forge_conductor.errors import ToolError, tool_error_payload

    base = _resolve(root)
    if not base.is_dir():
        return tool_error_payload(
            ToolError(
                "not_found",
                f"Not a directory: {base}",
                retryable=False,
                detail={"path": str(base), "pattern": pattern},
            )
        )
    matches = sorted(str(m) for m in base.glob(pattern) if m.is_file() or m.is_dir())
    return {"root": str(base), "pattern": pattern, "matches": matches}


def svc_stat(path: str) -> dict[str, Any]:
    """Return file/directory metadata.

    Missing paths return ``exists=False`` payload (never raise) — probing for
    cmake/tools is a normal agent pattern and must not crash the MCP server.
    """
    p = _resolve(path)
    if not p.exists():
        return {
            "path": str(p),
            "exists": False,
            "is_file": False,
            "is_dir": False,
            "size": None,
            "mtime": None,
            "mode": None,
            "code": "not_found",
            "message": f"Path not found: {p}",
        }
    st = p.stat()
    return {
        "path": str(p),
        "exists": True,
        "is_file": p.is_file(),
        "is_dir": p.is_dir(),
        "size": st.st_size,
        "mtime": st.st_mtime,
        "mode": oct(st.st_mode),
    }


def svc_mkdir(
    path: str,
    *,
    parents: bool = True,
    exist_ok: bool = True,
    client_id: str | None = None,
) -> dict[str, Any]:
    """Create a directory."""
    p = _resolve(path)
    p.mkdir(parents=parents, exist_ok=exist_ok)
    result = {"path": str(p), "created": True}
    _audit_mutating("fs_mkdir", {"path": str(p)}, client_id=client_id)
    return result


def svc_delete(
    path: str,
    *,
    recursive: bool = False,
    client_id: str | None = None,
) -> dict[str, Any]:
    """Delete a file or directory."""
    from forge_conductor.errors import ToolError, tool_error_payload

    p = _resolve(path)
    if not p.exists():
        return tool_error_payload(
            ToolError(
                "not_found",
                f"Path not found: {p}",
                retryable=False,
                detail={"path": str(p)},
            )
        )
    if p.is_dir():
        if recursive:
            shutil.rmtree(p)
        else:
            p.rmdir()
    else:
        p.unlink()
    result = {"path": str(p), "deleted": True}
    _audit_mutating(
        "fs_delete",
        {"path": str(p), "recursive": recursive},
        client_id=client_id,
    )
    return result


def svc_move(
    src: str,
    dest: str,
    *,
    client_id: str | None = None,
) -> dict[str, Any]:
    """Move/rename a path."""
    from forge_conductor.errors import ToolError, tool_error_payload

    s = _resolve(src)
    d = _resolve(dest)
    if not s.exists():
        return tool_error_payload(
            ToolError(
                "not_found",
                f"Source not found: {s}",
                retryable=False,
                detail={"src": str(s), "dest": str(d)},
            )
        )
    d.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(s), str(d))
    result = {"src": str(s), "dest": str(d)}
    _audit_mutating(
        "fs_move",
        {"src": str(s), "dest": str(d)},
        client_id=client_id,
    )
    return result


def _client_id_from_ctx() -> str | None:
    from forge_conductor.server import get_ctx

    ctx = get_ctx()
    return ctx.client_id if ctx is not None else None


def _safe(fn, *args, **kwargs) -> dict[str, Any]:
    """Never let filesystem tools raise into FastMCP (prevents host disconnect)."""
    from forge_conductor.errors import tool_error_payload

    try:
        return fn(*args, **kwargs)
    except Exception as exc:  # noqa: BLE001 — MCP boundary
        return tool_error_payload(exc)


def register(mcp: Any) -> None:
    """Register filesystem tools on *mcp* and record names in TOOL_NAMES."""
    from forge_conductor.server import TOOL_NAMES

    @mcp.tool
    def fs_read(path: str, encoding: str = "utf-8") -> dict[str, Any]:
        """Read a text file. Paths may be absolute or relative to cwd."""
        return _safe(svc_read, path, encoding=encoding)

    @mcp.tool
    def fs_write(path: str, content: str, encoding: str = "utf-8") -> dict[str, Any]:
        """Write text content to a file (create or overwrite)."""
        return _safe(
            svc_write,
            path,
            content,
            encoding=encoding,
            client_id=_client_id_from_ctx(),
        )

    @mcp.tool
    def fs_edit(
        path: str,
        old: str,
        new: str,
        encoding: str = "utf-8",
        replace_all: bool = False,
    ) -> dict[str, Any]:
        """Replace a string in a text file."""
        return _safe(
            svc_edit,
            path,
            old,
            new,
            encoding=encoding,
            replace_all=replace_all,
            client_id=_client_id_from_ctx(),
        )

    @mcp.tool
    def fs_list(path: str = ".") -> dict[str, Any]:
        """List directory entries (non-recursive)."""
        return _safe(svc_list, path)

    @mcp.tool
    def fs_glob(pattern: str, root: str = ".") -> dict[str, Any]:
        """Glob paths under root matching pattern (supports **)."""
        return _safe(svc_glob, pattern, root=root)

    @mcp.tool
    def fs_stat(path: str) -> dict[str, Any]:
        """Return metadata for a file or directory. Missing paths return exists=false."""
        return _safe(svc_stat, path)

    @mcp.tool
    def fs_mkdir(
        path: str,
        parents: bool = True,
        exist_ok: bool = True,
    ) -> dict[str, Any]:
        """Create a directory."""
        return _safe(
            svc_mkdir,
            path,
            parents=parents,
            exist_ok=exist_ok,
            client_id=_client_id_from_ctx(),
        )

    @mcp.tool
    def fs_delete(path: str, recursive: bool = False) -> dict[str, Any]:
        """Delete a file or empty directory (recursive for trees)."""
        return _safe(
            svc_delete,
            path,
            recursive=recursive,
            client_id=_client_id_from_ctx(),
        )

    @mcp.tool
    def fs_move(src: str, dest: str) -> dict[str, Any]:
        """Move or rename a file or directory."""
        return _safe(svc_move, src, dest, client_id=_client_id_from_ctx())

    TOOL_NAMES.update(
        {
            "fs_read",
            "fs_write",
            "fs_edit",
            "fs_list",
            "fs_glob",
            "fs_stat",
            "fs_mkdir",
            "fs_delete",
            "fs_move",
        }
    )
