"""Tests for multi-host registration snippets and writers."""

from __future__ import annotations

import json
from pathlib import Path

from forge_conductor.onboarding import (
    register_claude,
    register_codex,
    register_json,
    register_lmstudio,
    render_claude_mcp_json,
    render_codex_snippet,
)
from forge_conductor.paths import mcp_server_block, resolve_serve_command


def test_codex_snippet_contains_serve():
    text = render_codex_snippet(command="forge-conductor")
    assert "[mcp_servers.forge-conductor]" in text
    assert 'args = ["serve"]' in text
    assert 'command = "forge-conductor"' in text


def test_codex_snippet_resolved_has_env():
    text = render_codex_snippet(command=None)
    assert "[mcp_servers.forge-conductor]" in text
    assert "[mcp_servers.forge-conductor.env]" in text
    assert "FORGE_CONDUCTOR_HOME" in text


def test_claude_snippet_shape():
    data = render_claude_mcp_json(command="forge-conductor")
    assert data["mcpServers"]["forge-conductor"]["args"] == ["serve"]
    assert data["mcpServers"]["forge-conductor"]["command"] == "forge-conductor"


def test_resolved_mcp_block_has_env():
    block = mcp_server_block()
    assert "command" in block
    assert "env" in block
    assert "FORGE_CONDUCTOR_HOME" in block["env"]
    assert "PYTHONUTF8" in block["env"]


def test_register_codex_writes_and_replaces(tmp_path: Path):
    cfg = tmp_path / "config.toml"
    cfg.write_text(
        "# existing\n[other]\nx = 1\n\n[mcp_servers.forge-conductor]\n"
        'command = "old"\nargs = ["nope"]\n',
        encoding="utf-8",
    )
    code, msg = register_codex(cfg, dry_run=False, command="forge-conductor")
    assert code == 0
    text = cfg.read_text(encoding="utf-8")
    assert "[mcp_servers.forge-conductor]" in text
    assert 'command = "forge-conductor"' in text
    assert 'args = ["serve"]' in text
    assert 'command = "old"' not in text
    assert (tmp_path / "config.toml.bak").is_file()
    assert "Wrote" in msg


def test_register_codex_dry_run_no_write(tmp_path: Path):
    cfg = tmp_path / "config.toml"
    code, msg = register_codex(cfg, dry_run=True)
    assert code == 0
    assert "Dry-run" in msg
    assert not cfg.exists()


def test_register_claude_writes_json(tmp_path: Path):
    path = tmp_path / "claude.json"
    path.write_text(
        json.dumps({"mcpServers": {"other": {"command": "x", "args": []}}}),
        encoding="utf-8",
    )
    code, msg = register_claude(path, dry_run=False)
    assert code == 0
    data = json.loads(path.read_text(encoding="utf-8"))
    assert "forge-conductor" in data["mcpServers"]
    # Resolved launcher may be .cmd with args=[] or exe with ["serve"]
    fc = data["mcpServers"]["forge-conductor"]
    assert "command" in fc
    assert isinstance(fc.get("args"), list)
    assert "env" in fc and "FORGE_CONDUCTOR_HOME" in fc["env"]
    assert "other" in data["mcpServers"]
    assert "Wrote" in msg


def test_register_claude_unknown_path_prints_snippet(monkeypatch):
    import forge_conductor.onboarding as onboarding

    monkeypatch.setattr(onboarding, "find_claude_mcp_path", lambda: None)
    code, msg = register_claude(path=None, dry_run=False)
    # When no common path exists, still exit 0 with pasteable snippet
    assert code == 0
    assert "Paste" in msg or "mcpServers" in msg
    assert "forge-conductor" in msg


def test_register_lmstudio_dual_redundancy(tmp_path: Path):
    path = tmp_path / "mcp.json"
    path.write_text(
        json.dumps({"mcpServers": {"other": {"command": "x", "args": []}}}),
        encoding="utf-8",
    )
    code, msg = register_lmstudio(path=path, dry_run=False)
    assert code == 0
    data = json.loads(path.read_text(encoding="utf-8"))
    # Replaces third-party servers with dual forge family
    assert set(data["mcpServers"].keys()) == {
        "forge-conductor",
        "forge-conductor-fallback",
    }
    assert "env" in data["mcpServers"]["forge-conductor"]
    assert "env" in data["mcpServers"]["forge-conductor-fallback"]
    assert "fallback" in msg.lower() or "Wrote" in msg


def test_register_json_merge(tmp_path: Path):
    path = tmp_path / "mcp.json"
    path.write_text(
        json.dumps({"mcpServers": {"other": {"command": "x", "args": []}}}),
        encoding="utf-8",
    )
    code, msg = register_json(path, dry_run=False, sole=False)
    assert code == 0
    data = json.loads(path.read_text(encoding="utf-8"))
    assert "other" in data["mcpServers"]
    assert "forge-conductor" in data["mcpServers"]


def test_resolve_serve_command_returns_existing_path():
    cmd, args = resolve_serve_command()
    assert isinstance(cmd, str)
    assert isinstance(args, list)
