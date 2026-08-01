# Forge Conductor ↔ LM Studio (evidence-based)

This document is derived from **this Xcode project’s source** and **on-disk / runtime checks**, not from the retired Python stack.

## What the product is

| Component | Role |
|-----------|------|
| **LM Studio** | MCP **host** (spawns stdio servers, routes tool calls from local models) |
| **Forge Conductor Swift app (GUI)** | Rig / manager / installer UI. With no argv → SwiftUI. |
| **App binary `…/Forge Conductor serve`** | Same MCP server over stdin/stdout (`ForgeProcessEntry` → `MCPServer.swift`) — **only after that build includes `ForgeProcessEntry`** |
| **CLI `forge-conductor serve`** | Same MCP server (default registration target) |

There is **no** in-process link from the GUI into LM Studio’s address space.
There is **no** LM Studio SDK client inside Core for chat/completions.

### Process entry (one binary, three modes)

| Argv | Mode |
|------|------|
| _(none)_ | GUI |
| `serve` / `mcp` / `mcp-serve` | Stdio MCP (`ForgeProcessEntry` → `MCPServer`) |
| `manager run [--home …] [--open]` | Dashboard manager (LaunchAgent path) |

## Authoritative connection path (stable)

**Primary (official LM Studio mechanism):** `~/.lmstudio/mcp.json`

**Operational registration (both roles use the same selected, smoke-tested binary):**

```json
{
  "mcpServers": {
    "forge-conductor": {
      "command": "/path/to/the/selected/forge-conductor-or-app-binary",
      "args": ["serve"],
      "env": {
        "FORGE_MCP_ROLE": "primary",
        "FORGE_CONDUCTOR_HOME": "/Users/<you>/.forge-conductor",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/Users/<you>/.forge-conductor/bin"
      }
    },
    "forge-conductor-fallback": {
      "command": "/path/to/the/selected/forge-conductor-or-app-binary",
      "args": ["serve"],
      "env": {
        "FORGE_MCP_ROLE": "fallback",
        "FORGE_CONDUCTOR_HOME": "/Users/<you>/.forge-conductor",
        "PATH": "…"
      }
    }
  }
}
```

The CLI normally resolves the installed CLI executable. The GUI deliberately supplies its own app executable. Primary and fallback never mix versions within one deployment.

**Ship path (when deliberately registering an installed app):**

```bash
forge-conductor install-lmstudio-plugin \
  --binary "$HOME/.forge-conductor/Forge Conductor.app/Contents/MacOS/Forge Conductor"
```

Only do this after the **shipped** app binary responds to `serve` with MCP initialize (smoke below).
Do **not** point LM Studio at an older GUI-only `/Applications/Forge Conductor.app` — it ignores `serve`, opens UI, and LM Studio reports a ~60s plugin timeout.

LaunchAgent already uses the app as: `manager run --home …` (unrelated to MCP spawn).

**Secondary (lockstep mirror on this Mac):**
`~/.lmstudio/extensions/plugins/mcp/<name>/` with `runner: "mcpBridge"`.
Same command/args/env as `mcp.json`. Observed working layout for `project-continuity` and used by LM Studio’s `PluginProcess(mcp/…)` logs.

Source of truth in code:

| Concern | Source file |
|---------|-------------|
| Stdio MCP protocol + unbuffered stdout | `Sources/ForgeConductorCore/MCP/MCPServer.swift` |
| SQLite multi-process wait | `Sources/ForgeConductorCore/Infrastructure/SQLiteStore.swift` (`busy_timeout=3000`) |
| CLI entry `serve` | `Sources/ForgeConductorCLI/ForgeConductorMain.swift` |
| App entry `serve` / `manager run` | `Sources/ForgeConductorCore/Application/ForgeProcessEntry.swift` |
| Typed connector role / aggregate health | `Sources/ForgeConductorCore/Domain/LMStudioConnector.swift` |
| `mcp.json` parse/merge/write | `Sources/ForgeConductorCore/Telemetry/LMStudioEnvironment.swift` |
| Transactional mcpBridge plugin deployment | `Sources/ForgeConductorCore/Telemetry/LMStudioMCPPluginInstaller.swift` |
| Pre/post deployment health and promotion | `Sources/ForgeConductorCore/Telemetry/LMStudioDeployService.swift` |
| Independent process/identity smoke | `Sources/ForgeConductorCore/MCP/MCPServeVerifier.swift` |
| GUI install / heal | `Sources/ForgeConductorApp/AppModel.swift`, `Views/MCPServersView.swift` |
| Live observation only | `ProcessDiscovery.swift`, `ForgeCollector.swift` |

## Handshake / timeout (what we fixed, what you must verify)

### Root signals (investigated)

| Signal | Meaning |
|--------|---------|
| `spawn …/forge-serve ENOENT` | Stale registration still pointed at deleted Python/bash launcher |
| ~60s `Client created` → `Client disconnected` in LM Studio logs | Host handshake timeout (stdio reply delayed or never arrived) |
| Forge logs `initialize`, but LM Studio never requests `tools/list` | LM Studio rejected the initialize response; verify newline-delimited MCP output and ensure no LSP-style `Content-Length` headers are emitted |
| GUI holding SQLite store | Concurrent writer contention without `busy_timeout` |
| Fully buffered stdout on pipes | `initialize` response stuck until buffer fill |

### Code repairs (Xcode → CLI product)

| Fix | Location |
|-----|----------|
| `setvbuf(stdout/stderr, _IONBF)` | `MCPServer.run` |
| Exactly one compact JSON-RPC message plus `\n` per stdout frame; no `Content-Length` | `MCPStdioTransport` in `MCPServer.swift` |
| Deployment smoke accepts only newline-delimited responses | `MCPServeVerifier` |
| Unique `FORGE_DEPLOYMENT_ID` in both role entries forces every `mcp.json` deploy to be observable | `LMStudioEnvironment` / installer |
| Hot reload, scoped LM Studio relaunch fallback, exact-revision synchronization gate, and runtime evidence | `NativeLMStudioHostActivator` |
| `PRAGMA busy_timeout=3000` | `SQLiteStore` |
| Registration never writes `forge-serve` | `LMStudioEnvironment` / installer |
| Default spawn target = CLI `forge-conductor` | `resolveBinaryURL` / Install Plugin |

### Transactional operational deploy

Deployment performs these gates before reporting success:

1. The selected executable must pass independent primary and fallback MCP handshakes.
2. Existing `mcp.json` must parse; foreign servers are preserved.
3. Both plugins are staged and validated before live paths change.
4. Fallback commits first, followed by primary and an atomic configuration write.
5. Both committed roles are smoked again. A commit failure rolls back all live paths.
6. Every deploy writes a new shared revision to both role environments, even when the binary path is unchanged.
7. LM Studio is launched if necessary and given a bounded hot-reload window; if stale processes remain, only LM Studio is gracefully relaunched.
8. Success is withheld until LM Studio's own synchronized MCP state contains both roles with that exact revision. When the current chat activates them, host-originated `tools/list` evidence is also recorded for each role.

LM Studio then spawns the selected executable as:

`~/.forge-conductor/bin/forge-conductor serve`

That binary must be rebuilt and installed or selected explicitly.
**Do not silently overwrite** `/Applications/Forge Conductor.app` or the LaunchAgent home app unless the operator explicitly ships.

### Evidence checklist (stdio — no LM Studio UI required)

```bash
BIN="$HOME/.forge-conductor/bin/forge-conductor"
test -x "$BIN"

# Expect initialize + tools/list in well under 1s (typically <100ms)
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
| env FORGE_CONDUCTOR_HOME="$HOME/.forge-conductor" FORGE_MCP_ROLE=primary "$BIN" serve
```

Success criteria:

- `serverInfo.name` = `forge-conductor` (or `forge-conductor-fallback` with role=fallback)
- `tools/list` → **25** tools (`agent_*`, `fs_*`, `shell_exec`, `forge_status`, …)
- Each response is a single compact JSON object terminated by `\n`; stdout contains no `Content-Length` header
- No `forge-serve` in `~/.lmstudio/mcp.json` or mcpBridge configs

### LM Studio host verification (automated)

Standalone stdio smoke does not prove that LM Studio accepted the configuration. Deploy therefore requires LM Studio's generated `last-synced-mcp-state.json` to contain both `mcp/forge-conductor` and `mcp/forge-conductor-fallback` entries with the committed revision. The operation launches LM Studio when it is closed and relaunches it only when hot reload cannot replace possible stale processes. MCP plugin processes are lazy and start when selected by a chat; when they start, Forge records revision-correlated `tools/list` evidence. If synchronization fails, Deploy returns an error instead of reporting success.

For diagnosis only:

```bash
rg -i 'Plugin\(mcp/forge-conductor\)|forge-serve|ENOENT|timeout' \
  ~/Library/Logs/LM\ Studio/main.log ~/.lmstudio/server-logs/
```

## Fail-forward connection state

| Mechanism | Behavior |
|-----------|----------|
| State | Meaning |
|---|---|
| `ready` | Primary and fallback both passed role-aware MCP verification |
| `primary_only` | Primary is serving; fallback is degraded and should be repaired |
| `fallback_promoted` | Primary is degraded; fallback remains a valid serving connector |
| `unavailable` | Neither connector is healthy; deployment/health check fails closed |

The two registrations are separate LM Studio-hosted processes with distinct `serverInfo.name` values. This prevents one broken stdio session from taking down both paths. Forge does not impersonate LM Studio's scheduler: automatic selection between enabled MCP servers is ultimately a host/operator responsibility.

## Operator steps

1. Build with `./script/build_and_run.sh` or the Xcode `ForgeConductor` / `forge-conductor` schemes.
2. Install CLI layout: `forge-conductor install` (does **not** write LM Studio by itself).
3. Deploy and activate: **Deploy to LM Studio** in the GUI, or `forge-conductor install-lmstudio-plugin`.
4. Load a tool-capable local model. Configuration, activation, and connection verification are already complete.

### App-as-MCP ship checklist

1. Build an app whose executable enters MCP stdio mode when run with `serve`; normal startup must remain silent on stderr.
2. Smoke that app path with the same initialize/`tools/list` protocol.
3. `forge-conductor install-lmstudio-plugin --binary "<app executable>"`.
4. Confirm the command reports host acknowledgement for primary and fallback; restart is automated only if hot reload is insufficient.

## Auto-heal

On GUI bootstrap, registration is **not** auto-written (operator must Install Plugin).
`LMStudioMCPPluginInstaller.ensureConnection` exists for explicit heal paths when registration is incomplete or drifted. Repairs use the same typed, transactional installation boundary rather than modifying only one role.
