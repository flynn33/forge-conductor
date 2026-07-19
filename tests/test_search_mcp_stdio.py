"""Regression: search_text must not hang when the MCP server owns stdio.

Child git/rg processes MUST use stdin=DEVNULL. Otherwise they inherit the MCP
JSON-RPC stdin pipe and block forever (LM Studio error -32001 / host timeouts).
"""

from __future__ import annotations

import json
import os
import queue
import subprocess
import threading
import time
from pathlib import Path

import pytest


@pytest.fixture
def tiny_tree(tmp_path: Path) -> Path:
    (tmp_path / "a.txt").write_text("roadmap token here\n", encoding="utf-8")
    return tmp_path


def _mcp_call_search(root: Path, *, timeout: float = 15.0) -> dict:
    env = os.environ.copy()
    env["FASTMCP_SHOW_SERVER_BANNER"] = "false"
    # Prefer venv entry if present
    candidates = [
        Path(__file__).resolve().parents[1]
        / ".venv"
        / "Scripts"
        / "forge-conductor.exe",
        Path("forge-conductor"),
    ]
    exe = next((c for c in candidates if c == Path("forge-conductor") or c.is_file()), None)
    assert exe is not None
    cmd = [str(exe), "serve"]
    p = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
        bufsize=1,
    )
    q: queue.Queue[str] = queue.Queue()

    def _reader() -> None:
        assert p.stdout is not None
        for line in p.stdout:
            q.put(line)

    threading.Thread(target=_reader, daemon=True).start()
    _id = 0

    def rpc(method: str, params=None, *, notify: bool = False, wait: float = timeout):
        nonlocal _id
        _id += 1
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if not notify:
            msg["id"] = _id
        assert p.stdin is not None
        p.stdin.write(json.dumps(msg) + "\n")
        p.stdin.flush()
        if notify:
            return None
        want = _id
        end = time.time() + wait
        while time.time() < end:
            if p.poll() is not None:
                err = p.stderr.read() if p.stderr else ""
                raise RuntimeError(f"server exit {p.returncode}: {err[:400]}")
            try:
                line = q.get(timeout=0.2)
            except queue.Empty:
                continue
            try:
                data = json.loads(line)
            except json.JSONDecodeError:
                continue
            if data.get("id") == want:
                if "error" in data:
                    raise RuntimeError(data["error"])
                return data.get("result")
        raise TimeoutError(f"timeout waiting for {method}")

    try:
        rpc(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "pytest-search", "version": "1"},
            },
        )
        rpc("notifications/initialized", notify=True)
        t0 = time.perf_counter()
        result = rpc(
            "tools/call",
            {
                "name": "search_text",
                "arguments": {"query": "roadmap", "root": str(root)},
            },
            wait=timeout,
        )
        elapsed = time.perf_counter() - t0
        assert elapsed < 10.0, f"search_text too slow over MCP: {elapsed:.2f}s"
        content = (result or {}).get("content") or []
        text = content[0].get("text") if content else ""
        body = json.loads(text)
        assert body.get("count", 0) >= 1
        return body
    finally:
        try:
            p.kill()
        except Exception:
            pass


def test_search_text_mcp_stdio_does_not_hang(tiny_tree: Path):
    body = _mcp_call_search(tiny_tree, timeout=12.0)
    assert body["count"] >= 1
    assert any("roadmap" in h.get("text", "") for h in body.get("hits") or [])
