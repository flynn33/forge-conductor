"""Global tool + agent resilience: soft errors, one retry, diagnostics, circuit.

Installed as FastMCP middleware so every tools/call is hardened without
editing each pack. Failures never raise into the host session.
"""

from __future__ import annotations

import json
import os
import time
import traceback
from collections import defaultdict
from pathlib import Path
from typing import Any

from forge_conductor.errors import ToolError, tool_error_payload
from forge_conductor.fail_forward import attach_fail_forward


def _home() -> Path:
    return Path(os.environ.get("FORGE_CONDUCTOR_HOME", Path.home() / ".forge-conductor"))


def _role() -> str:
    return os.environ.get("FORGE_MCP_ROLE", "primary")


def diag(event: str, **fields: Any) -> None:
    """Append structured tool/agent diagnostic line."""
    rec: dict[str, Any] = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "event": event,
        "role": _role(),
        "pid": os.getpid(),
        **fields,
    }
    try:
        log_dir = _home() / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        with (log_dir / "tool-diagnostics.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, default=str) + "\n")
        # Also mirror critical events into failover diagnostics
        if event.startswith("tool_circuit") or event.startswith("tool_crash") or event.startswith(
            "agent_"
        ):
            with (log_dir / "failover-diagnostics.jsonl").open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(rec, default=str) + "\n")
    except OSError:
        pass


class ToolCircuit:
    """Per-tool consecutive-failure circuit (auto-reset after cooldown)."""

    def __init__(
        self,
        *,
        fail_threshold: int = 8,
        cooldown_sec: float = 30.0,
    ) -> None:
        self.fail_threshold = fail_threshold
        self.cooldown_sec = cooldown_sec
        self._fails: dict[str, int] = defaultdict(int)
        self._open_until: dict[str, float] = {}

    def allow(self, tool: str) -> bool:
        until = self._open_until.get(tool, 0.0)
        if until and time.time() < until:
            return False
        if until and time.time() >= until:
            self._open_until.pop(tool, None)
            self._fails[tool] = 0
            diag("tool_circuit_reset", tool=tool)
        return True

    def record_success(self, tool: str) -> None:
        self._fails[tool] = 0
        self._open_until.pop(tool, None)

    def record_failure(self, tool: str) -> bool:
        """Return True if circuit just opened."""
        self._fails[tool] = self._fails.get(tool, 0) + 1
        if self._fails[tool] >= self.fail_threshold:
            self._open_until[tool] = time.time() + self.cooldown_sec
            diag(
                "tool_circuit_open",
                tool=tool,
                fails=self._fails[tool],
                cooldown_sec=self.cooldown_sec,
            )
            return True
        return False


_CIRCUIT = ToolCircuit()


def _is_retryable(exc: BaseException) -> bool:
    if isinstance(exc, ToolError):
        return bool(exc.retryable)
    # Transient OS / DB / subprocess classes
    retry_types = (TimeoutError, ConnectionError, BrokenPipeError, OSError)
    if isinstance(exc, retry_types):
        # PermissionError / FileNotFoundError are OSError subclasses — don't retry those
        if isinstance(exc, (PermissionError, FileNotFoundError, NotADirectoryError)):
            return False
        return True
    name = type(exc).__name__.lower()
    msg = str(exc).lower()
    if "timeout" in name or "timeout" in msg or "locked" in msg or "busy" in msg:
        return True
    if "database is locked" in msg:
        return True
    return False


def _soft_result(payload: dict[str, Any]):
    """Build FastMCP ToolResult that does not tear down the session."""
    from fastmcp.tools.base import ToolResult

    # is_error=True maps to CallToolResult.isError — client sees tool error, connection stays up
    return ToolResult(
        structured_content=payload,
        is_error=True,
        meta={"forge_soft_error": True, "forge_role": _role()},
    )


def _circuit_open_payload(tool: str) -> dict[str, Any]:
    return {
        "ok": False,
        "code": "tool_circuit_open",
        "message": (
            f"Tool '{tool}' temporarily paused after repeated failures; "
            f"auto-resets shortly. Try a different tool or wait ~30s."
        ),
        "retryable": True,
        "detail": {"tool": tool, "cooldown_sec": _CIRCUIT.cooldown_sec},
        "forge_recovery": True,
    }


def install_tool_resilience(mcp: Any) -> None:
    """Attach ForgeToolResilienceMiddleware to a FastMCP app."""
    from fastmcp.server.middleware import Middleware

    class ForgeToolResilienceMiddleware(Middleware):
        async def on_call_tool(self, context, call_next):  # type: ignore[no-untyped-def]
            # context.message is CallToolRequestParams-like
            msg = getattr(context, "message", None)
            tool = None
            if msg is not None:
                tool = getattr(msg, "name", None) or getattr(msg, "tool", None)
            if not tool and isinstance(msg, dict):
                tool = msg.get("name")
            tool = str(tool or "unknown")

            if not _CIRCUIT.allow(tool):
                diag("tool_circuit_reject", tool=tool)
                return _soft_result(_circuit_open_payload(tool))

            # Grok mode: block host specialist mutations (mandatory offload)
            try:
                from forge_conductor.agent_backend import host_tool_allowed

                allowed, block_msg = host_tool_allowed(tool)
                if not allowed:
                    diag("agent_backend_host_block", tool=tool)
                    return _soft_result(
                        attach_fail_forward(
                            {
                                "ok": False,
                                "code": "agent_backend_host_blocked",
                                "message": block_msg
                                or "Host blocked in grok mode; use agent_run_start.",
                                "retryable": True,
                                "agent_backend": True,
                                "hint": (
                                    "Call agent_backend_status, then agent_run_start(agent_id, goal) "
                                    "and poll agent_run_status."
                                ),
                            },
                            last_tool=tool,
                            error_text=block_msg or "host blocked",
                        )
                    )
            except Exception:
                pass

            # Soft tool preference while a sub-agent run is active
            client_id = None
            try:
                from forge_conductor.server import get_ctx

                ctx = get_ctx()
                client_id = ctx.client_id if ctx else None
            except Exception:
                client_id = None

            pref = None
            try:
                from forge_conductor.agent_runtime import (
                    annotate_result_with_preference,
                    get_active,
                    soft_tool_preference,
                )

                pref = soft_tool_preference(tool, client_id)
                active = get_active(client_id)
                if pref and pref.get("severity") == "warn":
                    diag(
                        "agent_tool_preference_warn",
                        tool=tool,
                        agent_id=pref.get("agent_id"),
                        session_id=pref.get("session_id"),
                    )
                elif active:
                    diag(
                        "tool_call_under_agent",
                        tool=tool,
                        agent_id=active.agent_id,
                        agent_session_id=active.session_id,
                    )
            except Exception:
                annotate_result_with_preference = None  # type: ignore[assignment]

            last_exc: BaseException | None = None
            for attempt in (1, 2):
                try:
                    result = await call_next(context)
                    # Detect structured soft failures returned as normal results
                    if _result_looks_failed(result):
                        _CIRCUIT.record_failure(tool)
                        if attempt == 1 and _result_retryable(result):
                            diag(
                                "tool_soft_retry",
                                tool=tool,
                                attempt=attempt,
                            )
                            time.sleep(0.05)
                            continue
                        diag(
                            "tool_soft_fail",
                            tool=tool,
                            attempt=attempt,
                            summary=_result_summary(result),
                        )
                        # Annotate structured soft failures with fail-forward hints
                        try:
                            sc = getattr(result, "structured_content", None)
                            if isinstance(sc, dict) and "fail_forward" not in sc:
                                sc2 = attach_fail_forward(
                                    sc, last_tool=tool, error_text=str(sc.get("message") or sc.get("code") or "")
                                )
                                from fastmcp.tools.base import ToolResult

                                result = ToolResult(
                                    content=getattr(result, "content", None),
                                    structured_content=sc2,
                                    meta=getattr(result, "meta", None),
                                    is_error=getattr(result, "is_error", True),
                                )
                        except Exception:
                            pass
                    else:
                        _CIRCUIT.record_success(tool)
                    if pref and annotate_result_with_preference:
                        result = annotate_result_with_preference(result, pref)
                    # Auto continuity: inject project/handoff/bootstrap without model effort
                    try:
                        from forge_conductor.continuity_auto import process_tool_result

                        args = None
                        if msg is not None:
                            args = getattr(msg, "arguments", None)
                            if args is None and isinstance(msg, dict):
                                args = msg.get("arguments")
                        result = process_tool_result(tool, args, result)
                    except Exception:
                        pass
                    return result
                except BaseException as exc:  # noqa: BLE001 — MCP boundary
                    last_exc = exc
                    # Never swallow CancelledError / KeyboardInterrupt for process control
                    if isinstance(exc, (KeyboardInterrupt, SystemExit)):
                        raise
                    retry = _is_retryable(exc) and attempt == 1
                    diag(
                        "tool_exception",
                        tool=tool,
                        attempt=attempt,
                        retry=retry,
                        error=str(exc),
                        error_type=type(exc).__name__,
                        traceback=traceback.format_exc()[-1200:],
                    )
                    if retry:
                        time.sleep(0.08)
                        continue
                    _CIRCUIT.record_failure(tool)
                    payload = tool_error_payload(
                        exc if isinstance(exc, Exception) else Exception(str(exc))
                    )
                    payload["ok"] = False
                    payload["forge_recovery"] = True
                    payload["detail"] = {
                        **(payload.get("detail") or {}),
                        "tool": tool,
                        "attempt": attempt,
                    }
                    if pref:
                        payload["agent_tool_preference"] = pref
                    payload = attach_fail_forward(
                        payload, last_tool=tool, error_text=str(exc)
                    )
                    diag(
                        "tool_crash_softened",
                        tool=tool,
                        code=payload.get("code"),
                        error_class=(payload.get("fail_forward") or {}).get("error_class"),
                    )
                    return _soft_result(payload)

            # Should not reach; soften last
            payload = tool_error_payload(
                last_exc if isinstance(last_exc, Exception) else Exception("unknown")
            )
            payload["ok"] = False
            payload = attach_fail_forward(
                payload, last_tool=tool, error_text=str(last_exc)
            )
            return _soft_result(payload)

    mcp.add_middleware(ForgeToolResilienceMiddleware())
    diag("tool_resilience_installed", tools="all")


def _result_looks_failed(result: Any) -> bool:
    if result is None:
        return False
    if getattr(result, "is_error", False):
        return True
    sc = getattr(result, "structured_content", None)
    if isinstance(sc, dict):
        if sc.get("ok") is False:
            return True
        if sc.get("code") and sc.get("code") not in ("ok",):
            # tool_error_payload shape
            if "message" in sc and sc.get("retryable") is not None:
                return True
    return False


def _result_retryable(result: Any) -> bool:
    sc = getattr(result, "structured_content", None)
    if isinstance(sc, dict):
        return bool(sc.get("retryable"))
    return False


def _result_summary(result: Any) -> str:
    sc = getattr(result, "structured_content", None)
    if isinstance(sc, dict):
        return str(sc.get("code") or sc.get("message") or "")[:200]
    return type(result).__name__


# --- Agent session recovery helpers ---


def prune_stale_agent_sessions(
    conn: Any,
    *,
    max_age_sec: int = 86_400,
    status: str = "open",
) -> list[dict[str, Any]]:
    """Close open agent sessions older than max_age_sec. Returns closed rows."""
    from forge_conductor import store

    closed: list[dict[str, Any]] = []
    now = time.time()
    try:
        sessions = store.agent_session_list(conn, status=status)
    except Exception as exc:  # noqa: BLE001
        diag("agent_list_failed", error=str(exc))
        return []

    for s in sessions:
        updated = s.get("updated_at") or s.get("created_at")
        age = None
        if isinstance(updated, str) and "T" in updated:
            try:
                from datetime import datetime

                t = datetime.fromisoformat(updated.replace("Z", "+00:00")).timestamp()
                age = now - t
            except ValueError:
                age = None
        if age is not None and age > max_age_sec:
            try:
                row = store.agent_session_end(
                    conn,
                    session_id=s["id"],
                    summary=f"auto-closed by resilience (stale {int(age)}s)",
                )
                closed.append(row)
                diag(
                    "agent_session_auto_closed",
                    session_id=s["id"],
                    agent_id=s.get("agent_id"),
                    age_sec=int(age),
                )
            except Exception as exc:  # noqa: BLE001
                diag(
                    "agent_session_auto_close_failed",
                    session_id=s.get("id"),
                    error=str(exc),
                )
    return closed


def recover_agent_session(
    conn: Any,
    *,
    session_id: str | None = None,
    agent_id: str | None = None,
    client_id: str | None = None,
    home: Any = None,
) -> dict[str, Any]:
    """Re-open or create a healthy agent session after failure.

    If session_id exists and is open → return it.
    If closed/missing and agent_id given → start a new session.
    """
    from forge_conductor import store
    from forge_conductor.tools import agents as agents_mod

    if session_id:
        existing = store.agent_session_get(conn, session_id)
        if existing and existing.get("status") in ("open", "active", "running"):
            diag("agent_session_reuse", session_id=session_id)
            return {
                "ok": True,
                "recovered": False,
                "reused": True,
                "session": existing,
            }
        if existing and agent_id is None:
            agent_id = existing.get("agent_id")

    if not agent_id:
        return {
            "ok": False,
            "code": "missing_agent_id",
            "message": "Provide agent_id to recover/start a session.",
            "retryable": True,
        }

    # Validate agent still loads (reload catalog)
    try:
        agents_mod._require_spec(home, agent_id)
    except ToolError as exc:
        # Retry once after catalog touch
        try:
            from forge_conductor.agents_loader import load_agents
            from forge_conductor.config import get_home

            load_agents(home or get_home())
            agents_mod._require_spec(home, agent_id)
        except ToolError as exc2:
            diag("agent_recover_unknown", agent_id=agent_id, error=str(exc2))
            return tool_error_payload(exc2) | {"ok": False, "forge_recovery": True}

    # DB lock retry
    last: Exception | None = None
    for attempt in (1, 2, 3):
        try:
            row = store.agent_session_start(
                conn, agent_id=agent_id, client_id=client_id
            )
            diag(
                "agent_session_recovered",
                session_id=row["id"],
                agent_id=agent_id,
                attempt=attempt,
            )
            ctx = agents_mod.svc_context(home, agent_id)
            return {
                "ok": True,
                "recovered": True,
                "reused": False,
                "session": row,
                "agent": ctx,
                "next": "Apply agent.body as role instructions, then use Forge tools.",
            }
        except Exception as exc:  # noqa: BLE001
            last = exc
            if _is_retryable(exc) and attempt < 3:
                time.sleep(0.1 * attempt)
                continue
            break
    payload = tool_error_payload(last or Exception("recover failed"))
    payload["ok"] = False
    payload["forge_recovery"] = True
    diag("agent_recover_failed", agent_id=agent_id, error=str(last))
    return payload
