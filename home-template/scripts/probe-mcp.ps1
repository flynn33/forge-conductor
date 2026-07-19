#Requires -Version 5.1
<#
.SYNOPSIS
  Offline health probe for Forge-Conductor MCP (does not use LM Studio tokens).

.DESCRIPTION
  Spawns the same serve path LM Studio uses, runs initialize + tools/list + forge_status,
  prints latency and PASS/FAIL. Use this when chat "hangs on forge_status" to separate
  MCP failure from model/engine failure.

.EXAMPLE
  pwsh -File $env:USERPROFILE\.forge-conductor\scripts\probe-mcp.ps1
#>
param(
  [int]$TimeoutSec = 20,
  [string]$HomeDir = $(if ($env:FORGE_CONDUCTOR_HOME) { $env:FORGE_CONDUCTOR_HOME } else { Join-Path $env:USERPROFILE ".forge-conductor" }),
  [string]$ServeCmd = $(
    $homeLauncher = Join-Path $env:USERPROFILE ".forge-conductor\bin\forge-serve.cmd"
    if (Test-Path $homeLauncher) { $homeLauncher }
    elseif ($env:FORGE_SERVE_CMD -and (Test-Path $env:FORGE_SERVE_CMD)) { $env:FORGE_SERVE_CMD }
    elseif (Get-Command forge-conductor -ErrorAction SilentlyContinue) { "forge-conductor" }
    else { "" }
  )
)

$ErrorActionPreference = "Stop"
$results = [ordered]@{
  timestamp = (Get-Date).ToString("o")
  home = $HomeDir
  serve_cmd = $ServeCmd
  pass = $false
}

function Fail([string]$msg) {
  $results.pass = $false
  $results.error = $msg
  $results | ConvertTo-Json -Depth 6
  Write-Host "FAIL: $msg" -ForegroundColor Red
  exit 1
}

if (-not (Test-Path $ServeCmd)) {
  Fail "Serve script missing: $ServeCmd"
}

$pyProbe = @'
import json, os, queue, subprocess, sys, threading, time

home = os.environ["FORGE_CONDUCTOR_HOME"]
serve = os.environ["FORGE_SERVE_CMD"]
timeout = float(os.environ.get("FORGE_PROBE_TIMEOUT", "20"))

env = os.environ.copy()
env["FORGE_CONDUCTOR_HOME"] = home
env["FASTMCP_SHOW_SERVER_BANNER"] = "false"
env["GH_PROMPT_DISABLED"] = "1"
env["GIT_TERMINAL_PROMPT"] = "0"
env["GCM_INTERACTIVE"] = "never"

# Prefer cmd wrapper (matches LM Studio). On Windows this is .cmd
if serve.lower().endswith(".cmd"):
    cmd = ["cmd.exe", "/d", "/s", "/c", serve]
else:
    cmd = [serve, "serve"] if not serve.endswith("serve") else [serve]

t0 = time.perf_counter()
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
err_q: queue.Queue[str] = queue.Queue()

def _stdout():
    assert p.stdout is not None
    for line in p.stdout:
        q.put(line)

def _stderr():
    assert p.stderr is not None
    for line in p.stderr:
        err_q.put(line)

threading.Thread(target=_stdout, daemon=True).start()
threading.Thread(target=_stderr, daemon=True).start()

def rpc(obj, wait=True):
    assert p.stdin is not None
    p.stdin.write(json.dumps(obj) + "\n")
    p.stdin.flush()
    if not wait or "id" not in obj:
        return None
    want = obj["id"]
    end = time.time() + timeout
    while time.time() < end:
        try:
            line = q.get(timeout=0.2)
        except queue.Empty:
            if p.poll() is not None:
                errs = []
                while not err_q.empty():
                    errs.append(err_q.get_nowait())
                raise RuntimeError(f"server exited {p.returncode}: {''.join(errs)[:800]}")
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        if msg.get("id") == want:
            if "error" in msg:
                raise RuntimeError(json.dumps(msg["error"])[:500])
            return msg
    raise TimeoutError(f"timeout waiting for id={want}")

out = {}
try:
    t_init0 = time.perf_counter()
    init = rpc({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "forge-probe", "version": "1.0"},
        },
    })
    out["spawn_to_init_ms"] = round((time.perf_counter() - t_init0) * 1000, 1)
    out["server"] = (init or {}).get("result", {}).get("serverInfo")

    rpc({"jsonrpc": "2.0", "method": "notifications/initialized"}, wait=False)

    t_list0 = time.perf_counter()
    tools = rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    out["tools_list_ms"] = round((time.perf_counter() - t_list0) * 1000, 1)
    tool_list = (tools or {}).get("result", {}).get("tools") or []
    out["tool_count"] = len(tool_list)
    out["tools_list_kb"] = round(len(json.dumps(tool_list)) / 1024, 1)
    names = {t.get("name") for t in tool_list}
    for required in ("forge_status", "session_bootstrap", "agent_list", "agent_context"):
        if required not in names:
            raise RuntimeError(f"missing tool: {required}")

    t_st0 = time.perf_counter()
    status = rpc({
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {"name": "forge_status", "arguments": {}},
    })
    out["forge_status_ms"] = round((time.perf_counter() - t_st0) * 1000, 1)
    content = ((status or {}).get("result") or {}).get("content") or []
    text = content[0].get("text") if content else ""
    body = json.loads(text) if text.startswith("{") else {"raw": text}
    out["forge_status"] = {
        "version": body.get("version"),
        "tool_count": body.get("tool_count"),
        "schema_ready": body.get("schema_ready"),
        "home": body.get("home"),
    }
    if not body.get("schema_ready"):
        raise RuntimeError("forge_status.schema_ready is false")
    if int(body.get("tool_count") or 0) < 1:
        raise RuntimeError("forge_status tool_count < 1")

    out["total_ms"] = round((time.perf_counter() - t0) * 1000, 1)
    out["pass"] = True
    print(json.dumps(out, indent=2))
    sys.exit(0)
except Exception as e:
    errs = []
    while not err_q.empty():
        errs.append(err_q.get_nowait())
    out["pass"] = False
    out["error"] = str(e)
    out["stderr_tail"] = "".join(errs)[-1200:]
    out["total_ms"] = round((time.perf_counter() - t0) * 1000, 1)
    print(json.dumps(out, indent=2))
    sys.exit(1)
finally:
    try:
        p.kill()
    except Exception:
        pass
'@

$env:FORGE_CONDUCTOR_HOME = $HomeDir
$env:FORGE_SERVE_CMD = $ServeCmd
$env:FORGE_PROBE_TIMEOUT = "$TimeoutSec"

$venvPy = $null
foreach ($cand in @(
  $env:FORGE_PYTHON,
  "R:\app\.venv\Scripts\python.exe",
  (Join-Path $env:USERPROFILE ".forge-conductor\.venv\Scripts\python.exe")
)) {
  if ($cand -and (Test-Path $cand)) { $venvPy = $cand; break }
}
if (-not $venvPy) {
  $cmd = Get-Command python -ErrorAction SilentlyContinue
  if ($cmd) { $venvPy = $cmd.Source }
}
if (-not $venvPy) {
  Fail "python not found — set FORGE_PYTHON or install forge-conductor into a venv"
}
if (-not $ServeCmd) {
  Fail "serve command not found — run forge-conductor register or set FORGE_SERVE_CMD"
}

Write-Host "Probing Forge-Conductor MCP (timeout ${TimeoutSec}s)..." -ForegroundColor Cyan
& $venvPy -c $pyProbe
$code = $LASTEXITCODE
if ($code -eq 0) {
  Write-Host "PASS — MCP is healthy. If LM Studio chat still hangs, the fault is model/engine/context, not Forge." -ForegroundColor Green
} else {
  Write-Host "FAIL — fix MCP before debugging the model." -ForegroundColor Red
}
exit $code
