"""Agent backend mode: host (local LM) vs grok (external worker).

Single source of truth: {FORGE_HOME}/agent_backend.json
Survives RAM-disk unload when snapshotted into durable state.
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
import time
from copy import deepcopy
from pathlib import Path
from typing import Any

_LOCK = threading.RLock()
_STATE_NAME = "agent_backend.json"

DEFAULT_STATE: dict[str, Any] = {
    "version": 2,
    "mode": "host",  # host | grok
    "generation": 0,
    # Primary executor when mode=grok: Grok Build TUI session (paste connect prompt).
    # Optional cloud API worker is secondary and not required.
    "executor": "grok_build",
    "grok": {
        "enabled": True,
        "executor": "grok_build",  # grok_build | xai_api (optional)
        "api_base": "https://api.x.ai/v1",
        "model": "grok-3",
        "api_key_env": "XAI_API_KEY",
        "timeout_sec": 600,
        "max_tool_rounds": 40,
    },
    "policy": {
        "when_grok_mandatory_agents": True,
        "when_grok_block_host_mutations": True,
        "fallback_to_host_on_worker_error": False,
    },
    "last_changed_at": None,
    "last_changed_by": None,
    "connect_prompt_path": None,
    "notify": {
        "lmstudio_synced_generation": 0,
        "lmstudio_last_error": None,
    },
}

# Host (Qwen) may call these freely even in grok mode
HOST_ALWAYS_ALLOWED: frozenset[str] = frozenset(
    {
        "session_bootstrap",
        "inventory_tools",
        "forge_status",
        "forge_audit_tail",
        "forge_config_get",
        "agent_backend_status",
        "agent_backend_set",
        "agent_backend_worker_ping",
        "agent_run_start",
        "agent_run_status",
        "agent_list",
        "agent_recommend",
        "agent_get",
        "agent_context",
        "agent_chain_recommend",
        "agent_session_list",
        "orchestration_status",
        "orchestration_flush",
        "orchestration_reload",
        "memory_get",
        "memory_search",
        "memory_list",
        "memory_stats",
        "memory_set",
        "memory_delete",
        "memory_flush",
        "project_focus",
        "project_current",
        "handoff_save",
        "handoff_load",
        "ram_status",
        "fail_forward",
        "host_hygiene",
        "precommit_gate",
        "coord_status",
        "coord_presence_list",
    }
)

# Prefixes blocked for host when mode=grok (specialist work)
HOST_BLOCKED_PREFIXES: tuple[str, ...] = (
    "fs_write",
    "fs_edit",
    "fs_mkdir",
    "fs_delete",
    "fs_move",
    "fs_copy",
    "shell_exec",
    "shell_run",
    "git_add",
    "git_commit",
    "git_push",
    "git_checkout",
    "git_branch",
    "git_merge",
    "git_rebase",
    "git_stash",
    "git_reset",
    "git_tag",
    "gh_pr_create",
    "gh_pr_merge",
    "gh_issue_create",
    "python_exec",
    "python_run",
    "vs_build",
    "browser_",
    "research_",
)

# Exact names blocked for host in grok mode
HOST_BLOCKED_EXACT: frozenset[str] = frozenset(
    {
        "agent_run_complete",  # worker completes
        "fs_write",
        "fs_edit",
        "shell_exec",
    }
)


def _home() -> Path:
    return Path(os.environ.get("FORGE_CONDUCTOR_HOME", Path.home() / ".forge-conductor"))


def state_path(home: Path | None = None) -> Path:
    return (home or _home()) / _STATE_NAME


def _utc() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def load_state(home: Path | None = None) -> dict[str, Any]:
    path = state_path(home)
    with _LOCK:
        if not path.is_file():
            st = deepcopy(DEFAULT_STATE)
            save_state(st, home=home, bump=False)
            return st
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(raw, dict):
                return deepcopy(DEFAULT_STATE)
            merged = deepcopy(DEFAULT_STATE)
            _deep_update(merged, raw)
            return merged
        except (OSError, json.JSONDecodeError):
            return deepcopy(DEFAULT_STATE)


def save_state(
    state: dict[str, Any],
    *,
    home: Path | None = None,
    bump: bool = False,
    changed_by: str | None = None,
) -> dict[str, Any]:
    path = state_path(home)
    with _LOCK:
        st = deepcopy(state)
        if bump:
            st["generation"] = int(st.get("generation") or 0) + 1
            st["last_changed_at"] = _utc()
            if changed_by:
                st["last_changed_by"] = changed_by
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(st, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        tmp.replace(path)
        # Mirror to disk home if live is RAM disk
        try:
            disk_home = Path.home() / ".forge-conductor"
            live = home or _home()
            if live.resolve() != disk_home.resolve():
                disk_path = disk_home / _STATE_NAME
                disk_path.write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
        except OSError:
            pass
        return st


def _deep_update(base: dict[str, Any], override: dict[str, Any]) -> None:
    for k, v in override.items():
        if k in base and isinstance(base[k], dict) and isinstance(v, dict):
            _deep_update(base[k], v)
        else:
            base[k] = v


def get_mode(home: Path | None = None) -> str:
    mode = str(load_state(home).get("mode") or "host").strip().lower()
    return mode if mode in ("host", "grok") else "host"


def set_mode(
    mode: str,
    *,
    home: Path | None = None,
    changed_by: str = "api",
    reason: str | None = None,
    notify: bool = True,
) -> dict[str, Any]:
    mode = str(mode or "").strip().lower()
    if mode not in ("host", "grok"):
        raise ValueError(f"mode must be host|grok, got {mode!r}")
    st = load_state(home)
    st["mode"] = mode
    if reason:
        st["last_reason"] = reason
    st = save_state(st, home=home, bump=True, changed_by=changed_by)
    connect_payload: dict[str, Any] | None = None
    if mode == "grok":
        try:
            connect_payload = write_connect_prompt(home)
        except Exception as exc:  # noqa: BLE001
            connect_payload = {"ok": False, "error": str(exc)}
    if notify:
        notify_result = run_lmstudio_notify(home=home)
        st = load_state(home)
        st.setdefault("notify", {})
        if notify_result.get("ok"):
            st["notify"]["lmstudio_synced_generation"] = st.get("generation")
            st["notify"]["lmstudio_last_error"] = None
        else:
            st["notify"]["lmstudio_last_error"] = notify_result.get("error")
        st = save_state(st, home=home, bump=False)
        st["notify_result"] = notify_result
    if connect_payload is not None:
        st["connect_prompt"] = {
            "ok": connect_payload.get("ok"),
            "paths": connect_payload.get("paths"),
            "generation": connect_payload.get("generation"),
            # full text for dashboard popup
            "text": connect_payload.get("prompt"),
        }
    return st


def policy_banner(home: Path | None = None) -> dict[str, Any]:
    st = load_state(home)
    mode = get_mode(home)
    gen = int(st.get("generation") or 0)
    if mode == "grok":
        return {
            "mode": "grok",
            "generation": gen,
            "policy": "MANDATORY_OFFLOAD",
            "executor": "grok",
            "rules": [
                "You are the LOCAL ROUTER only. Grok Build (operator session) executes sub-agents.",
                "Non-trivial software work: ONLY agent_run_start — do not fs_write/shell/git yourself.",
                "Poll agent_run_status until completed/failed.",
                "Summarize the agent report; do not re-do specialist work.",
                "Continuity (memory_*/handoff_*/project_*) is allowed.",
                "If a tool returns agent_backend block, obey it.",
            ],
            "forbidden_while_grok": [
                "fs_write",
                "shell_exec",
                "git mutators",
                "python_exec",
                "agent_run_complete (Grok Build completes)",
            ],
            "executor": "grok_build",
        }
    return {
        "mode": "host",
        "generation": gen,
        "policy": "HOST_EXECUTES_AGENTS",
        "executor": "host",
        "rules": [
            "Local model executes agent playbooks after agent_run_start.",
            "Prefer sub-agents for non-trivial work (soft preference).",
        ],
    }


def host_tool_allowed(tool: str, *, home: Path | None = None) -> tuple[bool, str | None]:
    """Return (allowed, block_message). Executor env FORGE_AGENT_EXECUTOR=grok bypasses blocks."""
    if os.environ.get("FORGE_AGENT_EXECUTOR", "").lower() in ("grok", "grok_build"):
        return True, None
    if get_mode(home) != "grok":
        return True, None
    st = load_state(home)
    policy = st.get("policy") or {}
    if not policy.get("when_grok_block_host_mutations", True):
        return True, None

    name = str(tool or "")
    if name in HOST_ALWAYS_ALLOWED:
        return True, None
    # read-only-ish tools with common prefixes
    if name.startswith(
        (
            "memory_",
            "agent_",
            "coord_",
            "orchestration_",
            "forge_",
            "fs_read",
            "fs_stat",
            "fs_list",
            "fs_glob",
            "fs_search",
            "git_status",
            "git_diff",
            "git_log",
            "git_show",
            "git_branch_list",
            "search_",
            "inventory_",
            "session_",
            "project_",
            "handoff_",
            "ram_",
            "precommit_",
            "fail_",
            "host_",
        )
    ):
        # Still block agent_run_complete and mutators that share prefixes
        if name in HOST_BLOCKED_EXACT or name == "agent_run_complete":
            pass  # fall through to block check
        elif not any(name == p or name.startswith(p) for p in HOST_BLOCKED_PREFIXES):
            if name not in ("agent_run_complete",):
                return True, None

    if name in HOST_BLOCKED_EXACT or any(
        name == p or name.startswith(p.rstrip("_") if p.endswith("_") else p)
        for p in HOST_BLOCKED_PREFIXES
    ):
        # refine: allow fs_read etc already handled
        if name.startswith(("fs_read", "fs_stat", "fs_list", "fs_glob", "git_status", "git_diff", "git_log", "git_show")):
            return True, None
        msg = (
            f"agent_backend mode=grok (generation={st.get('generation')}): "
            f"host must not execute specialist tool '{name}'. "
            "Call agent_run_start(agent_id=..., goal=...) and poll agent_run_status. "
            "Grok Build runs sub-agents; you are the local router only."
        )
        return False, msg

    # Default allow unknown read tools; block unknown write-looking names
    if any(x in name for x in ("write", "delete", "exec", "run", "commit", "push", "merge")):
        msg = (
            f"agent_backend mode=grok: blocked host tool '{name}'. "
            "Use agent_run_start for specialist work."
        )
        return False, msg
    return True, None


def worker_ping(home: Path | None = None) -> dict[str, Any]:
    """Health of Grok Build attachment (heartbeat) — no API key required."""
    h = home or _home()
    st = load_state(h)
    grok = st.get("grok") or {}
    # Primary: Grok Build session heartbeat (written when attach prompt is followed)
    hb_paths = [
        h / "logs" / "grok-build.heartbeat",
        Path.home() / ".forge-conductor" / "logs" / "grok-build.heartbeat",
        h / "logs" / "grok-worker.heartbeat",  # legacy optional API worker
    ]
    heartbeat_age = None
    attached = False
    hb_used = None
    for hb in hb_paths:
        if not hb.is_file():
            continue
        try:
            age = time.time() - hb.stat().st_mtime
            if heartbeat_age is None or age < heartbeat_age:
                heartbeat_age = age
                hb_used = str(hb)
            if age < 120:  # 2 min — interactive session
                attached = True
        except OSError:
            pass
    connect_path = h / "lmstudio" / "grok-build-connect-prompt.md"
    if not connect_path.is_file():
        connect_path = Path.home() / ".forge-conductor" / "lmstudio" / "grok-build-connect-prompt.md"
    return {
        "ok": True,
        "mode": get_mode(h),
        "executor": "grok_build",
        "grok_build_attached": attached,
        "worker_alive": attached,  # dashboard alias
        "api_key_required": False,
        "api_key_configured": None,  # not required for grok_build
        "heartbeat_path": hb_used,
        "worker_heartbeat_age_sec": round(heartbeat_age, 1) if heartbeat_age is not None else None,
        "worker_enabled": bool(grok.get("enabled", True)),
        "connect_prompt_ready": connect_path.is_file(),
        "connect_prompt_path": str(connect_path) if connect_path.is_file() else None,
    }


def build_grok_build_connect_prompt(home: Path | None = None) -> str:
    """Auto-generated paste-into-Grok-Build instruction (plugin-style)."""
    h = home or _home()
    st = load_state(h)
    gen = int(st.get("generation") or 0)
    disk = Path.home() / ".forge-conductor"
    r_home = Path("R:/home")
    live = str(r_home) if r_home.is_dir() else str(h)
    stack_loaded = r_home.is_dir()
    prompt_path = disk / "lmstudio" / "grok-build-connect-prompt.md"
    ctl = disk / "scripts" / "grok-build-agent-ctl.py"
    ab_disk = disk / "agent_backend.json"
    lines = [
        "# Forge-Conductor · Grok Build Agent Plugin (ACTIVE)",
        "",
        "You are **Grok Build** on this Windows AI rig. The operator clicked **GROK** on the Forge Rig Dashboard.",
        "You are now the **sub-agent executor** for Forge-Conductor. LM Studio’s local model (Qwen) is **router only**.",
        "",
        "## What this plugin is",
        "- **Forge-Conductor** = local orchestration layer (agents, memory, git/fs/shell, MCP).",
        f"- **Mode** = `grok` (generation **{gen}**).",
        "- **Your job** = claim and run agent jobs (explore/plan/implement/…), use tools on this machine, complete sessions, keep the operator informed in this chat.",
        "- **Not required** = xAI API keys. You *are* the brain; tools stay local.",
        "",
        "## Prerequisites",
        "1. Stack **LOADED** on the dashboard (http://127.0.0.1:7788/) when using on-demand RAM orchestration.",
        f"2. Backend state: `{ab_disk}` (and `{live}\\\\agent_backend.json` if RAM stack is up).",
        "3. LM Studio: **mcp/forge-conductor** ON; prefer a **new chat** after the toggle so Qwen sees MANDATORY_OFFLOAD.",
        "",
        "## Where to look",
        f"| Disk Forge home | `{disk}` |",
        f"| Live home | `{live}` |",
        f"| Saved copy of this prompt | `{prompt_path}` |",
        f"| Control CLI | `{ctl}` |",
        f"| Heartbeat file (you refresh) | `logs/grok-build.heartbeat` under Forge home |",
        f"| Stack LOADED (best-effort) | **{stack_loaded}** |",
        "",
        "## Connect (run first in this Grok Build session)",
        "```powershell",
        "if (Test-Path 'R:\\home') { $env:FORGE_CONDUCTOR_HOME = 'R:\\home' } else { $env:FORGE_CONDUCTOR_HOME = \"$env:USERPROFILE\\.forge-conductor\" }",
        "$env:FORGE_AGENT_EXECUTOR = 'grok'",
        "if ($env:FORGE_SOURCE_ROOT) { $env:PYTHONPATH = $env:FORGE_SOURCE_ROOT } elseif (Test-Path 'R:\\app\\src') { $env:PYTHONPATH = 'R:\\app\\src' }",
        "if ($env:FORGE_PYTHON) { $py = $env:FORGE_PYTHON } elseif (Test-Path 'R:\\app\\.venv\\Scripts\\python.exe') { $py = 'R:\\app\\.venv\\Scripts\\python.exe' } else { $py = 'python' }",
        "& $py \"$env:USERPROFILE\\.forge-conductor\\scripts\\grok-build-agent-ctl.py\" attach",
        "```",
        "Expect JSON with `mode=grok` and heartbeat ok.",
        "",
        "## How work arrives",
        "1. In LM Studio, Qwen calls `agent_run_start(agent_id, goal)`.",
        "2. Forge queues a job and returns `session_id` to Qwen.",
        "3. Qwen must **not** freestyle specialist tools (middleware blocks).",
        "4. **You** claim the job, do the work with full visibility in this session, then complete it.",
        "",
        "## Job loop",
        "```powershell",
        "& $py \"$env:USERPROFILE\\.forge-conductor\\scripts\\grok-build-agent-ctl.py\" list",
        "& $py \"$env:USERPROFILE\\.forge-conductor\\scripts\\grok-build-agent-ctl.py\" claim",
        "# Use job.payload: session_id, agent_id, goal, super_context — execute playbook with tools",
        "& $py \"$env:USERPROFILE\\.forge-conductor\\scripts\\grok-build-agent-ctl.py\" complete --session-id <ID> --summary \"...\"",
        "& $py \"$env:USERPROFILE\\.forge-conductor\\scripts\\grok-build-agent-ctl.py\" heartbeat",
        "```",
        "You may also use native Grok Build tools (read/write/shell) with `FORGE_AGENT_EXECUTOR=grok` when calling Forge Python helpers.",
        "",
        "## Agent ids",
        "explore, plan, docs, implement, review, debug, test, security, refactor, release, research, precommit-audit",
        "",
        "## Why this design",
        "- Operator keeps a live conversation with **you** (learn, steer, inspect).",
        "- Qwen remains the LM Studio cockpit (start/poll only when mode=grok).",
        "- Completing jobs unblocks Qwen’s `agent_run_status`.",
        "",
        "## Switch off",
        "Dashboard **HOST** — stop claiming jobs; local model runs agents again.",
        "",
        "## Fail-forward",
        "- No jobs → tell operator you are waiting for `agent_run_start` from LM Studio.",
        "- Stack unloaded → ask for dashboard LOAD.",
        "- Tool failure → retry once, complete with failure summary; do not hang the host forever.",
        "",
        "---",
        "**Ack:** Reply that the Forge Grok Build plugin is active; report Forge home, mode/generation, and queued job count.",
        "",
    ]
    return "\n".join(lines) + "\n"


def write_connect_prompt(home: Path | None = None) -> dict[str, Any]:
    """Write connect prompt to disk for popup + Grok Build to re-read."""
    h = home or _home()
    text = build_grok_build_connect_prompt(h)
    disk = Path.home() / ".forge-conductor"
    out_dirs = [
        disk / "lmstudio",
        h / "lmstudio",
    ]
    paths: list[str] = []
    for d in out_dirs:
        try:
            d.mkdir(parents=True, exist_ok=True)
            p = d / "grok-build-connect-prompt.md"
            p.write_text(text, encoding="utf-8")
            paths.append(str(p))
        except OSError:
            continue
    st = load_state(h)
    st["connect_prompt_path"] = paths[0] if paths else None
    save_state(st, home=h, bump=False)
    return {"ok": bool(paths), "paths": paths, "prompt": text, "generation": st.get("generation")}


def run_lmstudio_notify(home: Path | None = None) -> dict[str, Any]:
    """Run notify script; best-effort."""
    h = home or _home()
    # Prefer disk home scripts (stable) then live home
    candidates = [
        Path.home() / ".forge-conductor" / "scripts" / "notify-lmstudio-agent-backend.ps1",
        h / "scripts" / "notify-lmstudio-agent-backend.ps1",
    ]
    script = next((p for p in candidates if p.is_file()), None)
    if script is None:
        # Inline minimal notify: write notify json + prompt files if present
        return _inline_notify(h)
    try:
        r = subprocess.run(
            [
                "pwsh",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(script),
                "-ForgeHome",
                str(h),
            ],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        return {
            "ok": r.returncode == 0,
            "exit_code": r.returncode,
            "stdout_tail": (r.stdout or "")[-1500:],
            "stderr_tail": (r.stderr or "")[-800:],
            "script": str(script),
        }
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": str(exc), "script": str(script)}


def _inline_notify(home: Path) -> dict[str, Any]:
    st = load_state(home)
    mode = get_mode(home)
    banner = policy_banner(home)
    # write sidecar for LM Studio
    try:
        lm_internal = Path.home() / ".lmstudio" / ".internal"
        lm_internal.mkdir(parents=True, exist_ok=True)
        payload = {
            "mode": mode,
            "generation": st.get("generation"),
            "ts": _utc(),
            "policy": banner,
            "source": "forge-conductor-inline-notify",
        }
        (lm_internal / "forge-agent-backend-notify.json").write_text(
            json.dumps(payload, indent=2) + "\n", encoding="utf-8"
        )
        # mode text for scripts
        mode_dir = Path.home() / ".forge-conductor" / "lmstudio"
        mode_dir.mkdir(parents=True, exist_ok=True)
        (mode_dir / "agent-backend-mode.txt").write_text(mode + "\n", encoding="utf-8")
        (mode_dir / "generation.txt").write_text(str(st.get("generation") or 0) + "\n", encoding="utf-8")
        # swap system prompt from templates if available
        assets = Path.home() / ".forge-conductor" / "scripts" / "assets"
        host_p = assets / "forge-system-prompt.host.txt"
        grok_p = assets / "forge-system-prompt.grok.txt"
        out_p = assets / "forge-system-prompt.txt"
        src = grok_p if mode == "grok" and grok_p.is_file() else host_p
        if src.is_file():
            text = src.read_text(encoding="utf-8")
            text = text.replace("{generation}", str(st.get("generation") or 0))
            out_p.write_text(text, encoding="utf-8")
        return {"ok": True, "inline": True, "mode": mode}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": str(exc), "inline": True}


def status_payload(home: Path | None = None) -> dict[str, Any]:
    h = home or _home()
    st = load_state(h)
    mode = get_mode(h)
    connect_text = None
    connect_path = st.get("connect_prompt_path")
    if mode == "grok":
        # Always refresh prompt text for popup (cheap)
        try:
            connect_text = build_grok_build_connect_prompt(h)
        except Exception:
            connect_text = None
        if connect_path and Path(str(connect_path)).is_file():
            try:
                connect_text = Path(str(connect_path)).read_text(encoding="utf-8")
            except OSError:
                pass
    return {
        "ok": True,
        "mode": mode,
        "generation": st.get("generation"),
        "executor": "grok_build" if mode == "grok" else "host",
        "policy": policy_banner(h),
        "grok": {
            k: v
            for k, v in (st.get("grok") or {}).items()
            if k != "api_key"  # never expose
        },
        "policy_flags": st.get("policy"),
        "last_changed_at": st.get("last_changed_at"),
        "last_changed_by": st.get("last_changed_by"),
        "notify": st.get("notify"),
        "worker": worker_ping(h),
        "state_path": str(state_path(h)),
        "connect_prompt_path": connect_path,
        "connect_prompt": connect_text,
        "connect_prompt_available": bool(connect_text) and mode == "grok",
    }
