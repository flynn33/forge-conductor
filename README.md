# Forge-Conductor (Swift)

Native **Swift** control plane and MCP server for **local models in [LM Studio](https://lmstudio.ai)** on macOS.

This project is **not** Claude Code orchestration, CCDT, or `~/.claude/local-mcp`.

### Context & agent continuity (v0.7)

Cross-chat handoff lives **inside** the same stdio MCP `serve` process (no HTTP):

| Tool | Role |
|------|------|
| `session_checkpoint` | Soft-save task + open agents |
| `session_handoff` | Finalize resume packet (`resume_seed`) |
| `context_get` / `context_list` | Bootstrap a new chat |

Packets are stored under `FORGE_CONDUCTOR_HOME` (SQLite + `memory/handoffs/`). Open agent sessions are snapshotted for reattach. Deploy remains **Deploy to LM Studio** (primary + fallback mcpBridge). Details: [`docs/CONTEXT-AGENT-CONTINUITY.md`](docs/CONTEXT-AGENT-CONTINUITY.md).

New-chat flow: call `context_get`, reattach any listed agent sessions with
`agent_run_status`, then pass the returned `handoff_id` to subsequent
`session_checkpoint` or `session_handoff` calls.

### How LM Studio connects

LM Studio is the MCP **host**. It spawns a Forge **stdio** server:

| Executable | Argv | Role |
|------------|------|------|
| `…/Forge Conductor.app/…/Forge Conductor` | `serve` | **Default MCP** via `ForgeProcessEntry` (Deploy to LM Studio) |
| Selected app or CLI executable | `serve` + `FORGE_MCP_ROLE` | Independent primary and fallback MCP registrations |
| App (LaunchAgent) | `manager run --home …` | Dashboard manager (`install-login`) |
| App (double-click) | _(none)_ | SwiftUI GUI |

**Product path (v0.5+):** GUI → **LM Studio MCP** → **Deploy to LM Studio**. Forge transactionally writes primary + failover configuration, triggers LM Studio reload (relaunching it only if needed), verifies LM Studio synchronized the exact revision, and independently smokes both tool servers. Details: [`docs/LM-STUDIO-CONNECTION.md`](docs/LM-STUDIO-CONNECTION.md), operator test plan: [`docs/RELEASE-0.5.0-TEST.md`](docs/RELEASE-0.5.0-TEST.md).

```bash
# After building products — does NOT write LM Studio by itself:
forge-conductor install
# Explicit deploy (same as GUI Deploy to LM Studio):
forge-conductor install-lmstudio-plugin
# GUI: LM Studio MCP tab → Deploy to LM Studio
```

No manual LM Studio configuration-file edit or restart is required. Selecting which plugins a model may use remains a per-chat LM Studio choice.

## Requirements

- macOS 26+
- Swift 6 / Xcode toolchain
- [LM Studio](https://lmstudio.ai) for running local models

## Quick start

```bash
git clone https://github.com/flynn33/forge-conductor.git
cd forge-conductor
# Reproducible native app build, bundle staging, and launch:
./script/build_and_run.sh --verify

# Full Core/CLI/connector acceptance suite:
swift test

# CLI install (from built product or SPM release)
forge-conductor install
forge-conductor doctor
forge-conductor manager start --open   # native dashboard / manager
# LM Studio starts MCP via ~/.lmstudio/mcp.json → forge-conductor serve (Swift stdio)
```

## What the UI shows

| Surface | Meaning |
|---------|---------|
| **FORGE RIG** | Host telemetry (CPU/GPU/RAM/disk) + LM Studio-oriented load |
| **LM Studio MCP** | LM Studio host, model backends, Forge MCP from `mcp.json` / live processes |
| **Agents / Tools / Feed** | Playbooks and tool audit for local-model agent runs |
| **Manager** | Start/Stop HTTP control plane, settings, doctor |

**Never listed:** CCDT, Claude Code `local-mcp` binaries, project-continuity (foreign projects).

The LaunchAgent manager is the single owner of the loopback dashboard port. Opening the SwiftUI app attaches to that manager through a native typed client; it does not start a competing listener. The app uses a persistent button-based navigation column; use its toolbar button or the **Navigation** menu to show or hide it.

## Architecture

| Layer | Responsibility |
|-------|----------------|
| **Domain** | Typed models (`ForgeSnapshot`, `AppConfig`, agent sessions) |
| **Infrastructure** | SQLite, paths, process runner, PDF, audit |
| **Application** | `ForgeApp`, catalog, sessions, tool packs |
| **MCP** | JSON-RPC stdio for LM Studio (`tools/list`, `tools/call`) |
| **Dashboard / App** | SwiftUI + Metal gauges; optional loopback HTTP |
| **CLI** | install / doctor / serve / manager |

State: `~/.forge-conductor` (`FORGE_CONDUCTOR_HOME` override).
LM Studio MCP config: `~/.lmstudio/mcp.json`.

## Design principles

1. OOP modules + DI via `ForgeApp.bootstrap`.
2. Apple-native stack (Foundation, SQLite3, Network, Metal) — no Node/Python core.
3. **LM Studio is the host** for local models; Forge is the MCP tool server + rig.
4. Durable sessions in SQLite for local-model agent runs.
5. SwiftPM acceptance tests and native GUI compilation gate release builds; Xcode remains the distribution/signing project.

Current build, test, static-analysis, orphan-file, and attribution evidence is
recorded in [`docs/AUDIT-2026-07-23.md`](docs/AUDIT-2026-07-23.md).

## CLI

```
forge-conductor install
forge-conductor install-lmstudio-plugin [--binary PATH]
forge-conductor doctor
forge-conductor status
forge-conductor agents
forge-conductor serve                 # MCP stdio (LM Studio client)
forge-conductor manager run [--open]
forge-conductor manager start|stop|restart|status
forge-conductor version
```

## Contributing

This project is open source under the Apache License, Version 2.0. You are
welcome to use, modify, and redistribute the code under that license.

Outside contributions are not accepted. See [CONTRIBUTING.md](CONTRIBUTING.md)
for the repository policy.

## License

Copyright 2026 James Daley

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for the
full terms.
