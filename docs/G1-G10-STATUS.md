# G1–G10 honest status (0.5.3-swift)

Legend: **CODE** = implemented in Xcode project · **TEST** = automated proof · **OPS** = requires your install/LM Studio

| ID | Requirement | CODE | TEST | OPS |
|----|-------------|------|------|-----|
| G1 | Deploy product path (Deploy → plugins → use) | Yes | Transactional config + standalone smoke + LM Studio host acknowledgement | Load a model |
| G2 | Main + failover plugins | Yes | Installer writes and host-verifies both under one revision | None |
| G3 | Native Apple build and operator verification | Yes, SwiftPM + Xcode project | Native app links; 122 tests | **You sign/release** |
| G4 | Modular OOP | Yes (typed services/protocols/clients/tool packs) | Protocols + services compile/test | Maintain boundaries |
| G5 | Real-time host telemetry (not 2s snapshot) | Yes (~30 Hz stream + continuous SSE + GUI bind) | RealtimeStreamTests multi-frame | Optional RIG look |
| G6 | Diagnostics + JSON/MD export | Yes + rotation + more events | Export unit test | **You** export after use |
| G7 | Reliable MCP tools/agents | Protocol negotiate + tools surface + host activation | In-process handshake + LM Studio-originated tools/list | Model-use acceptance |
| G8 | Single product / no dual port fight | **Yes: manager owns bind; GUI attaches; second manager fails closed** | Port guard + loopback client integration | None for normal launch |
| G9 | Installable single product identity | Prefer running app for Deploy; install still multi-path | Resolve + smoke | **You** install one app |
| G10 | No fake “done” without evidence | This matrix; Deploy fails if smoke fails | Tests pass/fail visibly | Operator acceptance |

## Port ownership behavior

1. `DashboardPortGuard` — detects who holds :7788
2. `DashboardServer.start` **waits for bind ready/failed** (no silent “listening” on conflict)
3. A second manager **fails with a clear error** instead of lying in manager state
4. The GUI detects and attaches to an existing LaunchAgent manager without binding again
5. The GUI retries transient manager connection loss and logs attach/recovery state
6. Deploy smoke-tests `serve`, revisions all required LM Studio configuration, activates the host, and requires both hosted tool lists

## What is still NOT claimed

- Model-specific tool-selection quality inside a conversation
- Automatic killing of a foreign process that owns the configured port (unsafe without your OK)
- Hub marketplace card named “Forge-Conductor”
