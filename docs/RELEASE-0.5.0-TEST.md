# Forge Conductor 0.5.1 — operator test plan (G1–G7 gap close)

Build **from Xcode** (you build and test; agents do not overwrite live `/Applications` or home installs).

**Version:** `0.5.1-swift`

## Product path under test

1. LM Studio installed
2. Forge Conductor 0.5.0 installed / run from your Xcode build
3. **LM Studio MCP** tab → **Deploy to LM Studio**
4. Wait for “Deployment complete”; Forge edits configuration, reloads/relaunches LM Studio when required, and verifies both hosted connections
5. Load a tool-capable local model; tools / agents available

## Architecture delivered

| Module | Role |
|--------|------|
| `LMStudioDeployService` | Deploy primary + failover; logs every step; resolves app `serve` binary |
| `RealtimeMetricsEngine` | Continuous native host sampling (~30 Hz) via Apple collectors |
| `TelemetryService` | Composes continuous host stream + forge/MCP cards |
| `DiagnosticLog` | Flight recorder JSONL + JSON/Markdown export |
| `MCPServer` | Protocol negotiation (`2025-11-25` / `2024-11-05`) |

## Non-negotiable features

| Feature | How to verify |
|---------|----------------|
| Real-time telemetry | FORGE RIG uses continuous engine + TimelineView. Label shows measured Hz (not “snapshot every 2s”). Gauges move without multi-second stalls. |
| Diagnostics export | **Diagnostics** tab → **Export JSON + Markdown…**. Deploy, call tools, export; JSON `records[]` includes deploy + tool_call + mcp_initialize; MD Timeline is filled. |
| Product Deploy | After Deploy, both primary and failover show installed and host-synchronized for the same revision; no manual config-file edit/restart; standalone tool lists work without ~60s hang. Plugin selection remains per chat. |

## Xcode commands (optional local verification before UI)

```bash
cd /Users/jim.daley/Forge-Conductor
xcodebuild -project ForgeConductor.xcodeproj -scheme ForgeConductor -destination 'platform=macOS' test
xcodebuild -project ForgeConductor.xcodeproj -scheme ForgeConductor -destination 'platform=macOS' build
xcodebuild -project ForgeConductor.xcodeproj -scheme forge-conductor -destination 'platform=macOS' build
```

## Version

- Marketing / Swift: **0.5.0-swift** (`ForgeApp.version`)
- Info.plist: **0.5.0**

## Out of scope for this build session

- Silent overwrite of live production app
- Leaving LM Studio proxies as the long-term path (native protocol negotiation is in-tree)
