#Requires -Version 5.1
<#
.SYNOPSIS
  Start Forge Rig Telemetry (foreground). Prefer install-task.ps1 for always-on.

.EXAMPLE
  pwsh -File $env:USERPROFILE\.forge-conductor\telemetry\run.ps1
#>
param(
  [string]$HostAddr = "0.0.0.0",
  [int]$Port = 7788,
  [double]$Interval = 2.0,
  [switch]$Supervised
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($Supervised) {
  & "$here\supervise.ps1" -HostAddr $HostAddr -Port $Port -Interval $Interval
  exit $LASTEXITCODE
}

$ErrorActionPreference = "Stop"
Set-Location $here
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
  Write-Host "Node.js not found on PATH." -ForegroundColor Red
  exit 1
}
if (-not (Test-Path "$here\node_modules\express")) {
  npm install --omit=dev
}
$env:TELEMETRY_HOST = $HostAddr
$env:TELEMETRY_PORT = "$Port"
$env:TELEMETRY_INTERVAL = "$Interval"
Write-Host "Open http://${HostAddr}:${Port}/"
node "$here\server.js"
