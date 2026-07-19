#Requires -Version 5.1
<#
.SYNOPSIS
  Notify LM Studio of Forge agent_backend mode change (HOST|GROK).

  Updates system prompt assets, Forge Global preset, model defaults,
  and ~/.lmstudio/.internal/forge-agent-backend-notify.json

.PARAMETER ForgeHome
  Forge home (live RAM home or disk home). Defaults to ~/.forge-conductor
#>
param(
  [string]$ForgeHome = ""
)

$ErrorActionPreference = "Stop"
if (-not $ForgeHome) { $ForgeHome = Join-Path $env:USERPROFILE ".forge-conductor" }
$diskHome = Join-Path $env:USERPROFILE ".forge-conductor"
$logDir = Join-Path $diskHome "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir "lmstudio-notify.log"

function Write-NotifyLog([string]$m) {
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m
  Add-Content -Path $log -Value $line -Encoding utf8
  Write-Host $line
}

$statePath = Join-Path $ForgeHome "agent_backend.json"
if (-not (Test-Path $statePath)) {
  $statePath = Join-Path $diskHome "agent_backend.json"
}
if (-not (Test-Path $statePath)) {
  Write-NotifyLog "FAIL no agent_backend.json"
  exit 1
}

$st = Get-Content $statePath -Raw | ConvertFrom-Json
$mode = [string]$st.mode
if ($mode -notin @("host", "grok")) { $mode = "host" }
$gen = [int]($st.generation)
Write-NotifyLog "notify mode=$mode generation=$gen home=$ForgeHome"

# --- assets ---
$assets = Join-Path $diskHome "scripts\assets"
$hostPrompt = Join-Path $assets "forge-system-prompt.host.txt"
$grokPrompt = Join-Path $assets "forge-system-prompt.grok.txt"
$outPrompt = Join-Path $assets "forge-system-prompt.txt"
$src = if ($mode -eq "grok" -and (Test-Path $grokPrompt)) { $grokPrompt } else { $hostPrompt }
if (-not (Test-Path $src)) {
  Write-NotifyLog "FAIL missing prompt template $src"
  exit 1
}
$text = (Get-Content $src -Raw -Encoding utf8) -replace '\{generation\}', "$gen"
Set-Content -Path $outPrompt -Value $text -Encoding utf8
Write-NotifyLog "wrote $outPrompt"

# sidecar mode files
$lmForge = Join-Path $diskHome "lmstudio"
New-Item -ItemType Directory -Force -Path $lmForge | Out-Null
Set-Content (Join-Path $lmForge "agent-backend-mode.txt") $mode -Encoding utf8
Set-Content (Join-Path $lmForge "generation.txt") "$gen" -Encoding utf8

# LM Studio notify json
$lmInternal = Join-Path $env:USERPROFILE ".lmstudio\.internal"
New-Item -ItemType Directory -Force -Path $lmInternal | Out-Null
$notifyObj = [ordered]@{
  mode       = $mode
  generation = $gen
  ts         = (Get-Date).ToUniversalTime().ToString("o")
  policy     = if ($mode -eq "grok") { "MANDATORY_OFFLOAD" } else { "HOST_EXECUTES_AGENTS" }
  source     = "notify-lmstudio-agent-backend.ps1"
  message    = if ($mode -eq "grok") {
    "Open a NEW chat. Local model is router only; use agent_run_start."
  } else {
    "Open a NEW chat. Local model executes agent playbooks."
  }
}
($notifyObj | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $lmInternal "forge-agent-backend-notify.json") -Encoding utf8

# Patch Forge Conductor Global preset
$presetPath = Join-Path $env:USERPROFILE ".lmstudio\config-presets\Forge Conductor Global.preset.json"
if (Test-Path $presetPath) {
  try {
    $preset = Get-Content $presetPath -Raw -Encoding utf8 | ConvertFrom-Json
    $fields = @($preset.operation.fields)
    $found = $false
    foreach ($f in $fields) {
      if ($f.key -eq "llm.prediction.systemPrompt") {
        $f.value = $text
        $found = $true
      }
    }
    if (-not $found) {
      $preset.operation.fields += [pscustomobject]@{ key = "llm.prediction.systemPrompt"; value = $text }
    }
    ($preset | ConvertTo-Json -Depth 30) | Set-Content $presetPath -Encoding utf8
    Write-NotifyLog "patched preset $presetPath"
  } catch {
    Write-NotifyLog "WARN preset patch: $_"
  }
}

# Dual preset copy for Grok Offload
$grokPresetPath = Join-Path $env:USERPROFILE ".lmstudio\config-presets\Forge Conductor Grok Offload.preset.json"
try {
  $gp = [ordered]@{
    identifier = "@local:forge-conductor-grok-offload"
    name       = "Forge Conductor (Grok Offload)"
    changed    = $false
    operation  = @{
      fields = @(
        @{ key = "llm.prediction.temperature"; value = 0.2 }
        @{ key = "llm.prediction.systemPrompt"; value = $text }
      )
    }
    load = @{ fields = @() }
  }
  if ($mode -eq "grok") {
    ($gp | ConvertTo-Json -Depth 20) | Set-Content $grokPresetPath -Encoding utf8
    Write-NotifyLog "wrote $grokPresetPath"
  }
} catch {
  Write-NotifyLog "WARN grok preset: $_"
}

# Patch chat model defaults (same approach as ensure-lmstudio-forge)
$root = Join-Path $env:USERPROFILE ".lmstudio\.internal\user-concrete-model-default-config"
if (Test-Path $root) {
  $n = 0
  Get-ChildItem $root -Recurse -Filter "*.json" | Where-Object {
    $_.Name -notmatch '\.bak' -and $_.FullName -notmatch 'flux|FLUX'
  } | ForEach-Object {
    try {
      $data = Get-Content $_.FullName -Raw -Encoding utf8 | ConvertFrom-Json
      if ($null -eq $data.operation -and $null -eq $data.preset) { return }
      if ($mode -eq "grok") {
        $data.preset = "@local:forge-conductor-grok-offload"
      } else {
        $data.preset = "@local:forge-conductor-global"
      }
      if (-not $data.operation) {
        $data | Add-Member -NotePropertyName operation -NotePropertyValue ([pscustomobject]@{ fields = @() }) -Force
      }
      $fields = @($data.operation.fields)
      $found = $false
      $newFields = @()
      foreach ($f in $fields) {
        if ($f.key -eq "llm.prediction.systemPrompt") {
          $f.value = $text
          $found = $true
        }
        $newFields += $f
      }
      if (-not $found) {
        $newFields += [pscustomobject]@{ key = "llm.prediction.systemPrompt"; value = $text }
      }
      $data.operation.fields = $newFields
      ($data | ConvertTo-Json -Depth 40) | Set-Content $_.FullName -Encoding utf8
      $n++
    } catch {
      Write-NotifyLog "WARN model default $($_.Name): $_"
    }
  }
  Write-NotifyLog "patched $n model default files"
}

# Update agent_backend notify stamp on disk home copy
try {
  $diskStatePath = Join-Path $diskHome "agent_backend.json"
  if (Test-Path $diskStatePath) {
    $ds = Get-Content $diskStatePath -Raw | ConvertFrom-Json
    if (-not $ds.notify) {
      $ds | Add-Member -NotePropertyName notify -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $ds.notify | Add-Member -NotePropertyName lmstudio_synced_generation -NotePropertyValue $gen -Force
    $ds.notify | Add-Member -NotePropertyName lmstudio_last_error -NotePropertyValue $null -Force
    ($ds | ConvertTo-Json -Depth 10) | Set-Content $diskStatePath -Encoding utf8
  }
} catch {
  Write-NotifyLog "WARN stamp: $_"
}

Write-NotifyLog "NOTIFY OK mode=$mode gen=$gen"
Write-Host '{"ok":true,"mode":"' $mode '","generation":' $gen '}'
exit 0
