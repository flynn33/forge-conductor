"""Headless Grok worker: claim agent jobs and run tool loops via xAI API.

Run:
  FORGE_CONDUCTOR_HOME=... FORGE_AGENT_EXECUTOR=grok python -m forge_conductor.agent_worker

Environment:
  XAI_API_KEY (or secrets.env)
"""

from __future__ import annotations

import json
import os
import sys
import time
import traceback
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable


def _home() -> Path:
    return Path(os.environ.get("FORGE_CONDUCTOR_HOME", Path.home() / ".forge-conductor"))


def _log(msg: str) -> None:
    line = f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}  {msg}"
    try:
        log_dir = _home() / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        with (log_dir / "grok-worker.log").open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass
    try:
        sys.stderr.write(line + "\n")
        sys.stderr.flush()
    except OSError:
        pass


def _heartbeat() -> None:
    try:
        p = _home() / "logs" / "grok-worker.heartbeat"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(str(time.time()), encoding="utf-8")
    except OSError:
        pass


def _load_api_key(env_name: str) -> str | None:
    v = os.environ.get(env_name)
    if v:
        return v.strip()
    secrets = _home() / "secrets.env"
    if secrets.is_file():
        for line in secrets.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith(f"{env_name}="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    return None


def _chat_completions(
    *,
    api_base: str,
    api_key: str,
    model: str,
    messages: list[dict[str, Any]],
    tools: list[dict[str, Any]] | None,
    timeout: int,
) -> dict[str, Any]:
    url = api_base.rstrip("/") + "/chat/completions"
    body: dict[str, Any] = {
        "model": model,
        "messages": messages,
        "temperature": 0.2,
    }
    if tools:
        body["tools"] = tools
        body["tool_choice"] = "auto"
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _tool_schemas_minimal() -> list[dict[str, Any]]:
    """Minimal OpenAI tool schemas for common Forge tools used by agents."""
    # Keep small to reduce prompt size; worker can also call tools by name via local registry
    names = [
        ("fs_read", "Read a file", {"path": "string"}),
        ("fs_write", "Write a file", {"path": "string", "content": "string"}),
        ("fs_glob", "Glob files", {"pattern": "string"}),
        ("shell_exec", "Run shell command", {"command": "string"}),
        ("git_status", "Git status", {}),
        ("git_diff", "Git diff", {}),
        ("search_files", "Search files", {"query": "string"}),
        ("memory_search", "Search memory", {"query": "string"}),
        ("memory_set", "Set memory note", {"key": "string", "body": "string"}),
        ("handoff_save", "Save handoff", {"summary": "string"}),
    ]
    tools = []
    for name, desc, props in names:
        properties = {
            k: {"type": v} for k, v in props.items()
        }
        tools.append(
            {
                "type": "function",
                "function": {
                    "name": name,
                    "description": desc,
                    "parameters": {
                        "type": "object",
                        "properties": properties,
                        "additionalProperties": True,
                    },
                },
            }
        )
    return tools


def _invoke_local_tool(name: str, arguments: dict[str, Any]) -> Any:
    """Best-effort local tool invocation via pack functions."""
    os.environ["FORGE_AGENT_EXECUTOR"] = "grok"
    try:
        if name == "fs_read":
            from forge_conductor.tools import filesystem as fs

            return fs.svc_read(arguments.get("path") or arguments.get("file") or "")
        if name == "fs_write":
            from forge_conductor.tools import filesystem as fs

            return fs.svc_write(
                arguments.get("path") or "",
                arguments.get("content") or arguments.get("text") or "",
            )
        if name in ("fs_glob", "fs_list"):
            from forge_conductor.tools import filesystem as fs

            if hasattr(fs, "svc_glob"):
                return fs.svc_glob(arguments.get("pattern") or "**/*")
            return {"ok": False, "error": "fs_glob unavailable"}
        if name in ("shell_exec", "shell_run"):
            from forge_conductor.tools import shell as sh

            return sh.svc_exec(arguments.get("command") or arguments.get("cmd") or "")
        if name == "git_status":
            from forge_conductor.tools import git as g

            return g.svc_status(arguments.get("path") or arguments.get("cwd"))
        if name == "git_diff":
            from forge_conductor.tools import git as g

            return g.svc_diff(cwd=arguments.get("path") or arguments.get("cwd"))
        if name == "memory_search":
            from forge_conductor.tools import memory as m
            from forge_conductor.server import get_ctx

            ctx = get_ctx()
            if ctx is None:
                return {"ok": False, "error": "no ctx"}
            return m.svc_search(ctx.conn, arguments.get("query") or "")
        if name == "memory_set":
            from forge_conductor.tools import memory as m
            from forge_conductor.server import get_ctx

            ctx = get_ctx()
            if ctx is None:
                return {"ok": False, "error": "no ctx"}
            return m.svc_set(
                ctx.conn,
                key=arguments.get("key") or "",
                body=arguments.get("body") or "",
            )
        if name == "handoff_save":
            from forge_conductor.tools import memory as m
            from forge_conductor.server import get_ctx

            ctx = get_ctx()
            if ctx is None:
                return {"ok": False, "error": "no ctx"}
            return m.svc_handoff_save(
                ctx.conn,
                summary=arguments.get("summary") or arguments.get("body") or "worker handoff",
                next_steps=arguments.get("next_steps") or "continue",
            )
        if name == "search_files":
            from forge_conductor.tools import search as s

            if hasattr(s, "svc_files"):
                return s.svc_files(arguments.get("query") or "")
            return {"ok": False, "error": "search_files unavailable"}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": str(exc), "tool": name, "trace": traceback.format_exc()[-500:]}
    return {"ok": False, "error": f"worker does not implement tool {name}", "hint": "extend agent_worker._invoke_local_tool"}


def run_job(conn: Any, job: dict[str, Any], *, home: Path) -> dict[str, Any]:
    from forge_conductor.agent_backend import load_state
    from forge_conductor.agent_jobs import complete_job
    from forge_conductor.agent_runtime import run_complete
    from forge_conductor.agents_loader import load_agents

    payload = job.get("payload") or {}
    session_id = payload.get("session_id")
    agent_id = payload.get("agent_id")
    goal = payload.get("goal") or ""
    st = load_state(home)
    grok = st.get("grok") or {}
    key_env = str(grok.get("api_key_env") or "XAI_API_KEY")
    api_key = _load_api_key(key_env)
    if not api_key:
        result = {
            "ok": False,
            "error": f"missing API key env {key_env}",
            "hint": f"Set {key_env} or {home}/secrets.env",
        }
        complete_job(conn, job["id"], status="failed", result=result)
        if session_id:
            try:
                from forge_conductor import store

                store.agent_session_end(
                    conn, session_id=session_id, summary=f"grok worker failed: missing {key_env}"
                )
            except Exception:
                pass
        return result

    agents = load_agents(home)
    spec = agents.get(agent_id)
    playbook = spec.to_dict(include_body=True) if spec else {}
    super_context = payload.get("super_context")

    system = (
        f"You are Forge SUPER agent '{agent_id}'. Execute the goal using tools. "
        f"Follow playbook. Return a final JSON report when done.\n"
        f"GOAL: {goal}\n"
        f"PLAYBOOK:\n{json.dumps(playbook, default=str)[:12000]}\n"
        f"SUPER_CONTEXT:\n{json.dumps(super_context, default=str)[:8000]}\n"
    )
    messages: list[dict[str, Any]] = [
        {"role": "system", "content": system},
        {"role": "user", "content": f"Execute agent_id={agent_id}. Goal: {goal}"},
    ]
    tools = _tool_schemas_minimal()
    max_rounds = int(grok.get("max_tool_rounds") or 40)
    timeout = int(grok.get("timeout_sec") or 600)
    api_base = str(grok.get("api_base") or "https://api.x.ai/v1")
    model = str(grok.get("model") or "grok-3")

    final_text = ""
    try:
        for _round in range(max_rounds):
            _heartbeat()
            resp = _chat_completions(
                api_base=api_base,
                api_key=api_key,
                model=model,
                messages=messages,
                tools=tools,
                timeout=min(timeout, 180),
            )
            choice = (resp.get("choices") or [{}])[0]
            msg = choice.get("message") or {}
            tool_calls = msg.get("tool_calls") or []
            content = msg.get("content") or ""
            if content:
                final_text = content
            messages.append(msg)
            if not tool_calls:
                break
            for tc in tool_calls:
                fn = tc.get("function") or {}
                tname = fn.get("name") or "unknown"
                raw_args = fn.get("arguments") or "{}"
                try:
                    args = json.loads(raw_args) if isinstance(raw_args, str) else (raw_args or {})
                except json.JSONDecodeError:
                    args = {"raw": raw_args}
                _log(f"tool_call {tname}")
                tool_result = _invoke_local_tool(tname, args if isinstance(args, dict) else {})
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": tc.get("id") or tname,
                        "content": json.dumps(tool_result, default=str)[:50000],
                    }
                )
        report = {
            "summary": final_text[:8000] if final_text else "Agent finished (no text).",
            "agent_id": agent_id,
            "goal": goal,
            "executor": "grok",
            "raw_tail": final_text[-2000:] if final_text else "",
        }
        if session_id:
            try:
                run_complete(
                    conn,
                    session_id=session_id,
                    report=report,
                    client_id=None,
                )
            except Exception as exc:  # noqa: BLE001
                _log(f"run_complete err: {exc}")
                try:
                    from forge_conductor import store

                    store.agent_session_end(
                        conn,
                        session_id=session_id,
                        summary=report.get("summary"),
                    )
                except Exception:
                    pass
        result = {"ok": True, "report": report}
        complete_job(conn, job["id"], status="completed", result=result)
        _log(f"job {job['id']} completed session={session_id}")
        return result
    except Exception as exc:  # noqa: BLE001
        _log(f"job fail: {exc}\n{traceback.format_exc()}")
        result = {"ok": False, "error": str(exc)}
        complete_job(conn, job["id"], status="failed", result=result)
        if session_id:
            try:
                from forge_conductor import store

                store.agent_session_end(
                    conn, session_id=session_id, summary=f"grok failed: {exc}"
                )
            except Exception:
                pass
        return result


def worker_loop(*, poll_sec: float = 2.0) -> None:
    os.environ["FORGE_AGENT_EXECUTOR"] = "grok"
    from forge_conductor.config import ensure_home, load_config
    from forge_conductor.store import connect, migrate
    from forge_conductor.memory_ram import ensure_bank
    from forge_conductor.ram_orchestration import ensure_orchestration
    from forge_conductor.server import RuntimeContext
    import forge_conductor.server as server_mod
    import uuid

    home = ensure_home()
    conn = connect()
    migrate(conn)
    ensure_bank(conn, home)
    ensure_orchestration(conn, home)
    config = load_config()
    server_mod._ctx = RuntimeContext(
        conn=conn,
        client_id=f"grok-worker-{uuid.uuid4().hex[:8]}",
        config=config,
        home=home,
        coordinator=None,
    )
    _log(f"worker start home={home}")
    from forge_conductor.agent_jobs import claim_next_job

    while True:
        try:
            _heartbeat()
            job = claim_next_job(conn)
            if job:
                _log(f"claimed job {job.get('id')}")
                run_job(conn, job, home=home)
            else:
                time.sleep(poll_sec)
        except KeyboardInterrupt:
            _log("worker stop")
            break
        except Exception as exc:  # noqa: BLE001
            _log(f"loop error: {exc}")
            time.sleep(poll_sec)


def main() -> None:
    worker_loop()


if __name__ == "__main__":
    main()
