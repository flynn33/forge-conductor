from forge_conductor.config import ensure_home
from forge_conductor.store import (
    connect,
    migrate,
    memory_set,
    memory_get,
    memory_list,
    memory_delete,
    memory_search,
)


def test_migrate_creates_tables(forge_home):
    ensure_home()
    conn = connect()
    migrate(conn)
    tables = {r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    )}
    for t in (
        "schema_version",
        "memory_notes",
        "agent_sessions",
        "jobs",
        "leases",
        "presence",
        "audit_events",
        "documents",
    ):
        assert t in tables


def test_migrate_idempotent(forge_home):
    ensure_home()
    conn = connect()
    migrate(conn)
    migrate(conn)
    version = conn.execute("SELECT version FROM schema_version").fetchone()[0]
    assert version == 2


def test_memory_roundtrip(forge_home):
    ensure_home()
    conn = connect()
    migrate(conn)
    memory_set(conn, key="k1", body="hello", tags=["t"])
    row = memory_get(conn, "k1")
    assert row is not None
    assert row["body"] == "hello"
    assert row["key"] == "k1"
    assert row["tags"] == ["t"]


def test_memory_get_missing(forge_home):
    ensure_home()
    conn = connect()
    migrate(conn)
    assert memory_get(conn, "nope") is None


def test_memory_list_delete_search(forge_home):
    ensure_home()
    conn = connect()
    migrate(conn)

    memory_set(conn, key="alpha", body="hello world", tags=["t1"])
    memory_set(conn, key="beta", body="other note", tags=["t2"])

    keys = {r["key"] for r in memory_list(conn)}
    assert keys == {"alpha", "beta"}

    hits = memory_search(conn, "hello")
    hit_keys = {h["key"] for h in hits}
    assert "alpha" in hit_keys
    assert "beta" not in hit_keys

    # search also matches key substring
    key_hits = memory_search(conn, "bet")
    assert any(h["key"] == "beta" for h in key_hits)

    memory_delete(conn, "alpha")
    assert memory_get(conn, "alpha") is None
    remaining = {r["key"] for r in memory_list(conn)}
    assert remaining == {"beta"}


def test_memory_set_updates_existing(forge_home):
    ensure_home()
    conn = connect()
    migrate(conn)
    memory_set(conn, key="k1", body="v1", tags=[])
    memory_set(conn, key="k1", body="v2", tags=["updated"])
    row = memory_get(conn, "k1")
    assert row["body"] == "v2"
    assert row["tags"] == ["updated"]
    assert row["created_at"] is not None
    assert row["updated_at"] is not None
