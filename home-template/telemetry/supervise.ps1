#Requires -Version 5.1
<#
.SYNOPSIS
  Keep Forge Rig Telemetry (Node) running. Auto-restart on crash/exit.

  Used by Windows Scheduled Task "ForgeRigTelemetry".
#>
param(
  # 0.0.0.0 = all interfaces (LAN). Use 127.0.0.1 for local-only.
  [string]$HostAddr = "0.0.0.0",
  [int]$Port = 7788,
  [double]$Interval = 2.0,
  [int]$RestartDelaySec = 3
)

$ErrorActionPreference = "Continue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$logDir = Join-Path $here "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "supervise.log"

function Write-Log([string]$msg) {
  $line = "{0:u}  {1}" -f (Get-Date).ToUniversalTime(), $msg
  Add-Content -Path $logFile -Value $line -Encoding utf8
  Write-Host $line
}

function Get-NodeExe {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $fallback = "C:\Program Files\nodejs\node.exe"
  if (Test-Path $fallback) { return $fallback }
  return $null
}

function Stop-PortHolders([int]$p) {
  try {
    $conns = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
    foreach ($c in $conns) {
      $procId = $c.OwningProcess
      if ($procId -and $procId -gt 0) {
        Write-Log "killing pid $procId holding port $p"
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
      }
    }
  } catch { }
}

$node = Get-NodeExe
if (-not $node) {
  Write-Log "FATAL: node.exe not found"
  exit 1
}

if (-not (Test-Path (Join-Path $here "node_modules\express"))) {
  Write-Log "npm install..."
  Push-Location $here
  & npm install --omit=dev 2>&1 | Out-File (Join-Path $logDir "npm-install.log") -Encoding utf8
  Pop-Location
}

$env:TELEMETRY_HOST = $HostAddr
$env:TELEMETRY_PORT = "$Port"
$env:TELEMETRY_INTERVAL = "$Interval"

Write-Log "supervise start node=$node port=$Port home=$here"

while ($true) {
  Stop-PortHolders -p $Port
  Start-Sleep -Milliseconds 400

  $outLog = Join-Path $logDir "server.out.log"
  $errLog = Join-Path $logDir "server.err.log"
  Write-Log "starting server.js"

  $p = Start-Process -FilePath $node `
    -ArgumentList @("server.js") `
    -WorkingDirectory $here `
    -PassThru `
    -WindowStyle Hidden `
    -RedirectStandardOutput $outLog `
    -RedirectStandardError $errLog

  Write-Log "server pid=$($p.Id)"
  Wait-Process -Id $p.Id
  $code = $p.ExitCode
  Write-Log "server exited code=$code — restart in ${RestartDelaySec}s"
  Start-Sleep -Seconds $RestartDelaySec
}
