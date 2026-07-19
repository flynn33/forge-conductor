"""Automatic MCP fail-over supervisor.

The host (LM Studio) keeps a single stdio connection to this process. We spawn
``forge-conductor serve`` as a child and proxy JSON-RPC. When the child dies:

1. Log failure to diagnostic + supervisor logs
2. Start the next launch candidate
3. Replay stored ``initialize`` + ``notifications/initialized`` to the new child
4. Keep proxying — host does not need to reconnect

Nested supervise is prevented via FORGE_SUPERVISED=1 on children.
"""

from __future__ import annotations

import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
import traceback
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, TextIO


def _home() -> Path:
    return Path(os.environ.get("FORGE_CONDUCTOR_HOME", Path.home() / ".forge-conductor"))


def _role() -> str:
    return os.environ.get("FORGE_MCP_ROLE", os.environ.get("FORGE_INSTANCE_ROLE", "primary"))


def _log(msg: str) -> None:
    line = f"{time.strftime('%Y-%m-%dT%H:%M:%S')} [{_role()}] {msg}"
    try:
        log_dir = _home() / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        with (log_dir / "supervisor.log").open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass
    try:
        sys.stderr.write(f"forge-supervisor: {msg}\n")
        sys.stderr.flush()
    except OSError:
        pass


def _diag(event: str, **fields: Any) -> None:
    """Append structured diagnostic record (crash / fail-over / circuit)."""
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
        path = log_dir / "failover-diagnostics.jsonl"
        with path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, default=str) + "\n")
    except OSError:
        pass
    # Human-readable mirror
    detail = " ".join(f"{k}={v}" for k, v in fields.items() if v is not None)
    _log(f"DIAG {event} {detail}".strip())


def _tail_file(path: Path, max_bytes: int = 4000) -> str:
    try:
        if not path.is_file():
            return ""
        data = path.read_bytes()
        if len(data) > max_bytes:
            data = data[-max_bytes:]
        return data.decode("utf-8", errors="replace")
    except OSError:
        return ""


def launch_candidates() -> list[list[str]]:
    worktree = Path(__file__).resolve().parents[2]
    venv_exe = worktree / ".venv" / "Scripts" / "forge-conductor.exe"
    venv_py = worktree / ".venv" / "Scripts" / "python.exe"
    out: list[list[str]] = []
    if venv_exe.is_file():
        out.append([str(venv_exe), "serve"])
    if venv_py.is_file():
        out.append([str(venv_py), "-m", "forge_conductor", "serve"])
    which = shutil.which("forge-conductor")
    if which:
        cand = [which, "serve"]
        if cand not in out:
            out.append(cand)
    py = shutil.which("python") or sys.executable
    if py:
        cand = [py, "-m", "forge_conductor", "serve"]
        if cand not in out:
            out.append(cand)
    return out


_SENTINEL = object()


@dataclass
class Supervisor:
    max_restarts: int = 20
    restart_window_sec: float = 120.0
    child_start_timeout_sec: float = 25.0
    circuit_cooldown_sec: float = 15.0

    _host_in: TextIO = field(default_factory=lambda: sys.stdin)
    _host_out: TextIO = field(default_factory=lambda: sys.stdout)
    _write_lock: threading.Lock = field(default_factory=threading.Lock)
    _child: subprocess.Popen[str] | None = None
    _line_q: queue.Queue[Any] = field(default_factory=queue.Queue)
    _reader_gen: int = 0
    _init_params: dict[str, Any] | None = None
    _init_id: int | str | None = None
    _restart_times: list[float] = field(default_factory=list)
    _stop: threading.Event = field(default_factory=threading.Event)
    _cand_index: int = 0
    _pause_forward: threading.Event = field(default_factory=threading.Event)
    _failover_count: int = 0
    # When set, forwarder does not consume queue (re-init owns it)

    def _env(self) -> dict[str, str]:
        env = os.environ.copy()
        env.setdefault(
            "FORGE_CONDUCTOR_HOME",
            str(Path.home() / ".forge-conductor"),
        )
        env["FASTMCP_SHOW_SERVER_BANNER"] = "false"
        env.setdefault("PYTHONUTF8", "1")
        env.setdefault("PYTHONIOENCODING", "utf-8")
        env.setdefault("GIT_TERMINAL_PROMPT", "0")
        env.setdefault("GCM_INTERACTIVE", "never")
        env["FORGE_SUPERVISED"] = "1"
        env.setdefault("FORGE_MCP_ROLE", _role())
        return env

    def _child_stderr_path(self) -> Path:
        return _home() / "logs" / "supervisor-child.stderr.log"

    def _spawn(self, argv: list[str]) -> subprocess.Popen[str]:
        _log(f"spawn {' '.join(argv)}")
        creationflags = 0
        if sys.platform == "win32":
            creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        return subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=self._env(),
            creationflags=creationflags,
        )

    def _drain_queue(self) -> None:
        while True:
            try:
                self._line_q.get_nowait()
            except queue.Empty:
                break

    def _start_reader(self, proc: subprocess.Popen[str]) -> None:
        self._reader_gen += 1
        gen = self._reader_gen
        self._drain_queue()

        def _read() -> None:
            assert proc.stdout is not None
            try:
                for line in proc.stdout:
                    if gen != self._reader_gen:
                        break
                    self._line_q.put(line)
            except OSError:
                pass
            finally:
                if gen == self._reader_gen:
                    self._line_q.put(_SENTINEL)

        def _err() -> None:
            assert proc.stderr is not None
            log = self._child_stderr_path()
            try:
                log.parent.mkdir(parents=True, exist_ok=True)
                with log.open("a", encoding="utf-8") as fh:
                    fh.write(
                        f"\n--- child pid={proc.pid} role={_role()} "
                        f"ts={time.strftime('%Y-%m-%dT%H:%M:%S')} ---\n"
                    )
                    for line in proc.stderr:
                        fh.write(line)
            except OSError:
                pass

        threading.Thread(target=_read, daemon=True).start()
        threading.Thread(target=_err, daemon=True).start()

    def _start_next_child(self) -> bool:
        cands = launch_candidates()
        if not cands:
            _diag("no_launch_candidates")
            return False
        for _ in range(len(cands)):
            argv = cands[self._cand_index % len(cands)]
            self._cand_index += 1
            try:
                proc = self._spawn(argv)
            except OSError as exc:
                _diag("spawn_failed", argv=argv, error=str(exc))
                continue
            time.sleep(0.25)
            if proc.poll() is not None:
                _diag(
                    "child_exit_immediate",
                    argv=argv,
                    exit_code=proc.returncode,
                    stderr_tail=_tail_file(self._child_stderr_path(), 1500)[-800:],
                )
                continue
            self._child = proc
            self._start_reader(proc)
            _diag("child_started", argv=argv, child_pid=proc.pid)
            return True
        return False

    def _kill_child(self) -> None:
        proc = self._child
        self._child = None
        self._reader_gen += 1  # invalidate reader
        if proc is None:
            return
        try:
            try:
                import psutil

                p = psutil.Process(proc.pid)
                for c in p.children(recursive=True):
                    try:
                        c.kill()
                    except psutil.Error:
                        pass
                p.kill()
            except Exception:
                if proc.poll() is None:
                    proc.kill()
        except OSError:
            pass

    def _write_host(self, line: str) -> None:
        with self._write_lock:
            self._host_out.write(line if line.endswith("\n") else line + "\n")
            self._host_out.flush()

    def _get_line(self, timeout: float) -> Any:
        try:
            return self._line_q.get(timeout=timeout)
        except queue.Empty:
            return None

    def _replay_initialize(self) -> bool:
        proc = self._child
        if proc is None or proc.stdin is None:
            return False
        if self._init_params is None:
            return True
        init_id = self._init_id if self._init_id is not None else 1
        msg = {
            "jsonrpc": "2.0",
            "id": init_id,
            "method": "initialize",
            "params": self._init_params,
        }
        self._pause_forward.set()
        self._drain_queue()
        try:
            proc.stdin.write(json.dumps(msg) + "\n")
            proc.stdin.flush()
            deadline = time.time() + self.child_start_timeout_sec
            while time.time() < deadline:
                if proc.poll() is not None:
                    _diag("child_died_during_reinit", exit_code=proc.returncode)
                    return False
                item = self._get_line(0.5)
                if item is None:
                    continue
                if item is _SENTINEL:
                    _diag("stdout_closed_during_reinit")
                    return False
                try:
                    data = json.loads(item)
                except (json.JSONDecodeError, TypeError):
                    continue
                if data.get("id") == init_id:
                    note = {"jsonrpc": "2.0", "method": "notifications/initialized"}
                    proc.stdin.write(json.dumps(note) + "\n")
                    proc.stdin.flush()
                    _log("re-init complete")
                    _diag("reinit_complete", child_pid=proc.pid)
                    return True
            _diag("reinit_timeout")
            return False
        except OSError as exc:
            _diag("reinit_error", error=str(exc))
            return False
        finally:
            self._pause_forward.clear()

    def _circuit_ok(self) -> bool:
        now = time.time()
        self._restart_times = [
            t for t in self._restart_times if now - t < self.restart_window_sec
        ]
        if len(self._restart_times) >= self.max_restarts:
            _diag(
                "circuit_open",
                restarts=len(self._restart_times),
                window_sec=self.restart_window_sec,
                cooldown_sec=self.circuit_cooldown_sec,
            )
            return False
        return True

    def _failover(self, reason: str, exit_code: int | None = None) -> bool:
        self._failover_count += 1
        stderr_tail = _tail_file(self._child_stderr_path(), 3000)[-1200:]
        _diag(
            "failover_begin",
            reason=reason,
            exit_code=exit_code,
            failover_n=self._failover_count,
            stderr_tail=stderr_tail or None,
        )

        # Circuit open → cool down, clear window, keep host connection alive
        if not self._circuit_ok():
            _log(
                f"circuit open — cooling down {self.circuit_cooldown_sec}s then retry"
            )
            time.sleep(self.circuit_cooldown_sec)
            self._restart_times.clear()
            _diag("circuit_reset_after_cooldown")

        self._restart_times.append(time.time())
        _log(f"fail-over: restarting backend ({reason})")
        self._kill_child()
        if not self._start_next_child():
            _diag("failover_failed", reason="no_child_started")
            # brief pause and one more full pass through candidates
            time.sleep(2.0)
            self._cand_index = 0
            if not self._start_next_child():
                _diag("failover_failed", reason="no_child_after_retry")
                return False

        if self._init_params is not None:
            if not self._replay_initialize():
                _diag("failover_reinit_failed_try_next")
                self._kill_child()
                if not self._start_next_child():
                    _diag("failover_failed", reason="no_child_after_reinit_fail")
                    return False
                ok = self._replay_initialize()
                if not ok:
                    _diag("failover_failed", reason="reinit_failed_twice")
                else:
                    _diag("failover_success", after="reinit_retry")
                return ok
        _diag("failover_success", reason=reason)
        return True

    def _forwarder(self) -> None:
        while not self._stop.is_set():
            if self._pause_forward.is_set():
                time.sleep(0.05)
                continue
            item = self._get_line(0.4)
            if item is None:
                proc = self._child
                if proc is not None and proc.poll() is not None:
                    ec = proc.returncode
                    _log(f"child exited ec={ec}")
                    if not self._failover("child_exited", exit_code=ec):
                        # Keep trying: do not drop host session permanently
                        _diag("failover_loop_continue", reason="child_exited")
                        time.sleep(self.circuit_cooldown_sec)
                        self._restart_times.clear()
                        if not self._failover("child_exited_retry", exit_code=ec):
                            self._stop.set()
                            return
                continue
            if item is _SENTINEL:
                proc = self._child
                if proc is not None and proc.poll() is not None:
                    ec = proc.returncode
                    _log(f"child stdout EOF ec={ec}")
                    if not self._failover("stdout_eof", exit_code=ec):
                        _diag("failover_loop_continue", reason="stdout_eof")
                        time.sleep(self.circuit_cooldown_sec)
                        self._restart_times.clear()
                        if not self._failover("stdout_eof_retry", exit_code=ec):
                            self._stop.set()
                            return
                continue
            self._write_host(item)

    def _note_host_message(self, raw: str) -> None:
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            return
        if msg.get("method") == "initialize" and "params" in msg:
            self._init_params = msg["params"]
            self._init_id = msg.get("id")
            _log("stored initialize params for fail-over replay")
            _diag("initialize_stored", init_id=self._init_id)

    def run(self) -> int:
        if os.environ.get("FORGE_SUPERVISED") == "1":
            from forge_conductor.server import run_stdio

            run_stdio()
            return 0

        _diag(
            "supervisor_start",
            candidates=[c[0] for c in launch_candidates()],
        )

        if not self._start_next_child():
            _diag("supervisor_failed", reason="failed_to_start_any_backend")
            return 1

        t = threading.Thread(target=self._forwarder, daemon=True)
        t.start()

        try:
            for raw in self._host_in:
                if self._stop.is_set():
                    break
                self._note_host_message(raw)
                proc = self._child
                if proc is None or proc.stdin is None or proc.poll() is not None:
                    ec = proc.returncode if proc is not None else None
                    _log("no live child; fail-over before write")
                    if not self._failover("no_live_child_before_write", exit_code=ec):
                        break
                    proc = self._child
                if proc is None or proc.stdin is None:
                    break
                try:
                    proc.stdin.write(raw if raw.endswith("\n") else raw + "\n")
                    proc.stdin.flush()
                except OSError as exc:
                    _log(f"write failed; fail-over ({exc})")
                    if not self._failover("write_failed", exit_code=None):
                        break
                    proc = self._child
                    if proc and proc.stdin:
                        try:
                            proc.stdin.write(
                                raw if raw.endswith("\n") else raw + "\n"
                            )
                            proc.stdin.flush()
                        except OSError:
                            break
        except KeyboardInterrupt:
            _diag("supervisor_keyboard_interrupt")
        except Exception as exc:
            _diag(
                "supervisor_exception",
                error=str(exc),
                traceback=traceback.format_exc()[-1500:],
            )
        finally:
            self._stop.set()
            self._kill_child()
            _diag("supervisor_stop", failover_count=self._failover_count)
        return 0


def run_supervisor() -> None:
    code = Supervisor().run()
    if code:
        raise SystemExit(code)
