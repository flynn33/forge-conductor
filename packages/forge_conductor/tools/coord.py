"""Coordinator MCP tools: presence, leases, jobs, status."""

from __future__ import annotations

from typing import Any


def _coord():
    from forge_conductor.server import get_ctx

    ctx = get_ctx()
    if ctx is None:
        raise RuntimeError("Runtime context not initialized")
    if ctx.coordinator is None:
        raise RuntimeError("Coordinator not initialized")
    return ctx.coordinator


def register(mcp: Any) -> None:
    """Register coord tools on *mcp* and record names in TOOL_NAMES."""
    from forge_conductor.server import TOOL_NAMES

    @mcp.tool
    def coord_presence(host_kind: str, pid: int, cwd: str) -> dict[str, Any]:
        """Register or refresh this process in the presence table."""
        coord = _coord()
        coord.register_presence(host_kind=host_kind, pid=pid, cwd=cwd)
        return {"ok": True, "client_id": coord.client_id}

    @mcp.tool
    def coord_lease_acquire(key: str, ttl_sec: int | None = None) -> dict[str, Any]:
        """Acquire a named lease for this client. Returns acquired=True/False."""
        coord = _coord()
        acquired = coord.acquire_lease(key, ttl_sec=ttl_sec)
        return {"acquired": acquired, "key": key, "client_id": coord.client_id}

    @mcp.tool
    def coord_lease_release(key: str) -> dict[str, Any]:
        """Release a lease if held by this client."""
        coord = _coord()
        released = coord.release_lease(key)
        return {"released": released, "key": key, "client_id": coord.client_id}

    @mcp.tool
    def coord_job_create(type: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        """Create an open job; returns the new job id."""
        coord = _coord()
        job_id = coord.create_job(type, payload if payload is not None else {})
        return {"job_id": job_id, "type": type}

    @mcp.tool
    def coord_job_claim() -> dict[str, Any] | None:
        """Claim the oldest open job for this client, or null if none."""
        coord = _coord()
        return coord.claim_job()

    @mcp.tool
    def coord_job_complete(
        job_id: str,
        result: dict[str, Any] | None = None,
        failed: bool = False,
    ) -> dict[str, Any]:
        """Complete or fail a job with a result payload."""
        coord = _coord()
        coord.complete_job(job_id, result if result is not None else {}, failed=failed)
        return {
            "ok": True,
            "job_id": job_id,
            "failed": failed,
        }

    @mcp.tool
    def coord_status() -> dict[str, Any]:
        """Return coordinator mode, client_id, presence and job counts."""
        return _coord().status()

    TOOL_NAMES.update(
        {
            "coord_presence",
            "coord_lease_acquire",
            "coord_lease_release",
            "coord_job_create",
            "coord_job_claim",
            "coord_job_complete",
            "coord_status",
        }
    )
