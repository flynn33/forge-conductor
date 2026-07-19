#Requires -Version 5.1
<#
.SYNOPSIS
  On-demand Forge orchestration stack — RAM-disk install + keepers.

  Operator-initiated only (dashboard or CLI). Not login-autostart.

  LOAD:
    1) Create ImDisk volume (default 16GB, max 32GB)
    2) Hydrate full package + durable state onto R:
    3) Start primary / fallback / memory keepers from R:
    4) Supervise restarts + periodic snapshot + tier oldest data in 1GB chunks

  UNLOAD:
    Final snapshot → stop keepers → destroy RAM volume

  Actions: load | unload | restart | status | supervise | warm | snapshot | tier
#>
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("load", "unload", "restart", "status", "supervise", "warm", "snapshot", "tier")]
  [string]$Action,
  [switch]$Quiet,
  [ValidateRange(16, 32)]
  [int]$SizeGb = 0
)

$ErrorActionPreference = "Stop"
$fc = Join-Path $env:USERPROFILE ".forge-conductor"
$scripts = Join-Path $fc "scripts"
$bin = Join-Path $fc "bin"
$logDir = Join-Path $fc "logs"
$statePath = Join-Path $fc "stack-state.json"
$configPath = Join-Path $fc "ramdisk-config.json"
$ramdiskPs1 = Join-Path $scripts "forge-ramdisk.ps1"
$roles = @("primary", "fallback", "memory")

New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Write-StackLog([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
  Add-Content -Path (Join-Path $logDir "stack-control.log") -Value $line -Encoding utf8
  if (-not $Quiet) { Write-Host $line }
}

function Get-Cfg {
  if (-not (Test-Path $configPath)) { throw "missing $configPath" }
  $c = Get-Content $configPath -Raw | ConvertFrom-Json
  if ($SizeGb -ge 16) { $c.size_gb = $SizeGb }
  return $c
}

function Invoke-Ramdisk([string]$RdAction) {
  $rdArgs = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", $ramdiskPs1,
    "-Action", $RdAction,
    "-Quiet"
  )
  if ($SizeGb -ge 16) { $rdArgs += @("-SizeGb", "$SizeGb") }
  $raw = & pwsh @rdArgs 2>&1 | Out-String
  # Full multi-line JSON object (not last single line starting with '{')
  $m = [regex]::Match($raw, '(?s)\{.*\}\s*$')
  if ($m.Success) {
    try {
      $obj = $m.Value | ConvertFrom-Json
      if ($null -ne $obj) { return $obj }
    } catch {
      # fall through
    }
  }
  return [pscustomobject]@{ ok = $false; error = "ramdisk $RdAction parse failed"; raw = $raw.Trim() }
}

function New-EmptyState {
  return [pscustomobject]@{
    desired       = "unloaded"
    loaded_at     = $null
    unloaded_at   = $null
    pids          = [pscustomobject]@{}
    supervise_pid = $null
    mode          = "ramdisk"
    ram_letter    = "R"
  }
}

function Read-State {
  $base = New-EmptyState
  if (Test-Path $statePath) {
    try {
      $raw = Get-Content $statePath -Raw | ConvertFrom-Json
      # Merge into a mutable PSCustomObject with all fields (JSON may omit newer props)
      foreach ($name in @("desired", "loaded_at", "unloaded_at", "pids", "supervise_pid", "mode", "ram_letter")) {
        if ($null -ne $raw.PSObject.Properties[$name]) {
          $base | Add-Member -NotePropertyName $name -NotePropertyValue $raw.$name -Force
        }
      }
    } catch { }
  }
  return $base
}

function Write-State($st) {
  # Always write a plain object so next Read-State is stable
  $out = [ordered]@{
    desired       = $st.desired
    loaded_at     = $st.loaded_at
    unloaded_at   = $st.unloaded_at
    pids          = $st.pids
    supervise_pid = $st.supervise_pid
    mode          = if ($st.mode) { $st.mode } else { "ramdisk" }
    ram_letter    = if ($st.ram_letter) { $st.ram_letter } else { "R" }
  }
  ($out | ConvertTo-Json -Depth 8) | Set-Content -Path $statePath -Encoding utf8
}

function Get-LivePaths {
  $cfg = Get-Cfg
  return [pscustomobject]@{
    home     = [string]$cfg.live_home
    app      = [string]$cfg.live_app
    letter   = [string]$cfg.letter
    venvPy   = Join-Path $cfg.live_app ".venv\Scripts\python.exe"
    keeperPy = Join-Path $cfg.live_home "scripts\forge-mcp-keeper.py"
    # fallback keeper on disk home if not yet hydrated
    keeperPyDisk = Join-Path $scripts "forge-mcp-keeper.py"
  }
}

function Stop-StackProcesses {
  $st = Read-State
  if ($st.pids) {
    foreach ($prop in $st.pids.PSObject.Properties) {
      $pidVal = $prop.Value
      if (-not $pidVal) { continue }
      Write-StackLog "stop pid=$pidVal role=$($prop.Name)"
      try { & taskkill.exe /PID $pidVal /T /F 2>$null | Out-Null } catch { }
      Stop-Process -Id ([int]$pidVal) -Force -ErrorAction SilentlyContinue
    }
  }
  if ($st.supervise_pid) {
    Write-StackLog "stop supervise pid=$($st.supervise_pid)"
    try { & taskkill.exe /PID $st.supervise_pid /T /F 2>$null | Out-Null } catch { }
    Stop-Process -Id ([int]$st.supervise_pid) -Force -ErrorAction SilentlyContinue
  }
  # Also kill any orphan forge-stack supervise / keepers referencing R:
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -and (
      $_.CommandLine -match 'forge-stack\.ps1\s+-Action\s+supervise' -or
      $_.CommandLine -match 'forge-mcp-keeper\.py'
    )
  } | ForEach-Object {
    Write-StackLog "stop orphan pid=$($_.ProcessId)"
    try { & taskkill.exe /PID $_.ProcessId /T /F 2>$null | Out-Null } catch { }
  }
  Start-Sleep -Milliseconds 400
}

function Start-Keeper([string]$Role) {
  $lp = Get-LivePaths
  $py = $lp.venvPy
  $keeper = $lp.keeperPy
  if (-not (Test-Path $keeper)) { $keeper = $lp.keeperPyDisk }
  if (-not (Test-Path $py)) { throw "missing live venv python: $py (is RAM disk hydrated?)" }
  if (-not (Test-Path $keeper)) { throw "missing keeper: $keeper" }

  $liveHome = $lp.home
  $outLog = Join-Path $liveHome "logs\keeper-$Role.out.log"
  $errLog = Join-Path $liveHome "logs\keeper-$Role.err.log"
  New-Item -ItemType Directory -Force -Path (Join-Path $liveHome "logs") | Out-Null

  Write-StackLog "start keeper role=$Role home=$liveHome py=$py"
  $env:FORGE_CONDUCTOR_HOME = $liveHome
  $p = Start-Process -FilePath $py `
    -ArgumentList @($keeper, "--role", $Role, "--restart-delay", "3") `
    -WorkingDirectory (Split-Path $keeper -Parent) `
    -WindowStyle Hidden `
    -PassThru `
    -RedirectStandardOutput $outLog `
    -RedirectStandardError $errLog
  return $p.Id
}

function Test-RoleAlive([string]$Role) {
  $st = Read-State
  if ($st.pids -and $st.pids.$Role) {
    try {
      $null = Get-Process -Id ([int]$st.pids.$Role) -ErrorAction Stop
      return $true
    } catch { return $false }
  }
  return $false
}

function Set-RolePid([string]$Role, [int]$PidVal) {
  $st = Read-State
  $pids = @{}
  if ($st.pids) {
    foreach ($prop in $st.pids.PSObject.Properties) {
      $pids[$prop.Name] = $prop.Value
    }
  }
  $pids[$Role] = $PidVal
  $st.pids = $pids
  Write-State $st
}

function Invoke-WarmRam {
  $lp = Get-LivePaths
  if (-not (Test-Path $lp.venvPy)) { return @{ ok = $false; error = "no live venv" } }
  if (-not (Test-Path $lp.home)) { return @{ ok = $false; error = "no live home" } }
  $homeEsc = $lp.home.Replace('\', '\\')
  $srcEsc = (Join-Path $lp.app "src").Replace('\', '\\')
  $code = @"
import os, json, sys
os.environ["FORGE_CONDUCTOR_HOME"] = r"$($lp.home)"
sys.path.insert(0, r"$($lp.app)\src")
from forge_conductor.config import ensure_home, get_home
from forge_conductor.store import connect, migrate
from forge_conductor.memory_ram import ensure_bank, set_bank
from forge_conductor.ram_orchestration import ensure_orchestration, set_orchestration
ensure_home()
set_bank(None)
set_orchestration(None)
conn = connect()
migrate(conn)
bank = ensure_bank(conn, get_home())
orch = ensure_orchestration(conn, get_home())
out = {
  "ok": True,
  "memory": bank.stats(),
  "orchestration": orch.stats(),
  "backup": orch.flush_backup(),
  "home": r"$($lp.home)",
}
print(json.dumps(out))
"@
  try {
    $env:FORGE_CONDUCTOR_HOME = $lp.home
    $raw = & $lp.venvPy -c $code 2>&1 | Out-String
    $jsonLine = ($raw -split "`n" | Where-Object { $_.Trim().StartsWith("{") } | Select-Object -Last 1)
    if ($jsonLine) { return ($jsonLine | ConvertFrom-Json) }
    return @{ ok = $false; error = $raw.Trim() }
  } catch {
    return @{ ok = $false; error = "$_" }
  }
}

function Get-StatusObject {
  $st = Read-State
  $rolesLive = @{}
  $procList = @()
  foreach ($r in $roles) {
    $pidVal = $null
    if ($st.pids) {
      try { $pidVal = $st.pids.$r } catch { $pidVal = $null }
    }
    $alive = $false
    if ($pidVal) {
      try {
        $null = Get-Process -Id ([int]$pidVal) -ErrorAction Stop
        $alive = $true
        $procList += [pscustomobject]@{ Pid = [int]$pidVal; Role = $r }
      } catch { $alive = $false }
    }
    $rolesLive[$r] = $alive
  }
  $liveCount = @($rolesLive.Values | Where-Object { $_ }).Count
  $desired = $st.desired
  if (-not $desired) { $desired = "unloaded" }

  # Fast ramdisk probe (no nested pwsh — avoids hang under concurrent supervise snapshots)
  $cfg = Get-Cfg
  $letter = [string]$cfg.letter
  $ramMounted = Test-Path "${letter}:\"
  $rdState = $null
  $rdPath = Join-Path $fc "ramdisk-state.json"
  if (Test-Path $rdPath) {
    try { $rdState = Get-Content $rdPath -Raw | ConvertFrom-Json } catch { }
  }
  $rd = [pscustomobject]@{
    ok                 = $true
    provider           = "imdisk"
    letter             = $letter
    mounted            = $ramMounted
    size_gb_config     = [int]$cfg.size_gb
    size_gb_min        = [int]$cfg.size_gb_min
    size_gb_max        = [int]$cfg.size_gb_max
    live_home_ok       = (Test-Path (Join-Path $cfg.live_home "."))
    live_app_ok        = (Test-Path (Join-Path $cfg.live_app ".venv"))
    last_snapshot      = if ($rdState) { $rdState.last_snapshot } else { $null }
    last_snapshot_ok   = if ($rdState) { [bool]$rdState.last_snapshot_ok } else { $false }
    last_tier          = if ($rdState) { $rdState.last_tier } else { $null }
    last_error         = if ($rdState) { $rdState.last_error } else { $null }
  }

  return [pscustomobject]@{
    ok               = $true
    desired          = $desired
    loaded           = ($desired -eq "loaded" -and $liveCount -eq $roles.Count -and $ramMounted)
    partially_loaded = ($desired -eq "loaded" -and ($liveCount -gt 0 -or $ramMounted) -and -not ($liveCount -eq $roles.Count -and $ramMounted))
    roles            = $rolesLive
    process_count    = $procList.Count
    processes        = $procList
    loaded_at        = $st.loaded_at
    unloaded_at      = $st.unloaded_at
    supervise_pid    = $st.supervise_pid
    supervise_alive  = if ($st.supervise_pid) {
      try { $null = Get-Process -Id ([int]$st.supervise_pid) -ErrorAction Stop; $true } catch { $false }
    } else { $false }
    state_path       = $statePath
    mode             = "ramdisk-on-demand"
    restart_policy   = "on_failure_while_loaded"
    autostart        = $false
    ramdisk          = $rd
  }
}

function Start-GrokWorkerIfNeeded {
  # Primary executor is Grok Build (interactive session + connect prompt).
  # Optional cloud agent_worker only if agent_backend.json says executor=xai_api.
  $cfgPath = Join-Path $fc "agent_backend.json"
  $mode = "host"
  $executor = "grok_build"
  if (Test-Path $cfgPath) {
    try {
      $ab = Get-Content $cfgPath -Raw | ConvertFrom-Json
      $mode = [string]$ab.mode
      if ($ab.grok -and $ab.grok.executor) { $executor = [string]$ab.grok.executor }
      elseif ($ab.executor) { $executor = [string]$ab.executor }
    } catch { }
  }
  $lp = Get-LivePaths
  $liveAb = Join-Path $lp.home "agent_backend.json"
  if (Test-Path $liveAb) {
    try {
      $ab2 = Get-Content $liveAb -Raw | ConvertFrom-Json
      $mode = [string]$ab2.mode
      if ($ab2.grok -and $ab2.grok.executor) { $executor = [string]$ab2.grok.executor }
    } catch { }
  }
  if ($mode -ne "grok") { return }
  if ($executor -ne "xai_api") {
    Write-StackLog "mode=grok executor=$executor — waiting for Grok Build session (no API worker)"
    return
  }

  $existing = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -and $_.CommandLine -match 'forge_conductor\.agent_worker|agent_worker\.py'
  }
  if ($existing) {
    Write-StackLog "xai api worker already running pid=$(@($existing)[0].ProcessId)"
    return
  }
  $py = $lp.venvPy
  if (-not (Test-Path $py)) {
    foreach ($cand in @($env:FORGE_PYTHON, (Join-Path $env:USERPROFILE ".forge-conductor\.venv\Scripts\python.exe"))) {
      if ($cand -and (Test-Path $cand)) { $py = $cand; break }
    }
  }
  if (-not (Test-Path $py)) {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { $py = $cmd.Source } else {
      Write-StackLog "xai worker: no python"
      return
    }
  }
  $liveHome = $lp.home
  if (-not (Test-Path $liveHome)) { $liveHome = $fc }
  $outLog = Join-Path $liveHome "logs\grok-worker.out.log"
  $errLog = Join-Path $liveHome "logs\grok-worker.err.log"
  New-Item -ItemType Directory -Force -Path (Join-Path $liveHome "logs") | Out-Null
  $src = Join-Path $lp.app "src"
  if (-not (Test-Path $src)) {
    if ($env:FORGE_SOURCE_ROOT -and (Test-Path $env:FORGE_SOURCE_ROOT)) {
      $src = $env:FORGE_SOURCE_ROOT
    } else {
      $src = ""
    }
  }
  Write-StackLog "start optional xai api worker home=$liveHome"
  $env:FORGE_CONDUCTOR_HOME = $liveHome
  $env:FORGE_AGENT_EXECUTOR = "grok"
  if ($src) { $env:PYTHONPATH = $src }
  $env:PYTHONUTF8 = "1"
  $workDir = if ($src) { Split-Path $src -Parent } else { $liveHome }
  Start-Process -FilePath $py `
    -ArgumentList @("-m", "forge_conductor.agent_worker") `
    -WorkingDirectory $workDir `
    -WindowStyle Hidden `
    -RedirectStandardOutput $outLog `
    -RedirectStandardError $errLog | Out-Null
}

function Start-SuperviseIfNeeded {
  $st = Read-State
  $alive = $false
  if ($st.supervise_pid) {
    try { $null = Get-Process -Id ([int]$st.supervise_pid) -ErrorAction Stop; $alive = $true } catch { $alive = $false }
  }
  if ($alive) { return }
  $existing = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -and $_.CommandLine -match 'forge-stack\.ps1\s+-Action\s+supervise'
  }
  if ($existing) {
    $st.supervise_pid = @($existing)[0].ProcessId
    Write-State $st
    return
  }
  $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
  if (-not $pwsh) { $pwsh = "pwsh" }
  $sp = Start-Process -FilePath $pwsh `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $PSCommandPath, "-Action", "supervise", "-Quiet") `
    -WorkingDirectory $scripts `
    -WindowStyle Hidden `
    -PassThru
  $st = Read-State
  $st.supervise_pid = $sp.Id
  Write-State $st
  Write-StackLog "supervise loop started pid=$($sp.Id)"
}

function Invoke-LoadStack {
  Write-StackLog "LOAD stack (RAM-disk on-demand)"
  $cfg = Get-Cfg
  Write-StackLog "ramdisk size_gb=$($cfg.size_gb) letter=$($cfg.letter)"

  $rd = Invoke-Ramdisk "load"
  # Accept ok=true, or already-mounted hydrate success (status.mounted)
  $rdOk = $false
  if ($rd -and ($rd.ok -eq $true -or $rd.ok -eq "True")) { $rdOk = $true }
  if ($rd -and $rd.status -and $rd.status.mounted) { $rdOk = $true }
  if ($rd -and $rd.volume -and $rd.hydrate -and $rd.hydrate.ok) { $rdOk = $true }
  if (-not $rdOk) {
    Write-StackLog "ramdisk load FAILED: $($rd | ConvertTo-Json -Compress -Depth 4)"
    throw "ramdisk load failed: $($rd.error)"
  }
  Write-StackLog "ramdisk load OK"

  $st = Read-State
  $st | Add-Member -NotePropertyName desired -NotePropertyValue "loaded" -Force
  $st | Add-Member -NotePropertyName loaded_at -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
  $st | Add-Member -NotePropertyName mode -NotePropertyValue "ramdisk" -Force
  $st | Add-Member -NotePropertyName ram_letter -NotePropertyValue ([string]$cfg.letter) -Force
  $st | Add-Member -NotePropertyName pids -NotePropertyValue ([pscustomobject]@{}) -Force
  Write-State $st

  $pids = @{}
  foreach ($r in $roles) {
    try {
      $pids[$r] = Start-Keeper $r
      Write-StackLog "started $r pid=$($pids[$r])"
    } catch {
      Write-StackLog "keeper $r failed: $_"
    }
  }
  $st = Read-State
  $st.pids = $pids
  Write-State $st

  Start-Sleep -Seconds 3
  foreach ($r in $roles) {
    if ($pids[$r]) {
      try {
        $null = Get-Process -Id ([int]$pids[$r]) -ErrorAction Stop
      } catch {
        Write-StackLog "keeper $r died immediately — restart once"
        try {
          $pids[$r] = Start-Keeper $r
          Write-StackLog "restarted $r pid=$($pids[$r])"
        } catch {
          Write-StackLog "restart $r failed: $_"
        }
      }
    }
  }
  $st = Read-State
  $st.pids = $pids
  Write-State $st

  Start-SuperviseIfNeeded
  try { Start-GrokWorkerIfNeeded } catch { Write-StackLog "grok worker start warn: $_" }

  # Warm process-RAM corpora on live home (secondary acceleration)
  $pwsh2 = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
  if (-not $pwsh2) { $pwsh2 = "pwsh" }
  Start-Process -FilePath $pwsh2 `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $PSCommandPath, "-Action", "warm", "-Quiet") `
    -WorkingDirectory $scripts `
    -WindowStyle Hidden | Out-Null
  Write-StackLog "process-RAM warm kicked off (background)"

  return Get-StatusObject
}

function Invoke-UnloadStack {
  Write-StackLog "UNLOAD stack (snapshot + destroy RAM disk)"
  # Mark unloaded first so supervise exits
  $st = Read-State
  $st.desired = "unloaded"
  Write-State $st

  # Final snapshot while volume still up
  try {
    $snap = Invoke-Ramdisk "snapshot"
    Write-StackLog "final snapshot ok=$($snap.ok)"
  } catch {
    Write-StackLog "final snapshot error: $_"
  }

  Stop-StackProcesses

  $st = Read-State
  $st.desired = "unloaded"
  $st.unloaded_at = (Get-Date).ToUniversalTime().ToString("o")
  $st.pids = @{}
  $st.supervise_pid = $null
  Write-State $st

  try {
    $des = Invoke-Ramdisk "unload"
    Write-StackLog "ramdisk unload ok=$($des.ok)"
  } catch {
    Write-StackLog "ramdisk unload error: $_"
  }

  return Get-StatusObject
}

switch ($Action) {
  "status" {
    Get-StatusObject | ConvertTo-Json -Depth 10
    exit 0
  }
  "warm" {
    Invoke-WarmRam | ConvertTo-Json -Depth 8
    exit 0
  }
  "snapshot" {
    Invoke-Ramdisk "snapshot" | ConvertTo-Json -Depth 8
    exit 0
  }
  "tier" {
    Invoke-Ramdisk "tier" | ConvertTo-Json -Depth 8
    exit 0
  }
  "unload" {
    Invoke-UnloadStack | ConvertTo-Json -Depth 10
    exit 0
  }
  "restart" {
    Write-StackLog "RESTART stack"
    try { Invoke-UnloadStack | Out-Null } catch { Write-StackLog "restart unload warn: $_" }
    Start-Sleep -Seconds 2
    $status = Invoke-LoadStack
    [pscustomobject]@{
      ok     = $true
      action = "restart"
      status = $status
    } | ConvertTo-Json -Depth 12
    exit 0
  }
  "load" {
    $status = Invoke-LoadStack
    [pscustomobject]@{
      ok     = $true
      action = "load"
      status = $status
      mode   = "ramdisk"
    } | ConvertTo-Json -Depth 12
    exit 0
  }
  "supervise" {
    Write-StackLog "supervise loop start pid=$PID (ramdisk mode)"
    $cfg = Get-Cfg
    $snapEvery = [int]$cfg.snapshot_interval_sec
    if ($snapEvery -lt 10) { $snapEvery = 30 }
    $lastSnap = Get-Date
    while ($true) {
      try {
        $st = Read-State
        if ($st.desired -ne "loaded") {
          Write-StackLog "desired=unloaded — supervise exit"
          exit 0
        }

        # Ensure volume still present
        $rd = Invoke-Ramdisk "status"
        if (-not $rd.mounted) {
          Write-StackLog "CRITICAL: RAM volume missing while desired=loaded — attempting recreate"
          try {
            Invoke-Ramdisk "load" | Out-Null
          } catch {
            Write-StackLog "recreate failed: $_"
          }
        }

        foreach ($r in $roles) {
          if (-not (Test-RoleAlive $r)) {
            Write-StackLog "FAILURE restart keeper role=$r"
            try {
              $newPid = Start-Keeper $r
              Set-RolePid $r $newPid
              Write-StackLog "restarted $r pid=$newPid"
            } catch {
              Write-StackLog "restart failed $r : $_"
            }
          }
        }

        # Keep Grok worker up when mode=grok
        try { Start-GrokWorkerIfNeeded } catch { }

        # Periodic snapshot + tier
        if (((Get-Date) - $lastSnap).TotalSeconds -ge $snapEvery) {
          try {
            $s = Invoke-Ramdisk "snapshot"
            Write-StackLog "periodic snapshot ok=$($s.ok)"
          } catch {
            Write-StackLog "periodic snapshot err: $_"
          }
          try {
            $t = Invoke-Ramdisk "tier"
            if ($t -and -not $t.skipped) {
              Write-StackLog "tier moved_mb=$($t.moved_mb) files=$($t.moved_files)"
            }
          } catch {
            Write-StackLog "tier err: $_"
          }
          $lastSnap = Get-Date
        }
      } catch {
        Write-StackLog "supervise error: $_"
      }
      Start-Sleep -Seconds 8
    }
  }
}
