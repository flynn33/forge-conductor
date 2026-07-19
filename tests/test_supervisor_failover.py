"""Automatic fail-over: host stdio stays up when backend child dies."""

from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

import psutil
import pytest


@pytest.fixture
def venv_exe() -> Path:
    p = (
        Path(__file__).resolve().parents[1]
        / ".venv"
        / "Scripts"
        / "forge-conductor.exe"
    )
    if not p.is_file():
        pytest.skip("venv forge-conductor.exe missing")
    return p


def _rpc_line(proc: subprocess.Popen, msg: dict, *, timeout: float = 20.0) -> dict:
    assert proc.stdin and proc.stdout
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()
    if "id" not in msg:
        return {}
    want = msg["id"]
    end = time.time() + timeout
    while time.time() < end:
        if proc.poll() is not None:
            err = proc.stderr.read() if proc.stderr else ""
            raise RuntimeError(f"supervisor exited {proc.returncode}: {err[:400]}")
        line = proc.stdout.readline()
        if not line:
            time.sleep(0.05)
            continue
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            continue
        if data.get("id") == want:
            if "error" in data:
                raise RuntimeError(data["error"])
            return data
    raise TimeoutError(f"timeout id={want}")


def _kill_backend_children(supervisor_pid: int) -> int:
    """Kill serve backends under supervisor; leave supervisor alive."""
    killed = 0
    try:
        parent = psutil.Process(supervisor_pid)
    except psutil.Error:
        return 0
    for child in parent.children(recursive=True):
        try:
            cmd = " ".join(child.cmdline()).lower()
        except psutil.Error:
            continue
        # Kill serve backends, not nested noise only
        if "serve" in cmd and "supervise" not in cmd:
            try:
                child.kill()
                killed += 1
            except psutil.Error:
                pass
    return killed


def test_supervisor_survives_child_kill(venv_exe: Path, forge_home: Path, monkeypatch):
    monkeypatch.setenv("FORGE_CONDUCTOR_HOME", str(forge_home))
    env = os.environ.copy()
    env["FORGE_CONDUCTOR_HOME"] = str(forge_home)
    env["FASTMCP_SHOW_SERVER_BANNER"] = "false"
    env["PYTHONUTF8"] = "1"
    env.pop("FORGE_SUPERVISED", None)

    proc = subprocess.Popen(
        [str(venv_exe), "supervise"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=env,
    )
    try:
        _rpc_line(
            proc,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "failover-test", "version": "1"},
                },
            },
        )
        _rpc_line(proc, {"jsonrpc": "2.0", "method": "notifications/initialized"})
        r1 = _rpc_line(
            proc,
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {"name": "forge_status", "arguments": {}},
            },
        )
        assert "result" in r1

        killed = _kill_backend_children(proc.pid)
        assert killed >= 1, "expected to kill at least one backend child"
        time.sleep(1.5)

        # Supervisor must still be alive
        assert proc.poll() is None, "supervisor died after child kill"

        r2 = _rpc_line(
            proc,
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "forge_status", "arguments": {}},
            },
            timeout=35.0,
        )
        assert "result" in r2
        text = (r2["result"].get("content") or [{}])[0].get("text", "")
        assert "tool_count" in text or "0.1.0" in text
    finally:
        try:
            parent = psutil.Process(proc.pid)
            for c in parent.children(recursive=True):
                try:
                    c.kill()
                except psutil.Error:
                    pass
            proc.kill()
        except (psutil.Error, OSError):
            try:
                proc.kill()
            except OSError:
                pass
