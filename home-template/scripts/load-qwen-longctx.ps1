#Requires -Version 5.1
<#
.SYNOPSIS
  Load Qwen with MAX long context (default 262144). Prefer load-qwen-balanced.ps1 for daily speed.

.DESCRIPTION
  Evidence (2026-07-16):
  - KV cache ON GPU + 262k => ~23.9 GiB VRAM (almost full) => engine death under tools
  - KV cache OFF GPU + 262k => ~18.8 GiB VRAM, ~32 GiB system RAM => tools + long prompts work

  This script unloads prior models, loads with:
    - context 262144 (override with -ContextLength)
    - GPU offload max
    - parallel 1
  and verifies offline MCP + short completion.

.EXAMPLE
  pwsh -File $env:USERPROFILE\.forge-conductor\scripts\load-qwen-longctx.ps1
#>
param(
  [string]$Model = "qwen/qwen3.6-27b",
  [int]$ContextLength = 262144,
  [ValidateSet("max","off","0.5","0.75","1")]
  [string]$Gpu = "max",
  [int]$Parallel = 1,
  # 0 = auto: all logical processors (this rig: 16c/32t Ryzen 9 5950X)
  [int]$CpuThreads = 0,
  [switch]$SkipProbe,
  [switch]$SkipCompletion
)

if ($CpuThreads -le 0) {
  $CpuThreads = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
}
if ($CpuThreads -lt 1) { $CpuThreads = 32 }

$ErrorActionPreference = "Stop"

function Get-VramMiB {
  [int]((nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits).Trim())
}
function Get-FreeRamGB {
  [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 2)
}

# Persist CPU thread pool into model defaults (LM Studio reads on load)
$cfgPath = Join-Path $env:USERPROFILE ".lmstudio\.internal\user-concrete-model-default-config\qwen\qwen3.6-27b.json"
if (Test-Path $cfgPath) {
  try {
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $fields = @($cfg.load.fields)
    $found = $false
    foreach ($f in $fields) {
      if ($f.key -eq "llm.load.llama.cpuThreadPoolSize") {
        $f.value = $CpuThreads
        $found = $true
      }
      if ($f.key -eq "llm.load.contextLength") { $f.value = $ContextLength }
      if ($f.key -eq "llm.load.offloadKVCacheToGpu") { $f.value = $false }
      if ($f.key -eq "llm.load.llama.keepModelInMemory") { $f.value = $true }
      if ($f.key -eq "llm.load.llama.tryMmap") { $f.value = $true }
      if ($f.key -eq "llm.load.useUnifiedKvCache") { $f.value = $true }
      if ($f.key -eq "llm.load.llama.flashAttention") { $f.value = $true }
    }
    if (-not $found) {
      $cfg.load.fields += [pscustomobject]@{ key = "llm.load.llama.cpuThreadPoolSize"; value = $CpuThreads }
    }
    $cfg | ConvertTo-Json -Depth 20 | Set-Content $cfgPath -Encoding utf8
    Write-Host "Updated model defaults: cpuThreads=$CpuThreads context=$ContextLength KV_GPU=off keepInMem=mmap=on"
  } catch {
    Write-Host "WARN: could not patch model defaults: $_" -ForegroundColor Yellow
  }
}

Write-Host "=== load-qwen-longctx (max RAM KV + full CPU) ===" -ForegroundColor Cyan
Write-Host "Model=$Model Context=$ContextLength Gpu=$Gpu Parallel=$Parallel CpuThreads=$CpuThreads"
Write-Host "KV cache uses SYSTEM RAM (not VRAM) — this is how we put 128GB to work for long context."

if (-not $SkipProbe) {
  Write-Host "`n[1/4] MCP probe..." -ForegroundColor Cyan
  & pwsh -NoProfile -File (Join-Path $env:USERPROFILE ".forge-conductor\scripts\probe-mcp.ps1")
  if ($LASTEXITCODE -ne 0) { throw "MCP probe failed; aborting load" }
}

Write-Host "`n[2/4] Unload existing models..." -ForegroundColor Cyan
lms unload --all 2>$null | Out-Host
Start-Sleep -Seconds 2

$ram0 = Get-FreeRamGB
$vram0 = Get-VramMiB
Write-Host "PRE freeRAM_GB=$ram0 vram_MiB=$vram0"

Write-Host "`n[3/4] Loading..." -ForegroundColor Cyan
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& lms load $Model -c $ContextLength --gpu $Gpu --parallel $Parallel -y
if ($LASTEXITCODE -ne 0) { throw "lms load failed" }
$sw.Stop()
Write-Host "load_sec=$([math]::Round($sw.Elapsed.TotalSeconds,2))"

lms ps | Out-Host
$ram1 = Get-FreeRamGB
$vram1 = Get-VramMiB
$ramDelta = [math]::Round($ram0 - $ram1, 2)
$vramDelta = $vram1 - $vram0
Write-Host "POST freeRAM_GB=$ram1 ram_used_delta_GB=$ramDelta vram_MiB=$vram1 vram_delta=$vramDelta"

# Guardrails from measured healthy band (~18–20 GiB VRAM at 262k with KV on system RAM)
if ($vram1 -gt 22000) {
  Write-Host "WARN: VRAM > 22000 MiB. Confirm UI: Offload KV Cache to GPU = OFF, Parallel = 1." -ForegroundColor Yellow
} else {
  Write-Host "VRAM headroom looks healthy for tool/agent work." -ForegroundColor Green
}

if (-not $SkipCompletion) {
  Write-Host "`n[4/4] Short completion smoke..." -ForegroundColor Cyan
  $body = @{
    model = $Model
    messages = @(@{ role = "user"; content = "Reply with exactly PONG" })
    max_tokens = 64
    temperature = 0
  } | ConvertTo-Json -Depth 5
  $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $resp = Invoke-RestMethod -Uri "http://127.0.0.1:1234/v1/chat/completions" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 300
    $sw2.Stop()
    $content = $resp.choices[0].message.content
    Write-Host "completion_sec=$([math]::Round($sw2.Elapsed.TotalSeconds,2)) content=[$content] usage=$($resp.usage | ConvertTo-Json -Compress)"
  } catch {
    $sw2.Stop()
    Write-Host "completion failed after $($sw2.Elapsed.TotalSeconds)s : $_" -ForegroundColor Red
    exit 2
  }
}

Write-Host "`nDONE. In LM Studio chat: Forge preset, tools on, only forge-conductor plugin." -ForegroundColor Green
Write-Host "If UI reloads model, re-check Offload KV Cache to GPU = OFF and context stays $ContextLength."
