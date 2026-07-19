"""Visual Studio / MSBuild tools (replaces standalone vs-build MCP)."""

from __future__ import annotations

import json
import os
import re
import shutil
from pathlib import Path
from typing import Any

from forge_conductor.subprocess_util import run_capture

_VSWHERE = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / (
    r"Microsoft Visual Studio\Installer\vswhere.exe"
)


def _vswhere() -> Path | None:
    if _VSWHERE.is_file():
        return _VSWHERE
    alt = Path(r"C:\Program Files\Microsoft Visual Studio\Installer\vswhere.exe")
    return alt if alt.is_file() else None


def _list_installs() -> list[dict[str, Any]]:
    vw = _vswhere()
    if not vw:
        return []
    r = run_capture(
        [str(vw), "-all", "-prerelease", "-format", "json", "-products", "*"],
        timeout_sec=30,
    )
    if r.get("exit_code") != 0 or not (r.get("stdout") or "").strip():
        return []
    try:
        data = json.loads(r["stdout"])
    except json.JSONDecodeError:
        return []
    out = []
    for item in data if isinstance(data, list) else []:
        out.append(
            {
                "displayName": item.get("displayName"),
                "installationPath": item.get("installationPath"),
                "installationVersion": item.get("installationVersion"),
            }
        )
    return out


def _msbuild_path(prefer: str | None = None) -> str | None:
    installs = _list_installs()
    if prefer:
        pref = prefer.lower()
        installs = [
            i
            for i in installs
            if pref in (i.get("installationPath") or "").lower()
            or pref in (i.get("displayName") or "").lower()
        ] or installs
    installs = sorted(
        installs, key=lambda i: i.get("installationVersion") or "", reverse=True
    )
    for inst in installs:
        root = Path(inst["installationPath"] or "")
        for rel in (
            r"MSBuild\Current\Bin\MSBuild.exe",
            r"MSBuild\Current\Bin\amd64\MSBuild.exe",
        ):
            p = root / rel
            if p.is_file():
                return str(p)
    vw = _vswhere()
    if vw:
        r = run_capture(
            [
                str(vw),
                "-latest",
                "-prerelease",
                "-requires",
                "Microsoft.Component.MSBuild",
                "-find",
                r"MSBuild\**\Bin\MSBuild.exe",
            ],
            timeout_sec=30,
        )
        for line in (r.get("stdout") or "").splitlines():
            if line.strip() and Path(line.strip()).is_file():
                return line.strip()
    return shutil.which("msbuild")


def register(mcp: Any) -> None:
    from forge_conductor.server import TOOL_NAMES

    @mcp.tool
    def vs_list() -> dict[str, Any]:
        """List installed Visual Studio instances via vswhere."""
        installs = _list_installs()
        return {"ok": bool(installs), "count": len(installs), "installations": installs}

    @mcp.tool
    def vs_toolchain(prefer: str | None = None) -> dict[str, Any]:
        """Resolve MSBuild / devenv paths (prefer e.g. '2022' or '18')."""
        installs = _list_installs()
        msbuild = _msbuild_path(prefer)
        devenv = None
        if installs:
            chosen = sorted(
                installs, key=lambda i: i.get("installationVersion") or "", reverse=True
            )[0]
            d = Path(chosen["installationPath"] or "") / r"Common7\IDE\devenv.exe"
            if d.is_file():
                devenv = str(d)
        return {
            "ok": bool(msbuild),
            "msbuild": msbuild,
            "devenv": devenv,
            "installations": installs,
        }

    @mcp.tool
    def vs_msbuild(
        project: str,
        configuration: str = "Debug",
        platform: str = "x64",
        target: str | None = None,
        timeout_sec: float = 600,
        prefer_vs: str | None = None,
    ) -> dict[str, Any]:
        """Build a .sln/.vcxproj with MSBuild. project= absolute or relative path."""
        proj = Path(project).expanduser()
        if not proj.is_file():
            return {"ok": False, "error": "project_not_found", "path": str(proj)}
        msbuild = _msbuild_path(prefer_vs)
        if not msbuild:
            return {"ok": False, "error": "msbuild_missing"}
        args = [
            msbuild,
            str(proj),
            f"/p:Configuration={configuration}",
            f"/p:Platform={platform}",
            "/v:minimal",
            "/nologo",
            "/m",
        ]
        if target:
            args.append(f"/t:{target}")
        r = run_capture(
            args,
            cwd=str(proj.parent),
            timeout_sec=float(timeout_sec),
            max_timeout_sec=max(float(timeout_sec), 600),
        )
        return {
            "ok": r.get("exit_code") == 0 and not r.get("timed_out"),
            "exit_code": r.get("exit_code"),
            "timed_out": r.get("timed_out"),
            "stdout": r.get("stdout") or "",
            "stderr": r.get("stderr") or "",
            "msbuild": msbuild,
            "project": str(proj),
            "configuration": configuration,
            "platform": platform,
        }

    @mcp.tool
    def vs_build_script(
        script: str,
        args: list[str] | None = None,
        timeout_sec: float = 600,
        cwd: str | None = None,
    ) -> dict[str, Any]:
        """Run a PowerShell build script (e.g. windows/build/build.ps1).

        Example args: ['-Configuration','Release','-Platform','x64','-Test']
        """
        sp = Path(script).expanduser()
        if not sp.is_file():
            return {"ok": False, "error": "script_not_found", "path": str(sp)}
        # sanitize args
        safe_args: list[str] = []
        for a in args or []:
            if not re.match(r"^-{0,2}[A-Za-z0-9_./\\:=+-]+$", a):
                return {"ok": False, "error": "invalid_arg", "arg": a}
            safe_args.append(a)
        cmd = [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(sp),
            *safe_args,
        ]
        r = run_capture(
            cmd,
            cwd=cwd or str(sp.parent),
            timeout_sec=float(timeout_sec),
            max_timeout_sec=max(float(timeout_sec), 600),
        )
        return {
            "ok": r.get("exit_code") == 0 and not r.get("timed_out"),
            "exit_code": r.get("exit_code"),
            "timed_out": r.get("timed_out"),
            "stdout": r.get("stdout") or "",
            "stderr": r.get("stderr") or "",
            "script": str(sp),
            "args": safe_args,
        }

    TOOL_NAMES.update(
        {
            "vs_list",
            "vs_toolchain",
            "vs_msbuild",
            "vs_build_script",
        }
    )
