"""Tests for filesystem tool pack."""

from __future__ import annotations

from forge_conductor.audit import tail
from forge_conductor.config import ensure_home, load_config
from forge_conductor.server import RuntimeContext
from forge_conductor.store import connect, migrate
from forge_conductor.tools import filesystem as fs


def _set_ctx(forge_home, conn):
    import forge_conductor.server as server

    server._ctx = RuntimeContext(
        conn=conn,
        client_id="test-client",
        config=load_config(),
        home=forge_home,
    )
    return server._ctx


def test_fs_write_read_edit_list_glob_stat_mkdir_delete_move(tmp_path, forge_home):
    ensure_home()
    root = tmp_path / "ws"
    root.mkdir()
    f = root / "hello.txt"

    written = fs.svc_write(str(f), "hello world")
    assert written["bytes_written"] > 0
    assert f.read_text(encoding="utf-8") == "hello world"

    read = fs.svc_read(str(f))
    assert read["content"] == "hello world"

    edited = fs.svc_edit(str(f), "world", "forge")
    assert edited["replacements"] == 1
    assert f.read_text(encoding="utf-8") == "hello forge"

    listed = fs.svc_list(str(root))
    names = [e["name"] for e in listed["entries"]]
    assert "hello.txt" in names

    sub = root / "sub"
    fs.svc_mkdir(str(sub))
    assert sub.is_dir()

    nested = sub / "a.py"
    fs.svc_write(str(nested), "print(1)\n")
    globs = fs.svc_glob("**/*.py", root=str(root))
    assert any(str(nested) in m or m.endswith("a.py") for m in globs["matches"])

    st = fs.svc_stat(str(f))
    assert st["is_file"] is True
    assert st["size"] > 0

    dest = root / "moved.txt"
    moved = fs.svc_move(str(f), str(dest))
    assert dest.is_file()
    assert not f.exists()
    assert moved["dest"] == str(dest.resolve())

    fs.svc_delete(str(dest))
    assert not dest.exists()

    fs.svc_delete(str(sub), recursive=True)
    assert not sub.exists()


def test_fs_write_delete_audit_when_ctx_and_client_id(tmp_path, forge_home):
    ensure_home()
    conn = connect()
    migrate(conn)
    _set_ctx(forge_home, conn)

    path = tmp_path / "audited.txt"
    fs.svc_write(str(path), "data", client_id="client-fs")
    events = tail(conn, limit=5)
    assert events
    assert events[0]["tool"] == "fs_write"
    assert events[0]["client_id"] == "client-fs"
    assert events[0].get("args") is not None

    fs.svc_delete(str(path), client_id="client-fs")
    events = tail(conn, limit=5)
    assert events[0]["tool"] == "fs_delete"
    assert events[0]["client_id"] == "client-fs"
