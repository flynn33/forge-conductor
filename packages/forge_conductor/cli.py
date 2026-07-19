"""Forge-Conductor CLI: install, doctor, status, register, serve."""

from __future__ import annotations

import argparse
import importlib
import shutil
import sys
from pathlib import Path
from typing import Any

# Path is used by doctor host checks

from forge_conductor import __version__


def install() -> int:
    """Ensure home layout + store schema; print next steps."""
    from forge_conductor.config import ensure_home, get_home
    from forge_conductor.paths import ensure_home_launcher, resolve_serve_command
    from forge_conductor.store import connect, migrate

    home = ensure_home()
    launcher = ensure_home_launcher()
    conn = connect()
    migrate(conn)
    conn.close()
    cmd, args = resolve_serve_command()

    print(f"Forge-Conductor home ready: {home}")
    print(f"Store migrated under {get_home() / 'store.sqlite'}")
    print(f"Serve launcher: {launcher}")
    print(f"Resolved serve: {cmd} {args}")
    print()
    print("Next steps:")
    print("  1. Optional browser support:")
    print("       uv run playwright install chromium")
    print("  2. Register clients (prefer absolute launcher, not bare PATH):")
    print("       forge-conductor register lmstudio")
    print("       forge-conductor register codex")
    print("       forge-conductor register claude")
    print("  3. Verify:")
    print("       forge-conductor doctor")
    print("       forge-conductor status")
    print("       pwsh -File $env:USERPROFILE\\.forge-conductor\\scripts\\compat-check.ps1")
    return 0


def _check_playwright_chromium() -> tuple[bool, str]:
    """Return (ok, message) for Chromium availability."""
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        return False, "playwright package not importable"
    try:
        with sync_playwright() as p:
            # executable_path raises if browser not installed
            path = p.chromium.executable_path
            if path and Path(path).exists():
                return True, f"chromium ok ({path})"
            return False, "chromium executable path missing"
    except Exception as exc:  # noqa: BLE001 — doctor should never crash
        return False, f"chromium not ready: {exc}"


def doctor(*, stream: Any = None) -> int:
    """Run health checks. Exit 0 if critical OK; 1 on critical failure."""
    out = stream if stream is not None else sys.stdout
    critical_ok = True
    warnings: list[str] = []

    def ok(msg: str) -> None:
        print(f"  [ok]   {msg}", file=out)

    def warn(msg: str) -> None:
        warnings.append(msg)
        print(f"  [warn] {msg}", file=out)

    def fail(msg: str) -> None:
        nonlocal critical_ok
        critical_ok = False
        print(f"  [FAIL] {msg}", file=out)

    print("Forge-Conductor doctor", file=out)
    print(f"version: {__version__}", file=out)

    # --- home ---
    from forge_conductor.config import ensure_home, get_home, load_config

    home = get_home()
    if not home.exists():
        try:
            ensure_home()
            ok(f"home created: {home}")
        except OSError as exc:
            fail(f"home missing and could not create {home}: {exc}")
    else:
        ok(f"home exists: {home}")

    # --- config ---
    try:
        cfg = load_config()
        ok("config.toml loads")
    except ValueError as exc:
        fail(f"config.toml corrupt or unreadable: {exc}")
        print(
            "  Fix config.toml or delete it and re-run `forge-conductor install`.",
            file=out,
        )
        cfg = None
    except Exception as exc:  # noqa: BLE001
        fail(f"config load error: {exc}")
        cfg = None

    # --- store ---
    try:
        from forge_conductor.store import SCHEMA_VERSION, connect, migrate

        conn = connect()
        migrate(conn)
        row = conn.execute("SELECT version FROM schema_version LIMIT 1").fetchone()
        ver = row["version"] if row is not None else None
        conn.close()
        ok(f"store migrates (schema_version={ver}, expected={SCHEMA_VERSION})")
    except Exception as exc:  # noqa: BLE001
        fail(f"store migrate failed: {exc}")

    # --- tool modules ---
    tool_modules = [
        "forge_conductor.tools.filesystem",
        "forge_conductor.tools.shell",
        "forge_conductor.tools.git",
        "forge_conductor.tools.search",
        "forge_conductor.tools.memory",
        "forge_conductor.tools.browser",
        "forge_conductor.tools.research",
        "forge_conductor.tools.agents",
        "forge_conductor.tools.coord",
        "forge_conductor.tools.meta",
        "forge_conductor.tools.inventory",
        "forge_conductor.tools.github_gh",
        "forge_conductor.tools.vsbuild",
        "forge_conductor.tools.python_exec",
    ]
    for mod in tool_modules:
        try:
            importlib.import_module(mod)
            ok(f"import {mod}")
        except Exception as exc:  # noqa: BLE001
            fail(f"import {mod}: {exc}")

    # --- playwright (warn) ---
    pw_ok, pw_msg = _check_playwright_chromium()
    if pw_ok:
        ok(f"playwright {pw_msg}")
    else:
        warn(
            f"playwright chromium: {pw_msg} "
            "(run: uv run playwright install chromium)"
        )

    # --- git on PATH (warn) ---
    git_path = shutil.which("git")
    if git_path:
        ok(f"git on PATH ({git_path})")
    else:
        warn("git not found on PATH (git_* tools will fail)")

    # --- coordinator lock / home writable (warn if not writable) ---
    try:
        home.mkdir(parents=True, exist_ok=True)
        lock_path = home / "coordinator.lock"
        with open(lock_path, "a", encoding="utf-8") as f:
            f.write("")
        ok(f"coordinator lock writable ({lock_path})")
    except OSError as exc:
        warn(f"coordinator lock not writable: {exc}")

    # --- config section presence (informational) ---
    if cfg is not None:
        coord = cfg.get("coordinator") or {}
        enabled = coord.get("enabled", True)
        ok(f"coordinator.enabled = {enabled}")

    # --- multi-host serve path / registration (compat) ---
    try:
        from forge_conductor.paths import (
            default_venv_exe,
            ensure_home_launcher,
            resolve_serve_command,
        )

        launcher = ensure_home_launcher()
        if launcher.is_file():
            ok(f"home serve launcher: {launcher}")
        else:
            warn(f"home serve launcher missing: {launcher}")
        venv_exe = default_venv_exe()
        if venv_exe.is_file():
            ok(f"venv forge-conductor: {venv_exe}")
        else:
            fail(f"venv forge-conductor missing: {venv_exe}")
        cmd, args = resolve_serve_command()
        ok(f"resolved serve: {cmd} {args}")
    except Exception as exc:  # noqa: BLE001
        warn(f"serve path resolution: {exc}")

    # Host config presence (warn only — hosts are optional)
    try:
        lm = Path.home() / ".lmstudio" / "mcp.json"
        if lm.is_file():
            import json

            data = json.loads(lm.read_text(encoding="utf-8"))
            servers = data.get("mcpServers") or {}
            forge_keys = {k for k in servers if str(k).startswith("forge-conductor")}
            foreign = set(servers.keys()) - forge_keys
            if "forge-conductor" in servers:
                ok(
                    f"LM Studio mcp.json forge servers={sorted(forge_keys)}"
                    + (f" foreign={sorted(foreign)}" if foreign else "")
                )
                if "forge-conductor-fallback" not in servers:
                    warn(
                        "LM Studio missing forge-conductor-fallback "
                        "(run: forge-conductor register lmstudio)"
                    )
                if foreign:
                    warn(
                        "LM Studio has non-forge MCP servers; charter prefers forge-only family"
                    )
            else:
                warn("LM Studio mcp.json missing forge-conductor (register lmstudio)")
        else:
            warn("LM Studio mcp.json not found")
    except Exception as exc:  # noqa: BLE001
        warn(f"LM Studio mcp check: {exc}")

    try:
        codex = Path.home() / ".codex" / "config.toml"
        if codex.is_file():
            text = codex.read_text(encoding="utf-8")
            if "[mcp_servers.forge-conductor]" in text:
                ok(f"Codex config has forge-conductor ({codex})")
            else:
                warn(f"Codex config missing forge-conductor ({codex})")
        else:
            warn("Codex config.toml not found (optional)")
    except Exception as exc:  # noqa: BLE001
        warn(f"Codex config check: {exc}")

    # Prune dead presence (non-critical hygiene)
    try:
        from forge_conductor.store import connect as _connect

        pconn = _connect()
        pruned = _prune_stale_presence(pconn)
        pconn.close()
        if pruned:
            ok(f"pruned {pruned} stale presence row(s)")
        else:
            ok("presence table clean (no dead PIDs)")
    except Exception as exc:  # noqa: BLE001
        warn(f"presence prune: {exc}")

    print(file=out)
    if critical_ok:
        print(
            f"Doctor result: PASS (critical ok"
            + (f", {len(warnings)} warning(s)" if warnings else "")
            + ")",
            file=out,
        )
        return 0
    print("Doctor result: FAIL (critical checks failed)", file=out)
    return 1


def _pid_alive(pid: int) -> bool:
    """Return True if *pid* appears to be a live process (Windows + POSIX)."""
    import os
    import sys

    if pid <= 0:
        return False
    if sys.platform == "win32":
        try:
            import ctypes
            from ctypes import wintypes

            PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
            kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
            handle = kernel32.OpenProcess(
                PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid)
            )
            if handle:
                kernel32.CloseHandle(handle)
                return True
            return False
        except Exception:  # noqa: BLE001
            return False
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, SystemError, ValueError):
        return False


def _prune_stale_presence(conn: Any) -> int:
    """Delete presence rows that are dead or past heartbeat TTL.

    Windows reuses PIDs (e.g. old forge pid becomes svchost), so PID-alive alone
    is insufficient — also drop rows with last_heartbeat older than presence TTL.
    """
    from datetime import datetime, timedelta, timezone

    from forge_conductor.config import load_config

    cfg = load_config()
    ttl = int((cfg.get("coordinator") or {}).get("presence_ttl_sec", 30))
    # Use a generous multiple so active servers (heartbeat ~TTL/2) are not
    # pruned mid-session; 5x covers slow hosts and clock skew.
    cutoff = (
        datetime.now(timezone.utc).replace(microsecond=0)
        - timedelta(seconds=max(ttl * 5, 120))
    ).isoformat().replace("+00:00", "Z")

    removed = 0
    # Heartbeat age first (handles PID reuse)
    cur = conn.execute(
        "DELETE FROM presence WHERE last_heartbeat < ?",
        (cutoff,),
    )
    removed += cur.rowcount if cur.rowcount and cur.rowcount > 0 else 0

    rows = conn.execute("SELECT client_id, pid FROM presence").fetchall()
    for row in rows:
        pid = row["pid"]
        if pid is None:
            continue
        if not _pid_alive(int(pid)):
            conn.execute(
                "DELETE FROM presence WHERE client_id = ?", (row["client_id"],)
            )
            removed += 1
    if removed:
        conn.commit()
    return removed


def status(*, stream: Any = None) -> int:
    """Print home, version, schema, tool/agent counts, presence, coord mode."""
    out = stream if stream is not None else sys.stdout
    from forge_conductor.agents_loader import load_agents
    from forge_conductor.config import ensure_home, get_home, load_config
    from forge_conductor.server import TOOL_NAMES, build_mcp
    from forge_conductor.store import SCHEMA_VERSION, connect, migrate

    home = ensure_home()
    try:
        cfg = load_config()
    except ValueError as exc:
        print(f"status: cannot load config: {exc}", file=out)
        print("Run: forge-conductor doctor", file=out)
        return 1

    conn = connect()
    migrate(conn)
    row = conn.execute("SELECT version FROM schema_version LIMIT 1").fetchone()
    schema = row["version"] if row is not None else None

    build_mcp()
    tool_count = len(TOOL_NAMES)
    agents = load_agents(home)
    agent_count = len(agents)

    presence_rows = conn.execute(
        "SELECT client_id, host_kind, pid, cwd, last_heartbeat FROM presence"
    ).fetchall()
    presence_count = len(presence_rows)

    coord_cfg = cfg.get("coordinator") or {}
    coord_enabled = bool(coord_cfg.get("enabled", True))
    # v1 always uses SQLite-local mode
    coord_mode = "local" if coord_enabled else "disabled"

    print(f"home:         {get_home()}", file=out)
    print(f"version:      {__version__}", file=out)
    print(f"schema:       {schema} (package expects {SCHEMA_VERSION})", file=out)
    print(f"tools:        {tool_count}", file=out)
    print(f"agents:       {agent_count}", file=out)
    print(f"presence:     {presence_count} row(s)", file=out)
    for p in presence_rows:
        print(
            f"  - {p['client_id']} kind={p['host_kind']} pid={p['pid']} "
            f"hb={p['last_heartbeat']}",
            file=out,
        )
    print(f"coord_mode:   {coord_mode}", file=out)
    print(f"client_id:    n/a (not serving)", file=out)
    conn.close()
    return 0


def register(
    client: str,
    *,
    dry_run: bool = False,
    path: str | None = None,
    sole: bool = False,
) -> int:
    """Register forge-conductor with a host client."""
    from forge_conductor.onboarding import (
        register_claude,
        register_codex,
        register_json,
        register_lmstudio,
    )
    from forge_conductor.paths import ensure_home_launcher

    ensure_home_launcher()
    client = client.lower().strip()
    if client in ("lmstudio", "lm-studio", "lms"):
        code, msg = register_lmstudio(path=path, dry_run=dry_run)
        print(msg)
        return code
    if client == "codex":
        code, msg = register_codex(path=path, dry_run=dry_run)
        print(msg)
        return code
    if client in ("claude", "claude-code", "claude_code"):
        code, msg = register_claude(path=path, dry_run=dry_run)
        print(msg)
        return code
    if client in ("json", "generic", "mcp-json"):
        if not path:
            print("register json requires --path to an mcp.json file", file=sys.stderr)
            return 2
        code, msg = register_json(path, dry_run=dry_run, sole=sole)
        print(msg)
        return code
    print(
        f"Unknown client: {client!r}. Use 'lmstudio', 'codex', 'claude', or 'json'.",
        file=sys.stderr,
    )
    return 2


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="forge-conductor")
    parser.add_argument("--version", action="version", version=__version__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("serve", help="Run MCP server on stdio")
    sub.add_parser(
        "supervise",
        help="Run MCP with automatic backend fail-over (recommended for LM Studio)",
    )
    sub.add_parser(
        "memory-serve",
        help="Run RAM Memory MCP only (stdio) — LM Studio toggle mcp/ram-memory",
    )
    sub.add_parser("install", help="Create home layout and migrate store")
    sub.add_parser("doctor", help="Run health checks")
    sub.add_parser("status", help="Print status summary")

    reg = sub.add_parser(
        "register",
        help="Register with LM Studio, Codex, Claude, or a generic MCP JSON file",
    )
    reg.add_argument(
        "client",
        choices=["lmstudio", "codex", "claude", "json"],
        help="Target client (lmstudio|codex|claude|json)",
    )
    reg.add_argument(
        "--dry-run",
        action="store_true",
        help="Print snippet only; do not write config files",
    )
    reg.add_argument(
        "--path",
        default=None,
        help="Override config path for the target client",
    )
    reg.add_argument(
        "--sole",
        action="store_true",
        help="For json: replace mcpServers with forge-only",
    )

    args = parser.parse_args(argv)

    if args.cmd == "serve":
        from forge_conductor.server import run_stdio

        run_stdio()
        return 0
    if args.cmd == "supervise":
        from forge_conductor.supervisor import run_supervisor

        run_supervisor()
        return 0
    if args.cmd == "memory-serve":
        from forge_conductor.memory_server import run_memory_stdio

        run_memory_stdio()
        return 0
    if args.cmd == "install":
        return install()
    if args.cmd == "doctor":
        return doctor()
    if args.cmd == "status":
        return status()
    if args.cmd == "register":
        return register(
            args.client,
            dry_run=args.dry_run,
            path=args.path,
            sole=getattr(args, "sole", False),
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
