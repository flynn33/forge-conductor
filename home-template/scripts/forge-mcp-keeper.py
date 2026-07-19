#!/usr/bin/env python3
"""Always-on MCP stdio keeper for Forge-Conductor primary or fallback.

Spawns the home launcher (forge-serve.cmd / forge-serve-fallback.cmd), performs
MCP initialize, keeps the child alive, and auto-restarts on any exit/crash.

This is independent of LM Studio: it ensures orchestration processes + presence
survive reboots/logons. LM Studio may still spawn its own plugin children for chat.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


def _utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _home() -> Path:
    return Path(os.environ.get("FORGE_CONDUCTOR_HOME", Path.home() / ".forge-conductor"))


def _log(role: str, msg: str) -> None:
    line = f"{_utc()}  [{role}] {msg}"
    log_dir = _home() / "logs"
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
        with (log_dir / "mcp-keeper.log").open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass
    try:
        sys.stderr.write(line + "\n")
        sys.stderr.flush()
    except OSError:
        pass


def _diag(event: str, **fields) -> None:
    rec = {"ts": _utc(), "event": event, "src": "forge-mcp-keeper", **fields}
    try:
        log_dir = _home() / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        with (log_dir / "failover-diagnostics.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, default=str) + "\n")
    except OSError:
        pass


def _launcher(role: str) -> Path:
    home = _home()
    if role in ("fallback",):
        return home / "bin" / "forge-serve-fallback.cmd"
    if role in ("memory", "ram-memory", "ram_memory"):
        return home / "bin" / "forge-memory-serve.cmd"
    return home / "bin" / "forge-serve.cmd"


def _ping_tool(role: str) -> str:
    """Tool used for keepalive (must exist on that server)."""
    if role in ("memory", "ram-memory", "ram_memory"):
        return "ram_status"
    return "forge_status"


def _normalize_role(role: str) -> str:
    r = (role or "primary").strip().lower()
    if r in ("ram-memory", "ram_memory", "mem"):
        return "memory"
    return r


def _rpc(proc: subprocess.Popen, msg: dict, *, timeout: float = 30.0) -> dict | None:
    assert proc.stdin and proc.stdout
    line = json.dumps(msg, separators=(",", ":")) + "\n"
    proc.stdin.write(line)
    proc.stdin.flush()
    if "id" not in msg:
        return {}
    want = msg["id"]
    end = time.time() + timeout
    while time.time() < end:
        if proc.poll() is not None:
            return None
        raw = proc.stdout.readline()
        if not raw:
            time.sleep(0.05)
            continue
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if data.get("id") == want:
            return data
    return None


def _run_once(role: str) -> int:
    launcher = _launcher(role)
    if not launcher.is_file():
        _log(role, f"launcher missing: {launcher}")
        _diag("keeper_launcher_missing", role=role, path=str(launcher))
        return 2

    role = _normalize_role(role)
    env = os.environ.copy()
    env["FORGE_CONDUCTOR_HOME"] = str(_home())
    # memory server expects FORGE_MCP_ROLE=memory (launcher also sets it)
    env["FORGE_MCP_ROLE"] = "memory" if role == "memory" else role
    env["FASTMCP_SHOW_SERVER_BANNER"] = "false"
    env["PYTHONUTF8"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"

    creationflags = 0
    if sys.platform == "win32":
        creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)

    _log(role, f"starting {launcher}")
    _diag("keeper_spawn", role=role, launcher=str(launcher))
    proc = subprocess.Popen(
        ["cmd.exe", "/d", "/s", "/c", str(launcher)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=env,
        cwd=str(_home()),
        creationflags=creationflags,
    )

    # Drain stderr to diagnostic file
    def _err() -> None:
        assert proc.stderr is not None
        err_path = _home() / "logs" / f"mcp-keeper-{role}.stderr.log"
        try:
            with err_path.open("a", encoding="utf-8") as fh:
                fh.write(f"\n--- pid={proc.pid} {_utc()} ---\n")
                for line in proc.stderr:
                    fh.write(line)
        except OSError:
            pass

    import threading

    threading.Thread(target=_err, daemon=True).start()

    init = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": f"forge-mcp-keeper-{role}", "version": "1.0"},
        },
    }
    resp = _rpc(proc, init, timeout=45.0)
    if resp is None or "error" in (resp or {}):
        _log(role, f"initialize failed: {resp}")
        _diag("keeper_init_failed", role=role, pid=proc.pid, resp=resp)
        try:
            proc.kill()
        except OSError:
            pass
        return 3

    _rpc(
        proc,
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        timeout=5.0,
    )
    _log(role, f"online pid={proc.pid}")
    _diag("keeper_online", role=role, pid=proc.pid)

    # Keepalive: periodic tool ping so presence heartbeats stay warm
    next_ping = time.time() + 15.0
    ping_id = 100
    ping_name = _ping_tool(role)
    while True:
        if proc.poll() is not None:
            ec = proc.returncode
            _log(role, f"child exited ec={ec}")
            _diag("keeper_child_exit", role=role, exit_code=ec, pid=proc.pid)
            return ec if ec is not None else 1
        now = time.time()
        if now >= next_ping:
            ping_id += 1
            try:
                _rpc(
                    proc,
                    {
                        "jsonrpc": "2.0",
                        "id": ping_id,
                        "method": "tools/call",
                        "params": {"name": ping_name, "arguments": {}},
                    },
                    timeout=20.0,
                )
            except Exception as exc:  # noqa: BLE001
                _log(role, f"ping error: {exc}")
            next_ping = now + 20.0
        time.sleep(0.5)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--role",
        choices=("primary", "fallback", "memory", "ram-memory"),
        required=True,
        help="primary|fallback|memory (ram-memory alias)",
    )
    ap.add_argument("--restart-delay", type=float, default=3.0)
    args = ap.parse_args()
    role = _normalize_role(args.role)
    os.environ.setdefault("FORGE_CONDUCTOR_HOME", str(Path.home() / ".forge-conductor"))
    os.environ["FORGE_MCP_ROLE"] = "memory" if role == "memory" else role

    _log(role, "keeper supervisor start")
    _diag("keeper_supervisor_start", role=role, pid=os.getpid())
    while True:
        try:
            code = _run_once(role)
        except KeyboardInterrupt:
            _log(role, "keyboard interrupt")
            return 0
        except Exception as exc:  # noqa: BLE001
            _log(role, f"run_once exception: {exc}")
            _diag("keeper_exception", role=role, error=str(exc))
            code = 1
        _log(role, f"restart in {args.restart_delay}s (last_code={code})")
        _diag("keeper_restart_sleep", role=role, last_code=code, delay=args.restart_delay)
        time.sleep(args.restart_delay)


if __name__ == "__main__":
    raise SystemExit(main())
