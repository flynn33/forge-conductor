from forge_conductor.config import ensure_home
from forge_conductor.store import connect, migrate
from forge_conductor.tools import memory as mem
from forge_conductor.audit import tail


def test_memory_set_get_list_delete_search(forge_home):
    ensure_home()
    conn = connect()
    migrate(conn)
    mem.svc_set(conn, key="alpha", body="hello world", tags=["t1"])
    assert mem.svc_get(conn, "alpha")["body"] == "hello world"
    keys = [r["key"] for r in mem.svc_list(conn)]
    assert "alpha" in keys
    hits = mem.svc_search(conn, "hello")
    assert any(h["key"] == "alpha" for h in hits)
    mem.svc_delete(conn, "alpha")
    assert mem.svc_get(conn, "alpha") is None


def test_memory_mutating_audits_when_client_id_given(forge_home):
    ensure_home()
    conn = connect()
    migrate(conn)
    mem.svc_set(
        conn,
        key="k1",
        body="body",
        tags=["t"],
        client_id="client-abc",
    )
    events = tail(conn, limit=5)
    assert events
    assert events[0]["tool"] == "memory_set"
    assert events[0]["client_id"] == "client-abc"
    assert events[0].get("args") is not None

    mem.svc_delete(conn, "k1", client_id="client-abc")
    events = tail(conn, limit=5)
    assert events[0]["tool"] == "memory_delete"
    assert events[0]["client_id"] == "client-abc"
