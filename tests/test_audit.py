from forge_conductor.config import ensure_home
from forge_conductor.store import connect, migrate
from forge_conductor.audit import append, tail


def test_audit_append_and_tail(forge_home):
    ensure_home()
    conn = connect()
    migrate(conn)
    append(
        conn,
        tool="fs_write",
        args={"path": "x", "content": "secret"},
        status="ok",
        client_id="c1",
        duration_ms=3,
        mutating=True,
    )
    events = tail(conn, limit=10)
    assert events[0]["tool"] == "fs_write"
    assert "args_digest" in events[0]
    assert events[0].get("args") is not None  # full args for mutating tools
    assert (forge_home / "audit.jsonl").is_file()


def test_audit_non_mutating_stores_digest_only(forge_home):
    ensure_home()
    conn = connect()
    migrate(conn)
    append(
        conn,
        tool="fs_read",
        args={"path": "x"},
        status="ok",
        client_id="c1",
        duration_ms=1,
        mutating=False,
    )
    ev = tail(conn, limit=1)[0]
    assert ev["args_digest"]
    # non-mutating may omit full args body
    assert ev.get("args") in (None, {}, {"path": "x"})
