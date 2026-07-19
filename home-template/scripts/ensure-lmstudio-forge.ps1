#Requires -Version 5.1
<#
.SYNOPSIS
  Ensure LM Studio can toggle mcp/forge-conductor and connect without manual path surgery.

.DESCRIPTION
  Idempotent. Syncs:
    - home forge-serve.cmd launcher
    - ~/.lmstudio/mcp.json (forge-only)
    - MCP plugin bridge + install-state + last-synced-mcp-state
    - pinned plugin + forge tool auto-approve
    - UI selection / expanded list (drops ghost MCPs)
    - chat LLM model defaults → Forge Conductor Global system prompt
  Then probes stdio the same way LM Studio's mcpBridge does.

.EXAMPLE
  pwsh -File $env:USERPROFILE\.forge-conductor\scripts\ensure-lmstudio-forge.ps1
#>
param(
  [switch]$SkipProbe
)

$ErrorActionPreference = "Stop"
$failed = 0
function Pass($m) { Write-Host "[PASS] $m" -ForegroundColor Green }
function Fail($m) { $script:failed++; Write-Host "[FAIL] $m" -ForegroundColor Red }

Write-Host "=== ensure-lmstudio-forge ===" -ForegroundColor Cyan

$venvFc = $null
foreach ($cand in @(
  $env:FORGE_CONDUCTOR_EXE,
  "R:\app\.venv\Scripts\forge-conductor.exe",
  (Join-Path $env:USERPROFILE ".forge-conductor\.venv\Scripts\forge-conductor.exe"),
  (Get-Command forge-conductor -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
)) {
  if ($cand -and (Test-Path $cand)) { $venvFc = $cand; break }
}
if (-not $venvFc) {
  Fail "forge-conductor executable not found — set FORGE_CONDUCTOR_EXE or install the package"
  exit 2
}

# 1) install + register lmstudio (canonical)
& $venvFc install | Out-Host
& $venvFc register lmstudio | Out-Host

$launcher = Join-Path $env:USERPROFILE ".forge-conductor\bin\forge-serve.cmd"
if (Test-Path $launcher) { Pass "launcher $launcher" } else { Fail "launcher missing" }

$mcpPath = Join-Path $env:USERPROFILE ".lmstudio\mcp.json"
$mcp = Get-Content $mcpPath -Raw | ConvertFrom-Json
$keys = @($mcp.mcpServers.PSObject.Properties.Name)
# Charter: forge-family surface — RAM memory + primary (+ optional fallback)
$allowed = @('ram-memory', 'forge-conductor', 'forge-conductor-fallback')
$extra = @($keys | Where-Object { $_ -notin $allowed })
if ($keys -contains 'forge-conductor' -and $keys -contains 'ram-memory' -and $extra.Count -eq 0) {
  Pass "mcp.json forge-family ($($keys -join ', '))"
} elseif ($keys -contains 'forge-conductor' -and $extra.Count -eq 0) {
  Pass "mcp.json forge-only ($($keys -join ', ')) — re-run register for ram-memory toggle"
} else {
  Fail "mcp.json unexpected servers: $($keys -join ', ')"
}
$cmd = $mcp.mcpServers.'forge-conductor'.command
if (Test-Path $cmd) { Pass "serve command exists: $cmd" } else { Fail "serve command missing: $cmd" }

# 2) Python ensure block (pin, UI, models, bridge sync)
$py = $null
foreach ($cand in @(
  $env:FORGE_PYTHON,
  "R:\app\.venv\Scripts\python.exe",
  (Join-Path $env:USERPROFILE ".forge-conductor\.venv\Scripts\python.exe")
)) {
  if ($cand -and (Test-Path $cand)) { $py = $cand; break }
}
if (-not $py) {
  $cmd = Get-Command python -ErrorAction SilentlyContinue
  if ($cmd) { $py = $cmd.Source }
}
if (-not $py) {
  Fail "python not found — set FORGE_PYTHON"
  exit 2
}
& $py -c @"
import json, time
from pathlib import Path

home = Path.home()
prompt_path = home / '.forge-conductor' / 'scripts' / 'assets' / 'forge-system-prompt.txt'
if prompt_path.is_file():
    forge_system = prompt_path.read_text(encoding='utf-8').strip()
else:
    forge_system = (
        'You have one local orchestration MCP server: forge-conductor (stdio).\n'
        'Call session_bootstrap first every chat. Use project_focus and handoff_save for continuity.\n'
    )


# settings — pin RAM memory first (main MCP frame visibility)
settings_path = home / '.lmstudio' / 'settings.json'
s = json.loads(settings_path.read_text(encoding='utf-8'))
chat = s.setdefault('chat', {})
desired_pins = [
    'mcp/ram-memory',
    'mcp/forge-conductor',
    'mcp/forge-conductor-fallback',
]
rest = [p for p in (chat.get('pinnedPlugins') or []) if p not in desired_pins]
chat['pinnedPlugins'] = desired_pins + rest
skips = chat.get('skipToolConfirmationPatterns') or []
for pat in ('mcp/ram-memory:*', 'mcp/forge-conductor:*', 'mcp/forge-conductor-fallback:*'):
    if pat not in skips:
        skips.insert(0, pat)
chat['skipToolConfirmationPatterns'] = skips
settings_path.write_text(json.dumps(s, indent=2) + '\n', encoding='utf-8')

# ui
ui_path = home / '.lmstudio' / '.internal' / 'ui-state' / 'window-1.json'
if ui_path.is_file():
    ui = json.loads(ui_path.read_text(encoding='utf-8'))
    ui.setdefault('chat', {})['expandedSidebarPlugins'] = desired_pins
    ui.setdefault('plugins', {})['selectedPluginIdentifier'] = 'mcp/ram-memory'
    ui_path.write_text(json.dumps(ui, indent=2) + '\n', encoding='utf-8')

# model defaults (chat LLMs only)
root = home / '.lmstudio' / '.internal' / 'user-concrete-model-default-config'
for p in root.rglob('*.json'):
    if '.bak' in p.name or 'FLUX' in str(p) or 'flux' in p.name.lower():
        continue
    data = json.loads(p.read_text(encoding='utf-8'))
    if 'preset' not in data and 'operation' not in data:
        continue
    data['preset'] = '@local:forge-conductor-global'
    op = data.setdefault('operation', {})
    fields = op.setdefault('fields', [])
    by_key = {f.get('key'): f for f in fields if isinstance(f, dict)}
    def upsert(key, value):
        if key in by_key:
            by_key[key]['value'] = value
        else:
            fields.append({'key': key, 'value': value})
            by_key[key] = fields[-1]
    upsert('llm.prediction.systemPrompt', forge_system)
    p.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')

# plugin bridge sync from mcp.json
mcp = json.loads((home / '.lmstudio' / 'mcp.json').read_text(encoding='utf-8'))
block = mcp['mcpServers']['forge-conductor']
plugin_dir = home / '.lmstudio' / 'extensions' / 'plugins' / 'mcp' / 'forge-conductor'
plugin_dir.mkdir(parents=True, exist_ok=True)
(plugin_dir / 'manifest.json').write_text(json.dumps({
    'type': 'plugin', 'runner': 'mcpBridge', 'owner': 'mcp', 'name': 'forge-conductor'
}, indent=2) + '\n', encoding='utf-8')
(plugin_dir / 'mcp-bridge-config.json').write_text(json.dumps(block, indent=2) + '\n', encoding='utf-8')
(plugin_dir / 'install-state.json').write_text(json.dumps({
    'by': 'mcp-bridge-v1', 'at': int(time.time() * 1000)
}) + '\n', encoding='utf-8')
(home / '.lmstudio' / '.internal' / 'last-synced-mcp-state.json').write_text(
    json.dumps(mcp, indent=2) + '\n', encoding='utf-8')
print('ensure python block ok')
"@
if ($LASTEXITCODE -ne 0) { Fail "python ensure block failed"; exit 1 }
Pass "settings/UI/models/bridge synced"

# 3) Verify plugin bridge matches mcp.json
$bridge = Get-Content (Join-Path $env:USERPROFILE ".lmstudio\extensions\plugins\mcp\forge-conductor\mcp-bridge-config.json") -Raw | ConvertFrom-Json
if ($bridge.command -eq $cmd) { Pass "plugin bridge command matches mcp.json" } else { Fail "bridge/mcp command mismatch" }

# 4) MCP probe (same protocol LM Studio uses)
if (-not $SkipProbe) {
  $probe = Join-Path $env:USERPROFILE ".forge-conductor\scripts\probe-mcp.ps1"
  & pwsh -NoProfile -File $probe
  if ($LASTEXITCODE -eq 0) { Pass "stdio probe (initialize + tools/list + forge_status)" }
  else { Fail "stdio probe failed" }
}

Write-Host ""
Write-Host "=== USER WORKFLOW (after restart) ===" -ForegroundColor Cyan
Write-Host "1. Start LM Studio"
Write-Host "2. Load any chat model (defaults include Forge system prompt)"
Write-Host "3. Open chat Integrations / Plugins / Tools"
Write-Host "4. Toggle ON: mcp/forge-conductor (pinned)"
Write-Host "5. Send: Call forge_status and report version and tool_count"
Write-Host "   LM Studio spawns forge-serve.cmd automatically — no path typing."
Write-Host ""
Write-Host "Long context (262k): keep Offload KV Cache to GPU = OFF (see load-qwen-longctx.ps1)"
Write-Host ""

if ($failed -gt 0) {
  Write-Host "ENSURE FAILED ($failed)" -ForegroundColor Red
  exit 1
}
Write-Host "ENSURE OK — restart LM Studio and toggle Forge-Conductor" -ForegroundColor Green
exit 0
