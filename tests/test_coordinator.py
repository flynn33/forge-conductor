"""Coordinator: presence, leases, jobs (store-backed, dual logical clients)."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from forge_conductor.config import ensure_home
from forge_conductor.coordinator import Coordinator
from forge_conductor.store import connect, migrate


def _coords(forge_home):
    ensure_home()
    conn = connect()
    migrate(conn)
    c1 = Coordinator(conn, client_id="c1", lease_ttl_sec=60, presence_ttl_sec=30)
    c2 = Coordinator(conn, client_id="c2", lease_ttl_sec=60, presence_ttl_sec=30)
    return conn, c1, c2


def test_lease_acquire_release(forge_home):
    _conn, c1, c2 = _coords(forge_home)
    c1.register_presence(host_kind="test", pid=1, cwd="/tmp/a")
    c2.register_presence(host_kind="test", pid=2, cwd="/tmp/b")

    assert c1.acquire_lease("path:/tmp/x") is True
    assert c2.acquire_lease("path:/tmp/x") is False
    assert c1.release_lease("path:/tmp/x") is True
    assert c2.acquire_lease("path:/tmp/x") is True


def test_job_create_claim_complete(forge_home):
    _conn, c1, c2 = _coords(forge_home)  # noqa: keep conn for status assert
    c1.register_presence(host_kind="test", pid=1, cwd="/tmp/a")
    c2.register_presence(host_kind="test", pid=2, cwd="/tmp/b")

    job_id = c1.create_job("demo", {"n": 1})
    assert isinstance(job_id, str) and job_id

    claimed = c2.claim_job()
    assert claimed is not None
    assert claimed["id"] == job_id
    assert claimed["type"] == "demo"
    assert claimed["payload"] == {"n": 1}
    assert claimed["status"] == "claimed"
    assert claimed["owner_client_id"] == "c2"

    # No second open job
    assert c1.claim_job() is None

    c2.complete_job(job_id, {"ok": True}, failed=False)
    st = c1.status()
    assert st["open_jobs"] == 0
    row = _conn.execute(
        "SELECT status, result_json FROM jobs WHERE id = ?", (job_id,)
    ).fetchone()
    assert row["status"] == "done"


def test_presence_heartbeat_expiry(forge_home):
    conn, c1, _c2 = _coords(forge_home)
    c1.register_presence(host_kind="test", pid=1, cwd="/tmp/a")

    row = conn.execute(
        "SELECT last_heartbeat FROM presence WHERE client_id = ?",
        ("c1",),
    ).fetchone()
    assert row is not None

    # Force last_heartbeat far in the past so reclaim removes the row
    expired = (
        datetime.now(timezone.utc) - timedelta(seconds=120)
    ).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    conn.execute(
        "UPDATE presence SET last_heartbeat = ? WHERE client_id = ?",
        (expired, "c1"),
    )
    conn.commit()

    c1.reclaim_expired()
    gone = conn.execute(
        "SELECT 1 FROM presence WHERE client_id = ?",
        ("c1",),
    ).fetchone()
    assert gone is None


def test_status_reports_local_mode(forge_home):
    _conn, c1, _c2 = _coords(forge_home)
    c1.register_presence(host_kind="test", pid=1, cwd="/tmp/a")
    st = c1.status()
    assert st["mode"] in ("local", "degraded")
    assert st["client_id"] == "c1"
    assert st["presence_count"] >= 1
