#Requires -Version 5.1
<#
.SYNOPSIS
  Register elevated scheduled task so dashboard LOAD can create/destroy ImDisk without UAC.
#>
param([switch]$StartProbe)

$ErrorActionPreference = "Stop"
$taskName = "ForgeRamdiskElevated"
$script = Join-Path $env:USERPROFILE ".forge-conductor\scripts\forge-ramdisk-elevated-ops.ps1"
if (-not (Test-Path $script)) {
  throw "missing $script"
}

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }

# Action: receive -OpsFile path via env or argument file
$arg = "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -OpsFile `"$env:USERPROFILE\.forge-conductor\logs\ramdisk-ops-request.json`""

$action = New-ScheduledTaskAction -Execute $pwsh -Argument $arg
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Registered task $taskName (RunLevel Highest) as $env:USERNAME"
if ($StartProbe) {
  Write-Host "Probe: writing status ops..."
  $req = @{
    action = "status"
    letter = "R"
    size_gb = 16
    label = "FORGE-RAM"
    request_id = [guid]::NewGuid().ToString()
  }
  $reqPath = Join-Path $env:USERPROFILE ".forge-conductor\logs\ramdisk-ops-request.json"
  $respPath = Join-Path $env:USERPROFILE ".forge-conductor\logs\ramdisk-ops-response.json"
  New-Item -ItemType Directory -Force -Path (Split-Path $reqPath) | Out-Null
  if (Test-Path $respPath) { Remove-Item $respPath -Force }
  ($req | ConvertTo-Json) | Set-Content $reqPath -Encoding utf8
  Start-ScheduledTask -TaskName $taskName
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline -and -not (Test-Path $respPath)) { Start-Sleep -Milliseconds 200 }
  if (Test-Path $respPath) { Get-Content $respPath -Raw } else { Write-Host "PROBE TIMEOUT" }
}
