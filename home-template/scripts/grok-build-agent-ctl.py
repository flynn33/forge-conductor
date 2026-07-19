#!/usr/bin/env python3
"""Grok Build attach / job control for Forge agent backend (no API key).

Usage:
  set FORGE_CONDUCTOR_HOME=...
  set FORGE_AGENT_EXECUTOR=grok
  set PYTHONPATH=.../forge-conductor-impl/src
  python grok-build-agent-ctl.py attach|heartbeat|list|claim|complete ...
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path


def _ensure_path() -> None:
    """Prefer installed package; optional FORGE_SOURCE_ROOT or live RAM app src."""
    candidates = []
    env_root = os.environ.get("FORGE_SOURCE_ROOT") or os.environ.get("PYTHONPATH") or ""
    for part in env_root.split(os.pathsep):
        if part:
            candidates.append(Path(part))
    candidates.extend(
        [
            Path(r"R:\app\src"),
            Path.home() / ".forge-conductor" / "src",
        ]
    )
    for impl in candidates:
        if impl.is_dir() and str(impl) not in sys.path:
            sys.path.insert(0, str(impl))
            break


def _home() -> Path:
    return Path(os.environ.get("FORGE_CONDUCTOR_HOME", Path.home() / ".forge-conductor"))


def cmd_heartbeat(_: argparse.Namespace) -> int:
    home = _home()
    log = home / "logs"
    log.mkdir(parents=True, exist_ok=True)
    (log / "grok-build.heartbeat").write_text(str(time.time()), encoding="utf-8")
    # also disk home so dashboard sees it if live home differs
    disk = Path.home() / ".forge-conductor" / "logs"
    disk.mkdir(parents=True, exist_ok=True)
    (disk / "grok-build.heartbeat").write_text(str(time.time()), encoding="utf-8")
    print(json.dumps({"ok": True, "heartbeat": True, "home": str(home)}))
    return 0


def cmd_attach(_: argparse.Namespace) -> int:
    _ensure_path()
    os.environ["FORGE_AGENT_EXECUTOR"] = "grok"
    from forge_conductor.agent_backend import get_mode, load_state, status_payload
    from forge_conductor.config import ensure_home
    from forge_conductor.store import connect, migrate
    from forge_conductor.agent_jobs import claim_next_job  # noqa: F401

    ensure_home()
    cmd_heartbeat(_)
    st = status_payload()
    mode = get_mode()
    print(
        json.dumps(
            {
                "ok": True,
                "action": "attach",
                "mode": mode,
                "generation": load_state().get("generation"),
                "executor": "grok_build",
                "home": str(_home()),
                "status": st,
                "next": "Run: list | claim | complete --session-id ... --summary ...",
            },
            default=str,
            indent=2,
        )
    )
    return 0 if mode == "grok" else 2


def cmd_list(_: argparse.Namespace) -> int:
    _ensure_path()
    from forge_conductor.config import ensure_home
    from forge_conductor.store import connect, migrate
    from forge_conductor.agent_jobs import JOB_TYPE

    ensure_home()
    conn = connect()
    migrate(conn)
    rows = conn.execute(
        """
        SELECT id, status, payload_json, created_at, updated_at
        FROM jobs WHERE type = ? ORDER BY created_at DESC LIMIT 20
        """,
        (JOB_TYPE,),
    ).fetchall()
    out = []
    for r in rows:
        payload = {}
        try:
            payload = json.loads(r[2] or "{}")
        except json.JSONDecodeError:
            pass
        out.append(
            {
                "id": r[0],
                "status": r[1],
                "session_id": payload.get("session_id"),
                "agent_id": payload.get("agent_id"),
                "goal": payload.get("goal"),
                "created_at": r[3],
            }
        )
    print(json.dumps({"ok": True, "jobs": out}, indent=2))
    return 0


def cmd_claim(_: argparse.Namespace) -> int:
    _ensure_path()
    os.environ["FORGE_AGENT_EXECUTOR"] = "grok"
    from forge_conductor.config import ensure_home
    from forge_conductor.store import connect, migrate
    from forge_conductor.agent_jobs import claim_next_job

    ensure_home()
    cmd_heartbeat(_)
    conn = connect()
    migrate(conn)
    job = claim_next_job(conn)
    if not job:
        print(json.dumps({"ok": True, "job": None, "message": "no queued jobs"}))
        return 0
    print(json.dumps({"ok": True, "job": job}, indent=2, default=str))
    return 0


def cmd_complete(args: argparse.Namespace) -> int:
    _ensure_path()
    os.environ["FORGE_AGENT_EXECUTOR"] = "grok"
    from forge_conductor.config import ensure_home
    from forge_conductor.store import connect, migrate
    from forge_conductor.agent_runtime import run_complete
    from forge_conductor.agent_jobs import get_job_for_session, complete_job

    ensure_home()
    conn = connect()
    migrate(conn)
    sid = args.session_id
    summary = args.summary or "Completed by Grok Build"
    report = {"summary": summary, "executor": "grok_build"}
    try:
        result = run_complete(conn, session_id=sid, report=report, client_id=None)
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 1
    job = get_job_for_session(conn, sid)
    if job and job.get("id"):
        complete_job(conn, job["id"], status="completed", result=report)
    cmd_heartbeat(args)
    print(json.dumps({"ok": True, "session_id": sid, "result": result}, default=str, indent=2))
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description="Grok Build ↔ Forge agent control")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("attach", help="Heartbeat + status (paste-session bootstrap)")
    sub.add_parser("heartbeat", help="Refresh grok-build.heartbeat")
    sub.add_parser("list", help="List recent agent jobs")
    sub.add_parser("claim", help="Claim next queued agent job")
    c = sub.add_parser("complete", help="Complete agent session after you finish work")
    c.add_argument("--session-id", required=True)
    c.add_argument("--summary", default="")

    args = p.parse_args()
    if not os.environ.get("FORGE_CONDUCTOR_HOME"):
        # Prefer RAM live home
        if Path(r"R:\home").is_dir():
            os.environ["FORGE_CONDUCTOR_HOME"] = r"R:\home"
        else:
            os.environ["FORGE_CONDUCTOR_HOME"] = str(Path.home() / ".forge-conductor")

    handlers = {
        "attach": cmd_attach,
        "heartbeat": cmd_heartbeat,
        "list": cmd_list,
        "claim": cmd_claim,
        "complete": cmd_complete,
    }
    return handlers[args.cmd](args)


if __name__ == "__main__":
    raise SystemExit(main())
