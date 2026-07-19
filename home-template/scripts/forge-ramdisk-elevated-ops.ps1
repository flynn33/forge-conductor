#Requires -Version 5.1
<#
.SYNOPSIS
  Elevated ImDisk ops runner (called by scheduled task ForgeRamdiskElevated).

  Reads ops request JSON, writes response JSON.
#>
param(
  [string]$OpsFile = ""
)

$ErrorActionPreference = "Continue"
$diskHome = Join-Path $env:USERPROFILE ".forge-conductor"
$logDir = Join-Path $diskHome "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir "ramdisk-elevated.log"

function Write-El([string]$m) {
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m
  Add-Content -Path $log -Value $line -Encoding utf8
}

if (-not $OpsFile) {
  $OpsFile = Join-Path $logDir "ramdisk-ops-request.json"
}
$respFile = Join-Path $logDir "ramdisk-ops-response.json"

function Write-Resp($obj) {
  ($obj | ConvertTo-Json -Depth 8) | Set-Content -Path $respFile -Encoding utf8
}

try {
  if (-not (Test-Path $OpsFile)) {
    Write-Resp @{ ok = $false; error = "missing ops file $OpsFile" }
    exit 1
  }
  $req = Get-Content $OpsFile -Raw | ConvertFrom-Json
  $action = [string]$req.action
  $letter = [string]($req.letter)
  if (-not $letter) { $letter = "R" }
  $sizeGb = [int]($req.size_gb)
  if ($sizeGb -lt 1) { $sizeGb = 16 }
  $label = [string]($req.label)
  if (-not $label) { $label = "FORGE-RAM" }
  $imdisk = "C:\Windows\System32\imdisk.exe"
  if (-not (Test-Path $imdisk)) { $imdisk = "imdisk" }

  Write-El "ops action=$action letter=$letter size=${sizeGb}G"

  function Clear-Orphans {
    # Remove mount letter first
    & $imdisk -D -m "${letter}:" 2>&1 | ForEach-Object { Write-El "cleanup letter: $_" }
    & $imdisk -d -m "${letter}:" 2>&1 | ForEach-Object { Write-El "cleanup letter d: $_" }
    # Remove units 0-15
    foreach ($u in 0..15) {
      $o = & $imdisk -D -u $u 2>&1
      if ($LASTEXITCODE -eq 0) { Write-El "removed unit $u" }
    }
    Start-Sleep -Milliseconds 500
  }

  switch ($action) {
    "status" {
      $mounted = Test-Path "${letter}:\"
      Write-Resp @{
        ok = $true
        action = "status"
        letter = $letter
        mounted = $mounted
        elevated = $true
        admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
      }
    }
    "cleanup" {
      Clear-Orphans
      Write-Resp @{ ok = $true; action = "cleanup"; mounted = (Test-Path "${letter}:\") }
    }
    "create" {
      Clear-Orphans
      if (Test-Path "${letter}:\") {
        Write-Resp @{ ok = $true; action = "create"; reused = $true; mounted = $true; letter = $letter }
        break
      }
      $sizeArg = "${sizeGb}G"
      Write-El "imdisk create $sizeArg -> ${letter}:"
      $out = & $imdisk -a -s $sizeArg -m "${letter}:" -p "/fs:ntfs /q /y /v:$label" 2>&1
      $code = $LASTEXITCODE
      foreach ($line in @($out)) { Write-El "imdisk: $line" }
      $deadline = (Get-Date).AddSeconds(90)
      $mounted = $false
      while ((Get-Date) -lt $deadline) {
        if (Test-Path "${letter}:\") { $mounted = $true; break }
        Start-Sleep -Milliseconds 400
      }
      if (-not $mounted) {
        Write-Resp @{
          ok = $false
          action = "create"
          error = "timeout waiting for ${letter}: after create"
          imdisk_exit = $code
          imdisk_out = ($out | Out-String)
        }
        exit 2
      }
      Write-Resp @{
        ok = $true
        action = "create"
        mounted = $true
        letter = $letter
        size_gb = $sizeGb
        imdisk_exit = $code
      }
    }
    "destroy" {
      Write-El "destroy ${letter}:"
      & $imdisk -D -m "${letter}:" 2>&1 | ForEach-Object { Write-El "$_" }
      Start-Sleep -Milliseconds 400
      if (Test-Path "${letter}:\") {
        & $imdisk -d -m "${letter}:" 2>&1 | ForEach-Object { Write-El "$_" }
      }
      Clear-Orphans
      $still = Test-Path "${letter}:\"
      Write-Resp @{
        ok = (-not $still)
        action = "destroy"
        mounted = $still
        letter = $letter
      }
      if ($still) { exit 3 }
    }
    default {
      Write-Resp @{ ok = $false; error = "unknown action $action" }
      exit 1
    }
  }
  Write-El "ops done ok"
  exit 0
} catch {
  Write-El "ops FAIL $_"
  Write-Resp @{ ok = $false; error = "$_" }
  exit 1
}
