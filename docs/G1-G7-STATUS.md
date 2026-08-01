# G1–G7 status after 0.5.1 gap-close work

| ID | Goal | Project status (0.5.1) | Operator still owns |
|----|------|------------------------|---------------------|
| **G1** | Product Deploy path | **Met in code + automated MCP product tests** | Your Xcode install + LM Studio enable |
| **G2** | Main + failover plugins | **Met** | Confirm both enabled in LM Studio UI |
| **G3** | Xcode only; you build/test | **Met** | Build/run ForgeConductor scheme |
| **G4** | Modular OOP | **Met for deploy/realtime/diagnostics protocols + services** | N/A |
| **G5** | Real-time telemetry | **Met: continuous ~30 Hz engine + UI pull; dashboard poll labeled separately** | Confirm RIG Hz label live |
| **G6** | Diagnostics + JSON/MD export | **Met: flight recorder, rotation, more events, export UI** | Export after Deploy + one tool call |
| **G7** | Reliable tools/MCP/agents | **Met in-process:** initialize `2025-11-25`, ≥20 tools, `forge_status` call; **Deploy smoke** pre/post | LM Studio model tool use |

## Automated proof (agent)

```
ProductPathReliabilityTests + MCPProtocolAndDiagnosticsTests — 8/8 passed
BUILD SUCCEEDED (ForgeConductor)
```

## New in 0.5.1

- `MCPServeVerifier` — Deploy fails if binary cannot complete MCP handshake
- Deploy prefers **running app executable**, then home app, then CLI
- Diagnostics log rotation at 8 MB
- MCP logs `mcp_tools_list` / `mcp_tools_call`
- Settings distinguish host telemetry vs dashboard HTML poll
