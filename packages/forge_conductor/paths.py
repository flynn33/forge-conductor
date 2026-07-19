"""Canonical serve entry resolution for multi-host registration."""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Any

# Launcher templates — __FORGE_APP_ROOT__ replaced at write time with install path.
_PRIMARY_LAUNCHER = r"""@echo off
setlocal EnableExtensions
set "FORGE_CONDUCTOR_HOME=%USERPROFILE%\.forge-conductor"
if defined FORGE_CONDUCTOR_HOME_OVERRIDE set "FORGE_CONDUCTOR_HOME=%FORGE_CONDUCTOR_HOME_OVERRIDE%"
set "FORGE_MCP_ROLE=primary"
set "FASTMCP_SHOW_SERVER_BANNER=false"
set "GH_PROMPT_DISABLED=1"
set "GIT_TERMINAL_PROMPT=0"
set "GCM_INTERACTIVE=never"
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
set "PATH=C:\Program Files\GitHub CLI;C:\Program Files\Git\cmd;C:\Program Files\nodejs;%USERPROFILE%\.local\bin;C:\WINDOWS\system32;C:\WINDOWS;%PATH%"
set "WT=__FORGE_APP_ROOT__"
set "VENV_EXE=%WT%\.venv\Scripts\forge-conductor.exe"
set "VENV_PY=%WT%\.venv\Scripts\python.exe"
set "LOGDIR=%FORGE_CONDUCTOR_HOME%\logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
echo [%DATE% %TIME%] primary launcher start role=primary >> "%LOGDIR%\launcher.log"
if exist "%VENV_EXE%" (
  "%VENV_EXE%" supervise
  set "EC=%ERRORLEVEL%"
  echo [%DATE% %TIME%] primary supervise exit ec=%EC% >> "%LOGDIR%\launcher.log"
  exit /b %EC%
)
if exist "%VENV_PY%" (
  "%VENV_PY%" -m forge_conductor supervise
  set "EC=%ERRORLEVEL%"
  echo [%DATE% %TIME%] primary py-m supervise exit ec=%EC% >> "%LOGDIR%\launcher.log"
  exit /b %EC%
)
where forge-conductor >nul 2>&1
if not errorlevel 1 (
  forge-conductor supervise
  set "EC=%ERRORLEVEL%"
  echo [%DATE% %TIME%] primary path supervise exit ec=%EC% >> "%LOGDIR%\launcher.log"
  exit /b %EC%
)
if exist "%VENV_EXE%" (
  "%VENV_EXE%" serve
  exit /b %ERRORLEVEL%
)
echo [%DATE% %TIME%] primary ALL launch candidates failed >> "%LOGDIR%\launcher.log"
echo forge-serve: ALL launch candidates failed 1>&2
exit /b 1
"""

_FALLBACK_LAUNCHER = r"""@echo off
setlocal EnableExtensions
set "FORGE_CONDUCTOR_HOME=%USERPROFILE%\.forge-conductor"
if defined FORGE_CONDUCTOR_HOME_OVERRIDE set "FORGE_CONDUCTOR_HOME=%FORGE_CONDUCTOR_HOME_OVERRIDE%"
set "FORGE_MCP_ROLE=fallback"
set "FASTMCP_SHOW_SERVER_BANNER=false"
set "GH_PROMPT_DISABLED=1"
set "GIT_TERMINAL_PROMPT=0"
set "GCM_INTERACTIVE=never"
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
set "WT=__FORGE_APP_ROOT__"
set "VENV_EXE=%WT%\.venv\Scripts\forge-conductor.exe"
set "VENV_PY=%WT%\.venv\Scripts\python.exe"
set "PATH=%WT%\.venv\Scripts;C:\Program Files\GitHub CLI;C:\Program Files\Git\cmd;C:\Program Files\nodejs;%USERPROFILE%\.local\bin;C:\WINDOWS\system32;C:\WINDOWS;%PATH%"
set "LOGDIR=%FORGE_CONDUCTOR_HOME%\logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
echo [%DATE% %TIME%] fallback launcher start role=fallback >> "%LOGDIR%\launcher.log"
if exist "%VENV_EXE%" (
  "%VENV_EXE%" supervise
  set "EC=%ERRORLEVEL%"
  echo [%DATE% %TIME%] fallback supervise exit ec=%EC% >> "%LOGDIR%\launcher.log"
  exit /b %EC%
)
if exist "%VENV_PY%" (
  "%VENV_PY%" -m forge_conductor supervise
  set "EC=%ERRORLEVEL%"
  echo [%DATE% %TIME%] fallback py-m supervise exit ec=%EC% >> "%LOGDIR%\launcher.log"
  exit /b %EC%
)
where forge-conductor >nul 2>&1
if not errorlevel 1 (
  forge-conductor supervise
  set "EC=%ERRORLEVEL%"
  echo [%DATE% %TIME%] fallback path supervise exit ec=%EC% >> "%LOGDIR%\launcher.log"
  exit /b %EC%
)
if exist "%VENV_EXE%" (
  "%VENV_EXE%" serve
  exit /b %ERRORLEVEL%
)
echo [%DATE% %TIME%] fallback ALL launch candidates failed >> "%LOGDIR%\launcher.log"
echo forge-serve-fallback: ALL candidates failed 1>&2
exit /b 1
"""

# Dedicated RAM Memory MCP — visible toggle in LM Studio (mcp/ram-memory)
_MEMORY_LAUNCHER = r"""@echo off
setlocal EnableExtensions
set "FORGE_CONDUCTOR_HOME=%USERPROFILE%\.forge-conductor"
if defined FORGE_CONDUCTOR_HOME_OVERRIDE set "FORGE_CONDUCTOR_HOME=%FORGE_CONDUCTOR_HOME_OVERRIDE%"
set "FORGE_MCP_ROLE=memory"
set "FASTMCP_SHOW_SERVER_BANNER=false"
set "GH_PROMPT_DISABLED=1"
set "GIT_TERMINAL_PROMPT=0"
set "GCM_INTERACTIVE=never"
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
set "WT=__FORGE_APP_ROOT__"
set "VENV_EXE=%WT%\.venv\Scripts\forge-conductor.exe"
set "VENV_PY=%WT%\.venv\Scripts\python.exe"
set "PATH=%WT%\.venv\Scripts;C:\Program Files\GitHub CLI;C:\Program Files\Git\cmd;C:\Program Files\nodejs;%USERPROFILE%\.local\bin;C:\WINDOWS\system32;C:\WINDOWS;%PATH%"
set "LOGDIR=%FORGE_CONDUCTOR_HOME%\logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
echo [%DATE% %TIME%] ram-memory launcher start >> "%LOGDIR%\launcher.log"
if exist "%VENV_EXE%" (
  "%VENV_EXE%" memory-serve
  set "EC=%ERRORLEVEL%"
  echo [%DATE% %TIME%] ram-memory exit ec=%EC% >> "%LOGDIR%\launcher.log"
  exit /b %EC%
)
if exist "%VENV_PY%" (
  "%VENV_PY%" -m forge_conductor memory-serve
  set "EC=%ERRORLEVEL%"
  echo [%DATE% %TIME%] ram-memory py-m exit ec=%EC% >> "%LOGDIR%\launcher.log"
  exit /b %EC%
)
where forge-conductor >nul 2>&1
if not errorlevel 1 (
  forge-conductor memory-serve
  set "EC=%ERRORLEVEL%"
  echo [%DATE% %TIME%] ram-memory path exit ec=%EC% >> "%LOGDIR%\launcher.log"
  exit /b %EC%
)
echo [%DATE% %TIME%] ram-memory ALL launch candidates failed >> "%LOGDIR%\launcher.log"
echo forge-memory-serve: ALL launch candidates failed 1>&2
exit /b 1
"""


def worktree_root() -> Path:
    """Installed app root (contains .venv) or source checkout root."""
    # Prefer explicit env from portable installer
    env = os.environ.get("FORGE_APP_ROOT") or os.environ.get("FORGE_CONDUCTOR_APP")
    if env:
        return Path(env)
    # package layout: .../app/src/forge_conductor/paths.py → parents[2] = app
    return Path(__file__).resolve().parents[2]


def default_serve_cmd() -> Path:
    return worktree_root() / "scripts" / "lmstudio-serve.cmd"


def default_venv_exe() -> Path:
    return worktree_root() / ".venv" / "Scripts" / "forge-conductor.exe"


def home_serve_launcher() -> Path:
    from forge_conductor.config import get_home

    return get_home() / "bin" / "forge-serve.cmd"


def home_serve_fallback_launcher() -> Path:
    from forge_conductor.config import get_home

    return get_home() / "bin" / "forge-serve-fallback.cmd"


def home_memory_launcher() -> Path:
    from forge_conductor.config import get_home

    return get_home() / "bin" / "forge-memory-serve.cmd"


def forge_env() -> dict[str, str]:
    from forge_conductor.config import get_home

    return {
        "FORGE_CONDUCTOR_HOME": str(get_home()),
        "FASTMCP_SHOW_SERVER_BANNER": "false",
        "GH_PROMPT_DISABLED": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "GCM_INTERACTIVE": "never",
        "PYTHONUTF8": "1",
        "PYTHONIOENCODING": "utf-8",
    }


def _render_launcher(template: str, app_root: Path | None = None) -> str:
    root = (app_root or worktree_root()).resolve()
    # cmd-safe path
    rendered = template.replace("__FORGE_APP_ROOT__", str(root))
    return rendered.replace("\n", "\r\n")


def ensure_home_launcher() -> Path:
    from forge_conductor.config import ensure_home

    ensure_home()
    launcher = home_serve_launcher()
    fallback = home_serve_fallback_launcher()
    memory = home_memory_launcher()
    launcher.parent.mkdir(parents=True, exist_ok=True)
    app = worktree_root()
    launcher.write_text(_render_launcher(_PRIMARY_LAUNCHER, app), encoding="utf-8")
    fallback.write_text(_render_launcher(_FALLBACK_LAUNCHER, app), encoding="utf-8")
    memory.write_text(_render_launcher(_MEMORY_LAUNCHER, app), encoding="utf-8")
    return launcher


def resolve_serve_command() -> tuple[str, list[str]]:
    try:
        home_cmd = ensure_home_launcher()
        if home_cmd.is_file():
            return str(home_cmd), []
    except OSError:
        pass
    wt = default_serve_cmd()
    if wt.is_file():
        return str(wt), []
    venv = default_venv_exe()
    if venv.is_file():
        return str(venv), ["supervise"]
    which = shutil.which("forge-conductor")
    if which:
        return which, ["supervise"]
    return "forge-conductor", ["supervise"]


def mcp_server_block() -> dict[str, Any]:
    command, args = resolve_serve_command()
    return {"command": command, "args": args, "env": forge_env()}


def mcp_fallback_server_block() -> dict[str, Any]:
    ensure_home_launcher()
    return {
        "command": str(home_serve_fallback_launcher()),
        "args": [],
        "env": forge_env(),
    }


def mcp_memory_server_block() -> dict[str, Any]:
    """Dedicated RAM Memory MCP — first-class LM Studio toggle."""
    ensure_home_launcher()
    return {
        "command": str(home_memory_launcher()),
        "args": [],
        "env": forge_env(),
    }


def mcp_dual_servers() -> dict[str, Any]:
    """Forge family for LM Studio: RAM memory + primary + fallback.

    ``ram-memory`` is listed first so it appears at the top of the MCP frame.
    """
    return {
        "ram-memory": mcp_memory_server_block(),
        "forge-conductor": mcp_server_block(),
        "forge-conductor-fallback": mcp_fallback_server_block(),
    }


def codex_toml_block() -> str:
    command, args = resolve_serve_command()
    cmd = command.replace("\\", "\\\\")
    lines = [
        "[mcp_servers.forge-conductor]",
        f'command = "{cmd}"',
    ]
    if args:
        args_lit = ", ".join(f'"{a}"' for a in args)
        lines.append(f"args = [{args_lit}]")
    else:
        lines.append("args = []")
    lines.append("")
    lines.append("[mcp_servers.forge-conductor.env]")
    for k, v in forge_env().items():
        vv = v.replace("\\", "\\\\")
        lines.append(f'{k} = "{vv}"')
    lines.append("")
    return "\n".join(lines)
