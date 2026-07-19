#Requires -Version 5.1
<#
.SYNOPSIS
  Open Forge Rig dashboard (light control node). Does NOT load the stack.

  Desktop shortcut target. Ensures telemetry is up, then opens the browser.
  User clicks LOAD on the page to bring the full RAM orchestration layer online.
#>
$ErrorActionPreference = "Stop"
$fc = Join-Path $env:USERPROFILE ".forge-conductor"
$tel = Join-Path $fc "telemetry"
$url = "http://127.0.0.1:7788/"

function Test-Dashboard {
  try {
    $r = Invoke-WebRequest -Uri "$url`api/health" -UseBasicParsing -TimeoutSec 2
    return $r.StatusCode -eq 200
  } catch {
    return $false
  }
}

if (-not (Test-Dashboard)) {
  $run = Join-Path $tel "run.ps1"
  if (Test-Path $run) {
    Start-Process -FilePath "pwsh" -ArgumentList @(
      "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
      "-File", $run
    ) -WindowStyle Hidden | Out-Null
  } else {
    # fallback: node directly
    $node = (Get-Command node -ErrorAction SilentlyContinue).Source
    if ($node) {
      Start-Process -FilePath $node -ArgumentList @("server.js") -WorkingDirectory $tel -WindowStyle Hidden | Out-Null
    }
  }
  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $deadline -and -not (Test-Dashboard)) {
    Start-Sleep -Milliseconds 400
  }
}

Start-Process $url
