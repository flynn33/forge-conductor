#Requires -Version 5.1
<#
.SYNOPSIS
  Install Windows Scheduled Task: ForgeRigTelemetry
  - Starts at user logon
  - Runs supervise.ps1 (auto-restart on crash)
  - Restarts task if it fails
#>
param(
  [string]$TaskName = "ForgeRigTelemetry",
  [switch]$StartNow
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$supervise = Join-Path $here "supervise.ps1"
if (-not (Test-Path $supervise)) { throw "Missing $supervise" }

$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwshCmd) { $pwshCmd = Get-Command powershell -ErrorAction SilentlyContinue }
if (-not $pwshCmd) { throw "PowerShell not found" }
$pwsh = $pwshCmd.Source

# Unregister old task if present
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$supervise`""
$action = New-ScheduledTaskAction -Execute $pwsh -Argument $arg -WorkingDirectory $here

# At logon for current user (interactive session — GPU/nvidia-smi available)
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

# Also try at startup (may run before user env; logon is primary)
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -RestartCount 999 `
  -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit ([TimeSpan]::Zero) `
  -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal `
  -UserId $env:USERNAME `
  -LogonType Interactive `
  -RunLevel Limited

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger $triggerLogon `
  -Settings $settings `
  -Principal $principal `
  -Description "Forge Rig Telemetry dashboard (Node, 127.0.0.1:7788). Auto-restart via supervise.ps1." `
  -Force | Out-Null

Write-Host "Installed scheduled task: $TaskName"
Write-Host "  Trigger : At logon ($env:USERNAME)"
Write-Host "  Action  : $pwsh $arg"
Write-Host "  URL     : http://127.0.0.1:7788/  (LAN: http://<this-pc-ip>:7788/)"
Write-Host "  Restart : supervise loop + Task Scheduler RestartCount=999"

if ($StartNow) {
  Start-ScheduledTask -TaskName $TaskName
  Write-Host "Started task now."
  Start-Sleep -Seconds 2
  Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo | Format-List LastRunTime, LastTaskResult, NextRunTime
}
