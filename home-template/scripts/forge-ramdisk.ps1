#Requires -Version 5.1
<#
.SYNOPSIS
  Forge RAM-disk volume lifecycle (ImDisk).

  Creates / hydrates / snapshots / tiers / destroys the live orchestration package volume.
  Management engine (telemetry) stays on C:; only the orchestration layer lives on R:.

  Actions: status | ensure-image | create | hydrate | snapshot | tier | destroy | load | unload
#>
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet(
    "status", "ensure-image", "create", "hydrate", "snapshot",
    "tier", "destroy", "load", "unload", "config"
  )]
  [string]$Action,

  [ValidateRange(16, 32)]
  [int]$SizeGb = 0,

  [switch]$Quiet,
  [switch]$Force
)

$ErrorActionPreference = "Stop"
$fc = Join-Path $env:USERPROFILE ".forge-conductor"
$configPath = Join-Path $fc "ramdisk-config.json"
$statePath = Join-Path $fc "ramdisk-state.json"
$logDir = Join-Path $fc "logs"
$logFile = Join-Path $logDir "ramdisk.log"

New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Write-RdLog([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
  Add-Content -Path $logFile -Value $line -Encoding utf8
  if (-not $Quiet) { Write-Host $line }
}

function Expand-RdPath([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $p }
  $expanded = [Environment]::ExpandEnvironmentVariables($p)
  # Drop unresolved %VAR% tokens left empty by missing env vars
  if ($expanded -match '^%[^%]+%$') { return "" }
  return $expanded
}

function Get-RdConfig {
  if (-not (Test-Path $configPath)) {
    throw "missing ramdisk-config.json at $configPath"
  }
  $c = Get-Content $configPath -Raw | ConvertFrom-Json
  if ($SizeGb -ge 16) { $c.size_gb = $SizeGb }
  if ($c.size_gb -lt $c.size_gb_min) { $c.size_gb = $c.size_gb_min }
  if ($c.size_gb -gt $c.size_gb_max) { $c.size_gb = $c.size_gb_max }
  $c.durable_root = Expand-RdPath ([string]$c.durable_root)
  if ([string]::IsNullOrWhiteSpace($c.durable_root)) {
    $c.durable_root = Join-Path $env:USERPROFILE ".forge-conductor\durable"
  }
  $c.source_app = Expand-RdPath ([string]$c.source_app)
  if ([string]::IsNullOrWhiteSpace($c.source_app)) {
    if ($env:FORGE_SOURCE_ROOT) { $c.source_app = $env:FORGE_SOURCE_ROOT }
  }
  return $c
}

function Save-RdConfig($c) {
  ($c | ConvertTo-Json -Depth 8) | Set-Content -Path $configPath -Encoding utf8
}

function Read-RdState {
  if (Test-Path $statePath) {
    try { return Get-Content $statePath -Raw | ConvertFrom-Json } catch { }
  }
  return [pscustomobject]@{
    mounted         = $false
    letter          = $null
    size_gb         = $null
    created_at      = $null
    destroyed_at    = $null
    last_snapshot   = $null
    last_snapshot_ok = $false
    last_tier       = $null
    last_error      = $null
    image_built_at  = $null
  }
}

function Write-RdState($st) {
  ($st | ConvertTo-Json -Depth 8) | Set-Content -Path $statePath -Encoding utf8
}

function Get-ImdiskExe {
  $candidates = @(
    "C:\Windows\System32\imdisk.exe",
    "C:\Program Files\ImDisk\imdisk.exe",
    (Get-Command imdisk -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
  ) | Where-Object { $_ -and (Test-Path $_) }
  if (-not $candidates) { throw "imdisk.exe not found — install ImDisk Toolkit to C:\Tools\ImDisk / Program Files" }
  return $candidates[0]
}

function Test-VolumeMounted([string]$Letter) {
  $root = "${Letter}:\"
  return (Test-Path $root)
}

function Get-VolumeStats([string]$Letter) {
  $root = "${Letter}:\"
  if (-not (Test-Path $root)) {
    return [pscustomobject]@{
      mounted = $false
      letter  = $Letter
      total_bytes = 0
      free_bytes  = 0
      used_bytes  = 0
      free_gb     = 0
      used_gb     = 0
      total_gb    = 0
      used_pct    = 0
    }
  }
  $drive = Get-PSDrive -Name $Letter -PSProvider FileSystem -ErrorAction SilentlyContinue
  if (-not $drive) {
    $item = Get-Item $root
    # fallback via WMI
    $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${Letter}:'" -ErrorAction SilentlyContinue
    if ($vol) {
      $free = [int64]$vol.FreeSpace
      $total = [int64]$vol.Size
      $used = $total - $free
      return [pscustomobject]@{
        mounted     = $true
        letter      = $Letter
        total_bytes = $total
        free_bytes  = $free
        used_bytes  = $used
        free_gb     = [math]::Round($free / 1GB, 2)
        used_gb     = [math]::Round($used / 1GB, 2)
        total_gb    = [math]::Round($total / 1GB, 2)
        used_pct    = if ($total -gt 0) { [math]::Round(100.0 * $used / $total, 1) } else { 0 }
      }
    }
  }
  $free = [int64]$drive.Free
  $used = [int64]$drive.Used
  $total = $free + $used
  return [pscustomobject]@{
    mounted     = $true
    letter      = $Letter
    total_bytes = $total
    free_bytes  = $free
    used_bytes  = $used
    free_gb     = [math]::Round($free / 1GB, 2)
    used_gb     = [math]::Round($used / 1GB, 2)
    total_gb    = [math]::Round($total / 1GB, 2)
    used_pct    = if ($total -gt 0) { [math]::Round(100.0 * $used / $total, 1) } else { 0 }
  }
}

function Ensure-DurableLayout($cfg) {
  $root = $cfg.durable_root
  $dirs = @(
    $root,
    (Join-Path $root "image"),
    (Join-Path $root "image\app"),
    (Join-Path $root "state"),
    (Join-Path $root "state\current"),
    (Join-Path $root "snapshots"),
    (Join-Path $root "tiered"),
    (Join-Path $root "logs")
  )
  foreach ($d in $dirs) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
  }
}

function Seed-DurableState($cfg) {
  $current = Join-Path $cfg.durable_root "state\current"
  $srcHome = $fc
  $files = @(
    "store.sqlite", "store.sqlite-wal", "store.sqlite-shm",
    "memory_corpus.json", "orchestration_corpus.json",
    "config.toml", "audit.jsonl", "MEMORY.md", "AGENTS.md", "SUPER_AGENTS.md",
    "agent_backend.json"
  )
  foreach ($f in $files) {
    $src = Join-Path $srcHome $f
    $dst = Join-Path $current $f
    if ((Test-Path $src) -and -not (Test-Path $dst)) {
      Copy-Item -LiteralPath $src -Destination $dst -Force
      Write-RdLog "seed state file $f"
    }
  }
  $agentsSrc = Join-Path $srcHome "agents"
  $agentsDst = Join-Path $current "agents"
  if ((Test-Path $agentsSrc) -and -not (Test-Path $agentsDst)) {
    Copy-Item -LiteralPath $agentsSrc -Destination $agentsDst -Recurse -Force
    Write-RdLog "seed agents/"
  }
  # Keep scripts + mcp-role on live home too
  foreach ($name in @("scripts", "mcp-role", "bin")) {
    $src = Join-Path $srcHome $name
    $dst = Join-Path $current $name
    if ((Test-Path $src) -and -not (Test-Path (Join-Path $dst ".seeded"))) {
      New-Item -ItemType Directory -Force -Path $dst | Out-Null
      # only seed lightweight bits for bin/scripts; full scripts always re-copied from disk home on hydrate for control scripts
      if ($name -eq "agents") { continue }
    }
  }
}

function Invoke-EnsureImage($cfg) {
  Ensure-DurableLayout $cfg
  $src = $cfg.source_app
  if (-not (Test-Path $src)) { throw "source_app missing: $src" }
  $imgApp = Join-Path $cfg.durable_root "image\app"
  Write-RdLog "ensure-image: mirror $src -> $imgApp"
  # Mirror package essentials (not .git, not __pycache__ noise is ok)
  $null = robocopy $src $imgApp /MIR /XD .git .pytest_cache __pycache__ .mypy_cache /XF *.pyc /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
  $code = $LASTEXITCODE
  # robocopy 0-7 = success-ish
  if ($code -ge 8) { throw "robocopy image failed exit=$code" }
  $st = Read-RdState
  $st.image_built_at = (Get-Date).ToUniversalTime().ToString("o")
  Write-RdState $st
  $size = (Get-ChildItem $imgApp -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  Write-RdLog ("ensure-image done bytes={0:N0} robocopy={1}" -f $size, $code)
  return [pscustomobject]@{
    ok = $true
    image_path = $imgApp
    bytes = $size
    robocopy_exit = $code
    built_at = $st.image_built_at
  }
}

function Invoke-ElevatedRamdiskOp {
  param(
    [string]$Action,
    [string]$Letter = "R",
    [int]$SizeGb = 16,
    [string]$Label = "FORGE-RAM",
    [int]$TimeoutSec = 120
  )
  $taskName = "ForgeRamdiskElevated"
  $reqPath = Join-Path $fc "logs\ramdisk-ops-request.json"
  $respPath = Join-Path $fc "logs\ramdisk-ops-response.json"
  New-Item -ItemType Directory -Force -Path (Join-Path $fc "logs") | Out-Null

  $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if (-not $task) {
    $install = Join-Path $fc "scripts\install-forge-ramdisk-elevated-task.ps1"
    if (Test-Path $install) {
      Write-RdLog "registering elevated task $taskName"
      & pwsh -NoProfile -ExecutionPolicy Bypass -File $install 2>&1 | ForEach-Object { Write-RdLog "task-install: $_" }
    }
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  }
  if (-not $task) {
    throw "Elevated task $taskName missing. Run as admin: install-forge-ramdisk-elevated-task.ps1"
  }

  if (Test-Path $respPath) { Remove-Item $respPath -Force -ErrorAction SilentlyContinue }
  $req = [ordered]@{
    action     = $Action
    letter     = $Letter
    size_gb    = $SizeGb
    label      = $Label
    request_id = [guid]::NewGuid().ToString()
    ts         = (Get-Date).ToUniversalTime().ToString("o")
  }
  ($req | ConvertTo-Json) | Set-Content -Path $reqPath -Encoding utf8
  Write-RdLog "elevated op request action=$Action letter=$Letter"
  Start-ScheduledTask -TaskName $taskName | Out-Null

  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path $respPath) {
      Start-Sleep -Milliseconds 150
      try {
        $resp = Get-Content $respPath -Raw | ConvertFrom-Json
        Write-RdLog "elevated op response ok=$($resp.ok) action=$($resp.action)"
        return $resp
      } catch {
        Start-Sleep -Milliseconds 200
      }
    }
    Start-Sleep -Milliseconds 250
  }
  throw "elevated ramdisk op timeout action=$Action (${TimeoutSec}s)"
}

function Invoke-CreateVolume($cfg) {
  $letter = [string]$cfg.letter
  $sizeGb = [int]$cfg.size_gb
  if ($sizeGb -lt [int]$cfg.size_gb_min) { $sizeGb = [int]$cfg.size_gb_min }
  if ($sizeGb -gt [int]$cfg.size_gb_max) { $sizeGb = [int]$cfg.size_gb_max }

  # Free RAM check: need size + 4GB headroom for OS/models
  $os = Get-CimInstance Win32_OperatingSystem
  $freeGb = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
  $need = $sizeGb + 4
  if ($freeGb -lt $need -and -not $Force) {
    throw "insufficient free RAM: free=${freeGb}GB need>=${need}GB for ${sizeGb}GB disk (use -Force to override)"
  }

  if (Test-VolumeMounted $letter) {
    Write-RdLog "volume ${letter}: already mounted — reusing"
    $st = Read-RdState
    $st.mounted = $true
    $st.letter = $letter
    Write-RdState $st
    return Get-VolumeStats $letter
  }

  # ImDisk create/format requires elevation — dashboard LOAD is not elevated.
  # Use scheduled task ForgeRamdiskElevated (RunLevel Highest).
  $label = [string]$cfg.label
  Write-RdLog "create RAM disk ${letter}: size=${sizeGb}G label=$label via elevated task"
  $resp = Invoke-ElevatedRamdiskOp -Action create -Letter $letter -SizeGb $sizeGb -Label $label -TimeoutSec 180
  if (-not $resp -or $resp.ok -ne $true) {
    $err = if ($resp) { $resp.error } else { "no response" }
    throw "elevated create failed: $err"
  }
  if (-not (Test-VolumeMounted $letter)) {
    # brief settle
    Start-Sleep -Seconds 1
  }
  if (-not (Test-VolumeMounted $letter)) {
    throw "elevated create reported ok but ${letter}: not mounted"
  }

  $st = Read-RdState
  $st.mounted = $true
  $st.letter = $letter
  $st.size_gb = $sizeGb
  $st.created_at = (Get-Date).ToUniversalTime().ToString("o")
  $st.destroyed_at = $null
  $st.last_error = $null
  Write-RdState $st
  Write-RdLog "create OK (elevated)"
  return Get-VolumeStats $letter
}

function Write-LiveLaunchers($cfg) {
  $liveHome = $cfg.live_home
  $liveApp = $cfg.live_app
  $bin = Join-Path $liveHome "bin"
  $logs = Join-Path $liveHome "logs"
  New-Item -ItemType Directory -Force -Path $bin, $logs | Out-Null

  $roles = @{
    "forge-serve.cmd"          = "primary"
    "forge-serve-fallback.cmd" = "fallback"
    "forge-memory-serve.cmd"   = "memory"
  }
  foreach ($name in $roles.Keys) {
    $role = $roles[$name]
    $path = Join-Path $bin $name
    $content = @"
@echo off
setlocal EnableExtensions
set "FORGE_CONDUCTOR_HOME=$liveHome"
set "FORGE_MCP_ROLE=$role"
set "FASTMCP_SHOW_SERVER_BANNER=false"
set "GH_PROMPT_DISABLED=1"
set "GIT_TERMINAL_PROMPT=0"
set "GCM_INTERACTIVE=never"
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
set "PATH=C:\Program Files\GitHub CLI;C:\Program Files\Git\cmd;C:\Program Files\nodejs;%USERPROFILE%\.local\bin;C:\WINDOWS\system32;C:\WINDOWS;%PATH%"
set "VENV_EXE=$liveApp\.venv\Scripts\forge-conductor.exe"
set "VENV_PY=$liveApp\.venv\Scripts\python.exe"
set "LOGDIR=$liveHome\logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
echo [%DATE% %TIME%] $role launcher (RAM) start >> "%LOGDIR%\launcher.log"
if exist "%VENV_EXE%" (
  "%VENV_EXE%" supervise
  set "EC=%ERRORLEVEL%"
  echo [%DATE% %TIME%] $role supervise exit ec=%EC% >> "%LOGDIR%\launcher.log"
  exit /b %EC%
)
if exist "%VENV_PY%" (
  set "PYTHONPATH=$liveApp\src"
  "%VENV_PY%" -m forge_conductor supervise
  set "EC=%ERRORLEVEL%"
  echo [%DATE% %TIME%] $role py-m supervise exit ec=%EC% >> "%LOGDIR%\launcher.log"
  exit /b %EC%
)
echo [%DATE% %TIME%] $role ALL launch candidates failed >> "%LOGDIR%\launcher.log"
echo forge-serve RAM: ALL launch candidates failed 1>&2
exit /b 1
"@
    Set-Content -Path $path -Value $content -Encoding ascii
  }

  # Copy keeper + stack helpers onto live home scripts for process isolation
  $liveScripts = Join-Path $liveHome "scripts"
  New-Item -ItemType Directory -Force -Path $liveScripts | Out-Null
  $keeperSrc = Join-Path $fc "scripts\forge-mcp-keeper.py"
  if (Test-Path $keeperSrc) {
    Copy-Item $keeperSrc (Join-Path $liveScripts "forge-mcp-keeper.py") -Force
  }
}

function Write-DiskShims($cfg) {
  $diskBin = Join-Path $fc "bin"
  New-Item -ItemType Directory -Force -Path $diskBin | Out-Null
  $liveHome = $cfg.live_home
  $map = @{
    "forge-serve.cmd"          = "forge-serve.cmd"
    "forge-serve-fallback.cmd" = "forge-serve-fallback.cmd"
    "forge-memory-serve.cmd"   = "forge-memory-serve.cmd"
  }
  foreach ($name in $map.Keys) {
    $path = Join-Path $diskBin $name
    $live = Join-Path $liveHome "bin\$($map[$name])"
    $content = @"
@echo off
setlocal EnableExtensions
REM Disk shim: delegates to RAM-disk live stack when LOADED.
if not exist "$live" (
  echo [forge] RAM orchestration stack is not loaded. Open http://127.0.0.1:7788/ and click LOAD. 1>&2
  exit /b 2
)
set "FORGE_CONDUCTOR_HOME=$liveHome"
call "$live" %*
exit /b %ERRORLEVEL%
"@
    Set-Content -Path $path -Value $content -Encoding ascii
  }
  # Convenience stack control
  $loadCmd = Join-Path $diskBin "stack-load.cmd"
  $unloadCmd = Join-Path $diskBin "stack-unload.cmd"
  Set-Content -Path $loadCmd -Value "@echo off`r`npwsh -NoProfile -ExecutionPolicy Bypass -File `"$fc\scripts\forge-stack.ps1`" -Action load`r`n" -Encoding ascii
  Set-Content -Path $unloadCmd -Value "@echo off`r`npwsh -NoProfile -ExecutionPolicy Bypass -File `"$fc\scripts\forge-stack.ps1`" -Action unload`r`n" -Encoding ascii
}

function Invoke-Hydrate($cfg) {
  Ensure-DurableLayout $cfg
  Seed-DurableState $cfg
  $letter = [string]$cfg.letter
  if (-not (Test-VolumeMounted $letter)) { throw "volume ${letter}: not mounted — create first" }

  $imgApp = Join-Path $cfg.durable_root "image\app"
  if (-not (Test-Path (Join-Path $imgApp ".venv"))) {
    Write-RdLog "image missing/incomplete — building"
    Invoke-EnsureImage $cfg | Out-Null
  }

  $liveApp = $cfg.live_app
  $liveHome = $cfg.live_home
  New-Item -ItemType Directory -Force -Path $liveApp, $liveHome | Out-Null

  Write-RdLog "hydrate app $imgApp -> $liveApp"
  $null = robocopy $imgApp $liveApp /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
  if ($LASTEXITCODE -ge 8) { throw "robocopy app hydrate failed exit=$LASTEXITCODE" }

  $stateCurrent = Join-Path $cfg.durable_root "state\current"
  Write-RdLog "hydrate state $stateCurrent -> $liveHome"
  $null = robocopy $stateCurrent $liveHome /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
  if ($LASTEXITCODE -ge 8) { throw "robocopy state hydrate failed exit=$LASTEXITCODE" }

  # Ensure logs dir on live
  New-Item -ItemType Directory -Force -Path (Join-Path $liveHome "logs") | Out-Null

  Write-LiveLaunchers $cfg
  Write-DiskShims $cfg
  Write-RdLog "hydrate complete"
  return [pscustomobject]@{
    ok = $true
    live_app = $liveApp
    live_home = $liveHome
    volume = Get-VolumeStats $letter
  }
}

function Invoke-SqliteCheckpoint($liveHome) {
  $db = Join-Path $liveHome "store.sqlite"
  if (-not (Test-Path $db)) { return }
  $liveAppPy = Join-Path (Split-Path $liveHome -Parent) "app\.venv\Scripts\python.exe"
  $envPy = $env:FORGE_PYTHON
  $homePy = Join-Path $env:USERPROFILE ".forge-conductor\.venv\Scripts\python.exe"
  $py = @($liveAppPy, $envPy, $homePy) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
  if (-not $py) {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { $py = $cmd.Source }
  }
  if (-not $py) { return }
  $code = "import sqlite3,sys;p=sys.argv[1];c=sqlite3.connect(p,timeout=30);c.execute('PRAGMA wal_checkpoint(TRUNCATE)');c.close();print('ok')"
  try {
    & $py -c $code $db 2>&1 | Out-Null
  } catch {
    Write-RdLog "sqlite checkpoint warn: $_"
  }
}

function Invoke-Snapshot($cfg, [switch]$Blocking) {
  $letter = [string]$cfg.letter
  $st = Read-RdState
  if (-not (Test-VolumeMounted $letter)) {
    $st.last_snapshot_ok = $false
    $st.last_error = "snapshot skipped: volume not mounted"
    Write-RdState $st
    return [pscustomobject]@{ ok = $false; error = $st.last_error }
  }
  $liveHome = $cfg.live_home
  if (-not (Test-Path $liveHome)) {
    return [pscustomobject]@{ ok = $false; error = "live home missing" }
  }

  Ensure-DurableLayout $cfg
  Invoke-SqliteCheckpoint $liveHome

  $current = Join-Path $cfg.durable_root "state\current"
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $snapDir = Join-Path $cfg.durable_root "snapshots\$stamp"
  New-Item -ItemType Directory -Force -Path $current, $snapDir | Out-Null

  # Critical state files
  $patterns = @(
    "store.sqlite", "store.sqlite-wal", "store.sqlite-shm",
    "memory_corpus.json", "orchestration_corpus.json",
    "config.toml", "audit.jsonl", "MEMORY.md", "AGENTS.md", "SUPER_AGENTS.md",
    "agent_backend.json"
  )
  $copied = @()
  foreach ($name in $patterns) {
    $src = Join-Path $liveHome $name
    if (Test-Path $src) {
      Copy-Item -LiteralPath $src -Destination (Join-Path $current $name) -Force
      Copy-Item -LiteralPath $src -Destination (Join-Path $snapDir $name) -Force
      $copied += $name
    }
  }
  $agentsSrc = Join-Path $liveHome "agents"
  if (Test-Path $agentsSrc) {
    $null = robocopy $agentsSrc (Join-Path $current "agents") /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
    $null = robocopy $agentsSrc (Join-Path $snapDir "agents") /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
    $copied += "agents/"
  }

  # Also mirror into disk home for tools that still read ~/.forge-conductor directly
  foreach ($name in $patterns) {
    $src = Join-Path $current $name
    $dst = Join-Path $fc $name
    if (Test-Path $src) {
      try { Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue } catch { }
    }
  }

  # Rotate snapshots — keep last 20
  $allSnaps = Get-ChildItem (Join-Path $cfg.durable_root "snapshots") -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending
  $allSnaps | Select-Object -Skip 20 | ForEach-Object {
    try { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  }

  $st.last_snapshot = (Get-Date).ToUniversalTime().ToString("o")
  $st.last_snapshot_ok = $true
  $st.last_error = $null
  Write-RdState $st
  Write-RdLog ("snapshot ok files=[{0}] dir={1}" -f ($copied -join ","), $snapDir)

  # Also write pointer
  @{
    stamp = $stamp
    at = $st.last_snapshot
    files = $copied
    path = $snapDir
  } | ConvertTo-Json | Set-Content (Join-Path $cfg.durable_root "state\latest-snapshot.json") -Encoding utf8

  return [pscustomobject]@{
    ok = $true
    stamp = $stamp
    files = $copied
    snapshot_dir = $snapDir
    at = $st.last_snapshot
  }
}

function Test-IsProtectedPath([string]$full, [string]$liveHome) {
  $rel = $full.Substring($liveHome.Length).TrimStart('\', '/')
  $protected = @(
    '^store\.sqlite',
    '^memory_corpus\.json',
    '^orchestration_corpus\.json',
    '^config\.toml',
    '^agents($|\\)',
    '^bin($|\\)',
    '^scripts($|\\)',
    '^mcp-role($|\\)'
  )
  foreach ($p in $protected) {
    if ($rel -match $p) { return $true }
  }
  return $false
}

function Invoke-Tier($cfg) {
  $letter = [string]$cfg.letter
  if (-not (Test-VolumeMounted $letter)) {
    return [pscustomobject]@{ ok = $true; skipped = $true; reason = "not mounted" }
  }
  $vol = Get-VolumeStats $letter
  $needTier = ($vol.free_gb -lt [double]$cfg.tier_free_gb_threshold) -or ($vol.used_pct -ge [double]$cfg.tier_usage_pct_threshold)
  if (-not $needTier) {
    return [pscustomobject]@{ ok = $true; skipped = $true; reason = "below threshold"; volume = $vol }
  }

  $liveHome = $cfg.live_home
  $tierRoot = Join-Path $cfg.durable_root "tiered"
  $chunkTarget = [int64]([double]$cfg.tier_chunk_gb * 1GB)
  New-Item -ItemType Directory -Force -Path $tierRoot | Out-Null

  # Candidates: logs, cache, browser cache, old large files under home — oldest first
  $searchRoots = @(
    (Join-Path $liveHome "logs"),
    (Join-Path $liveHome "cache"),
    (Join-Path $liveHome "tier-candidates")
  ) | Where-Object { Test-Path $_ }

  $files = @()
  foreach ($root in $searchRoots) {
    $files += Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue
  }
  # Also any *.log / *.tmp older than 1h at home root
  $files += Get-ChildItem -LiteralPath $liveHome -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in @(".log", ".tmp", ".bak") -and $_.LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddHours(-1) }

  $ordered = $files |
    Where-Object { $_ -and -not (Test-IsProtectedPath $_.FullName $liveHome) } |
    Sort-Object LastWriteTimeUtc

  $movedBytes = [int64]0
  $movedFiles = @()
  $batchStamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $batchDir = Join-Path $tierRoot $batchStamp
  New-Item -ItemType Directory -Force -Path $batchDir | Out-Null

  foreach ($f in $ordered) {
    if ($movedBytes -ge $chunkTarget) { break }
    try {
      $rel = $f.FullName.Substring($liveHome.Length).TrimStart('\')
      $dest = Join-Path $batchDir $rel
      $destParent = Split-Path $dest -Parent
      New-Item -ItemType Directory -Force -Path $destParent | Out-Null
      Move-Item -LiteralPath $f.FullName -Destination $dest -Force
      $movedBytes += $f.Length
      $movedFiles += $rel
    } catch {
      Write-RdLog "tier skip $($f.FullName): $_"
    }
  }

  $st = Read-RdState
  $st.last_tier = (Get-Date).ToUniversalTime().ToString("o")
  Write-RdState $st
  $vol2 = Get-VolumeStats $letter
  Write-RdLog ("tier moved {0:N1} MB files={1} free_gb={2}" -f ($movedBytes / 1MB), $movedFiles.Count, $vol2.free_gb)

  return [pscustomobject]@{
    ok = $true
    skipped = $false
    moved_bytes = $movedBytes
    moved_mb = [math]::Round($movedBytes / 1MB, 1)
    moved_files = $movedFiles.Count
    batch = $batchDir
    volume = $vol2
  }
}

function Invoke-Destroy($cfg) {
  $letter = [string]$cfg.letter
  if (-not (Test-VolumeMounted $letter)) {
    Write-RdLog "destroy: ${letter}: not mounted — elevated cleanup orphans"
    try {
      $null = Invoke-ElevatedRamdiskOp -Action cleanup -Letter $letter -TimeoutSec 60
    } catch {
      Write-RdLog "cleanup warn: $_"
    }
    $st = Read-RdState
    $st.mounted = $false
    $st.destroyed_at = (Get-Date).ToUniversalTime().ToString("o")
    Write-RdState $st
    return [pscustomobject]@{ ok = $true; destroyed = $false; reason = "not mounted" }
  }
  Write-RdLog "destroy ${letter}: via elevated task"
  $resp = Invoke-ElevatedRamdiskOp -Action destroy -Letter $letter -TimeoutSec 90
  $still = Test-VolumeMounted $letter
  $st = Read-RdState
  $st.mounted = $still
  $st.destroyed_at = (Get-Date).ToUniversalTime().ToString("o")
  if ($still) { $st.last_error = "destroy incomplete" } else { $st.last_error = $null }
  Write-RdState $st
  if ($still) { throw "failed to destroy ${letter}: elevated=$($resp | ConvertTo-Json -Compress)" }
  Write-RdLog "destroy OK (elevated)"
  return [pscustomobject]@{ ok = $true; destroyed = $true; letter = $letter }
}

function Get-StatusObject($cfg) {
  $letter = [string]$cfg.letter
  $vol = Get-VolumeStats $letter
  $st = Read-RdState
  $imdiskOk = $false
  try { $null = Get-ImdiskExe; $imdiskOk = $true } catch { $imdiskOk = $false }
  return [pscustomobject]@{
    ok = $true
    provider = "imdisk"
    imdisk_installed = $imdiskOk
    letter = $letter
    mounted = [bool]$vol.mounted
    size_gb_config = [int]$cfg.size_gb
    size_gb_min = [int]$cfg.size_gb_min
    size_gb_max = [int]$cfg.size_gb_max
    volume = $vol
    live_app = $cfg.live_app
    live_home = $cfg.live_home
    durable_root = $cfg.durable_root
    last_snapshot = $st.last_snapshot
    last_snapshot_ok = $st.last_snapshot_ok
    last_tier = $st.last_tier
    image_built_at = $st.image_built_at
    created_at = $st.created_at
    last_error = $st.last_error
    snapshot_interval_sec = [int]$cfg.snapshot_interval_sec
    tier_chunk_gb = [double]$cfg.tier_chunk_gb
  }
}

# --- main ---
$cfg = Get-RdConfig

switch ($Action) {
  "config" {
    $cfg | ConvertTo-Json -Depth 8
    exit 0
  }
  "status" {
    Get-StatusObject $cfg | ConvertTo-Json -Depth 8
    exit 0
  }
  "ensure-image" {
    Invoke-EnsureImage $cfg | ConvertTo-Json -Depth 6
    exit 0
  }
  "create" {
    Invoke-CreateVolume $cfg | ConvertTo-Json -Depth 6
    exit 0
  }
  "hydrate" {
    Invoke-Hydrate $cfg | ConvertTo-Json -Depth 6
    exit 0
  }
  "snapshot" {
    Invoke-Snapshot $cfg -Blocking | ConvertTo-Json -Depth 6
    exit 0
  }
  "tier" {
    Invoke-Tier $cfg | ConvertTo-Json -Depth 6
    exit 0
  }
  "destroy" {
    Invoke-Destroy $cfg | ConvertTo-Json -Depth 6
    exit 0
  }
  "load" {
    # Full: create + hydrate (does not start keepers — forge-stack does)
    Write-RdLog "LOAD ramdisk begin size_gb=$($cfg.size_gb)"
    Ensure-DurableLayout $cfg
    Seed-DurableState $cfg
    $img = Invoke-EnsureImage $cfg
    $vol = Invoke-CreateVolume $cfg
    $hyd = Invoke-Hydrate $cfg
    $snap = Invoke-Snapshot $cfg -Blocking
    [pscustomobject]@{
      ok = $true
      action = "load"
      image = $img
      volume = $vol
      hydrate = $hyd
      snapshot = $snap
      status = Get-StatusObject $cfg
    } | ConvertTo-Json -Depth 10
    exit 0
  }
  "unload" {
    Write-RdLog "UNLOAD ramdisk begin"
    $snap = $null
    try { $snap = Invoke-Snapshot $cfg -Blocking } catch { Write-RdLog "final snapshot failed: $_" }
    $des = Invoke-Destroy $cfg
    [pscustomobject]@{
      ok = $true
      action = "unload"
      snapshot = $snap
      destroy = $des
      status = Get-StatusObject $cfg
    } | ConvertTo-Json -Depth 10
    exit 0
  }
}
