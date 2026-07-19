"""Client registration for LM Studio, Codex, Claude, and generic JSON MCP hosts."""

from __future__ import annotations

import json
import os
import re
import shutil
from pathlib import Path
from typing import Any

from forge_conductor.paths import (
    codex_toml_block,
    ensure_home_launcher,
    forge_env,
    mcp_server_block,
    resolve_serve_command,
)

# mcp_dual_servers imported lazily in register_lmstudio to avoid cycles


def render_codex_snippet(command: str | None = None) -> str:
    """Return a TOML fragment for Codex ``config.toml`` MCP registration.

    When *command* is None, uses the resolved absolute serve path + env block.
    When *command* is provided, emits a minimal legacy-style block for tests.
    """
    if command is not None:
        return (
            f"[mcp_servers.forge-conductor]\n"
            f'command = "{command}"\n'
            f'args = ["serve"]\n'
        )
    return codex_toml_block()


def render_claude_mcp_json(command: str | None = None) -> dict[str, Any]:
    """Return a Claude/LM Studio-style MCP servers JSON object."""
    if command is not None:
        return {
            "mcpServers": {
                "forge-conductor": {
                    "command": command,
                    "args": ["serve"],
                }
            }
        }
    return {"mcpServers": {"forge-conductor": mcp_server_block()}}


def _replace_or_append_toml_section(text: str, section_header: str, body: str) -> str:
    """Replace an existing TOML table section or append *body* if missing.

    *section_header* is the bracket line without trailing newline, e.g.
    ``[mcp_servers.forge-conductor]``.
    *body* is the full section including the header line and nested tables.
    """
    # Match this section and nested dotted tables under the same prefix until
    # the next top-level sibling section that is not a child of this header.
    # Example: [mcp_servers.forge-conductor] + [mcp_servers.forge-conductor.env]
    prefix = section_header.strip("[]")
    pattern = re.compile(
        rf"(?ms)^{re.escape(section_header)}\s*\n"
        rf"(?:(?!^\[[^\]]+\]).*\n)*"
        rf"(?:^\[{re.escape(prefix)}\.[^\]]+\]\s*\n(?:(?!^\[[^\]]+\]).*\n)*)*"
    )
    replacement = body if body.endswith("\n") else body + "\n"
    if pattern.search(text):
        return pattern.sub(replacement, text, count=1)

    base = text.rstrip()
    if base:
        return base + "\n\n" + replacement
    return replacement


def register_codex(
    path: Path | str | None = None,
    *,
    dry_run: bool = False,
    command: str | None = None,
) -> tuple[int, str]:
    """Backup and write Codex MCP config for forge-conductor.

    Returns ``(exit_code, message)``.
    """
    ensure_home_launcher()
    snippet = render_codex_snippet(command=command)
    if path is None:
        path = Path.home() / ".codex" / "config.toml"
    else:
        path = Path(path)

    if dry_run:
        msg = f"Dry-run: would write Codex MCP config to {path}:\n\n{snippet}"
        return 0, msg

    path.parent.mkdir(parents=True, exist_ok=True)
    existing = ""
    if path.is_file():
        backup = path.with_suffix(path.suffix + ".bak")
        shutil.copy2(path, backup)
        existing = path.read_text(encoding="utf-8")

    updated = _replace_or_append_toml_section(
        existing,
        "[mcp_servers.forge-conductor]",
        snippet,
    )
    path.write_text(updated, encoding="utf-8")
    return 0, f"Wrote Codex MCP registration to {path} (backup: {path}.bak if pre-existing)"


def claude_mcp_candidate_paths() -> list[Path]:
    """Return common Claude Desktop / Claude Code user MCP config paths."""
    home = Path.home()
    candidates: list[Path] = [
        home / ".claude.json",
        home / ".claude" / "claude_desktop_config.json",
        home / ".claude" / "settings.json",
    ]
    appdata = os.environ.get("APPDATA")
    if appdata:
        candidates.append(Path(appdata) / "Claude" / "claude_desktop_config.json")
    roaming = home / "AppData" / "Roaming" / "Claude" / "claude_desktop_config.json"
    if roaming not in candidates:
        candidates.append(roaming)
    return candidates


def find_claude_mcp_path() -> Path | None:
    """Return the first existing Claude MCP config path, if any."""
    for p in claude_mcp_candidate_paths():
        if p.is_file():
            return p
    return None


def lmstudio_mcp_path() -> Path:
    return Path.home() / ".lmstudio" / "mcp.json"


def register_claude(
    path: Path | str | None = None,
    *,
    dry_run: bool = False,
    command: str | None = None,
) -> tuple[int, str]:
    """Write/update Claude user MCP config, or print a snippet if path unknown."""
    ensure_home_launcher()
    snippet_obj = render_claude_mcp_json(command=command)
    snippet_text = json.dumps(snippet_obj, indent=2)

    target: Path | None
    if path is not None:
        target = Path(path)
    else:
        target = find_claude_mcp_path()

    if dry_run or target is None:
        if target is None:
            msg = (
                "No Claude MCP config found at common paths. "
                "Paste this into your Claude Code / Desktop MCP config:\n\n"
                f"{snippet_text}\n"
            )
        else:
            msg = (
                f"Dry-run: would merge forge-conductor into {target}:\n\n"
                f"{snippet_text}\n"
            )
        return 0, msg

    return _merge_json_mcp(target, snippet_obj["mcpServers"]["forge-conductor"])


def register_lmstudio(
    path: Path | str | None = None,
    *,
    dry_run: bool = False,
) -> tuple[int, str]:
    """Write LM Studio ``mcp.json`` with RAM memory + primary + fallback.

    Forge-family only (no third-party stacks). ``ram-memory`` is a dedicated
    first-class MCP toggle for the RAM corpus; dual conductor gives failover.
    """
    from forge_conductor.paths import mcp_dual_servers

    ensure_home_launcher()
    target = Path(path) if path is not None else lmstudio_mcp_path()
    data = {"mcpServers": mcp_dual_servers()}
    text = json.dumps(data, indent=2) + "\n"

    if dry_run:
        return 0, f"Dry-run: would write LM Studio MCP config to {target}:\n\n{text}"

    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_file():
        shutil.copy2(target, target.with_suffix(target.suffix + ".bak"))
    target.write_text(text, encoding="utf-8")
    # Sync bridge plugin for primary (LM Studio creates per-server bridges)
    synced = Path.home() / ".lmstudio" / ".internal" / "last-synced-mcp-state.json"
    try:
        if synced.parent.is_dir():
            synced.write_text(text, encoding="utf-8")
    except OSError:
        pass
    # Ensure plugin bridge configs exist for every forge-family server
    for name, block in data["mcpServers"].items():
        _write_lmstudio_plugin_bridge(name, block)
    return (
        0,
        f"Wrote LM Studio MCP registration to {target} "
        f"(ram-memory + forge-conductor + forge-conductor-fallback)",
    )


def _write_lmstudio_plugin_bridge(name: str, block: dict[str, Any]) -> None:
    import time

    plugin_dir = (
        Path.home() / ".lmstudio" / "extensions" / "plugins" / "mcp" / name
    )
    try:
        plugin_dir.mkdir(parents=True, exist_ok=True)
        (plugin_dir / "manifest.json").write_text(
            json.dumps(
                {
                    "type": "plugin",
                    "runner": "mcpBridge",
                    "owner": "mcp",
                    "name": name,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        (plugin_dir / "mcp-bridge-config.json").write_text(
            json.dumps(block, indent=2) + "\n", encoding="utf-8"
        )
        (plugin_dir / "install-state.json").write_text(
            json.dumps({"by": "mcp-bridge-v1", "at": int(time.time() * 1000)}) + "\n",
            encoding="utf-8",
        )
    except OSError:
        pass


def register_json(
    path: Path | str,
    *,
    dry_run: bool = False,
    sole: bool = False,
) -> tuple[int, str]:
    """Merge forge-conductor into an arbitrary MCP JSON config file."""
    ensure_home_launcher()
    target = Path(path)
    block = mcp_server_block()
    if dry_run:
        preview = {"mcpServers": {"forge-conductor": block}}
        return 0, f"Dry-run: would merge into {target}:\n{json.dumps(preview, indent=2)}\n"
    if sole:
        data = {"mcpServers": {"forge-conductor": block}}
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_file():
            shutil.copy2(target, target.with_suffix(target.suffix + ".bak"))
        target.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        return 0, f"Wrote sole forge-conductor MCP config to {target}"
    return _merge_json_mcp(target, block)


def _merge_json_mcp(target: Path, server_block: dict[str, Any]) -> tuple[int, str]:
    target.parent.mkdir(parents=True, exist_ok=True)
    data: dict[str, Any] = {}
    if target.is_file():
        backup = target.with_suffix(target.suffix + ".bak")
        shutil.copy2(target, backup)
        try:
            raw = json.loads(target.read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                data = raw
        except json.JSONDecodeError:
            data = {}

    servers = data.get("mcpServers")
    if not isinstance(servers, dict):
        servers = {}
        data["mcpServers"] = servers
    servers["forge-conductor"] = server_block
    target.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return 0, f"Wrote MCP registration to {target}"


def describe_resolved_serve() -> str:
    """Human-readable resolved serve command for doctor/status."""
    cmd, args = resolve_serve_command()
    env = forge_env()
    return f"command={cmd!r} args={args!r} home={env.get('FORGE_CONDUCTOR_HOME')!r}"
