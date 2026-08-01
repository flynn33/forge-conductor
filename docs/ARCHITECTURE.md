# Forge Conductor architecture

Forge Conductor is a native macOS orchestration server for local models hosted by LM Studio. The same codebase supplies a SwiftUI/Metal operator app, a CLI, a persistent local manager, and MCP stdio connector processes.

## Design rules

1. `ForgeConductorCore` contains reusable domain and service modules; executable targets are composition and presentation shells.
2. Dependencies point inward through Swift protocols. LM Studio installation and MCP verification are injected ports, not hard-coded global calls.
3. The Apple-native stack is Foundation, SwiftUI, AppKit, Combine, Metal, Network, IOKit, Mach, SQLite3, and FileManager. The runtime does not require Node or Python.
4. Framework features are exposed through modular `ToolPackHandling` implementations and stable MCP tool names.
5. Primary and fallback LM Studio connectors are independent processes with typed identities and aggregate health.
6. Persistent sessions and active bindings survive process restarts.

## Package products

| Product / target | Responsibility |
|---|---|
| `ForgeConductorCore` | Domain, application services, infrastructure, MCP, manager, dashboard, telemetry |
| `forge-conductor` / `ForgeConductorCLI` | CLI, installer, manager commands, and MCP stdio executable |
| `forge-conductor-app` / `ForgeConductorApp` | SwiftUI/AppKit/Metal operator application |
| `ForgeConductorTests` | Unit, integration, security, connector, and process acceptance tests |

The Xcode project mirrors these boundaries. SwiftPM provides a second reproducible Apple-native build path and stages the GUI through `script/build_and_run.sh`.

## Core module map

```text
Domain/          Typed models, connector roles/health, protocols, JSON support
Application/     Composition root, agent/session services, authorization, tool packs
Infrastructure/ Paths, configuration, SQLite, audit, diagnostics, process execution
MCP/             Bounded JSON-RPC stdio server and independent serve verifier
Manager/         Persistent local service lifecycle and normalized settings
Dashboard/       Loopback HTTP telemetry/control surface and request policy
Telemetry/       Native collectors, LM Studio discovery, transactional deployment
```

## Composition root

```text
ForgeApp.bootstrap(home:)
  -> AppPaths + ConfigStore
  -> SQLiteStore migration
  -> AuditService + DiagnosticLog
  -> AgentCatalog + AgentSessionService
  -> LM Studio installer/verifier/deploy services
  -> ToolAuthorizationService -> ToolRouter -> modular tool packs
  -> TelemetryService
```

The root owns its services. Back-references are non-owning, avoiding service cycles. Presentation code receives the root through `AppModel`; it does not construct infrastructure directly.

## Manager ownership

The persistent LaunchAgent `ManagerNode` is the sole owner of the loopback dashboard port. A double-clicked GUI detects an existing manager by its PID file and port ownership, then attaches through the typed, Foundation-native `ManagerDashboardClient`. If no manager exists, the GUI may host a local manager. Remote status polling retries transient loss and Manager controls use the same loopback API, so a GUI launch never competes with a healthy manager for port 7788.

## LM Studio fail-forward lifecycle

```text
resolve executable
  -> smoke primary identity
  -> smoke fallback identity
  -> parse existing LM Studio configuration
  -> stage and validate both plugin directories
  -> commit fallback, then primary, then mcp.json atomically
  -> smoke both committed registrations
  -> ready | primary_only | fallback_promoted | unavailable
```

- `forge-conductor` and `forge-conductor-fallback` have distinct role environment values and `serverInfo.name` identities.
- Foreign MCP registrations are preserved.
- Malformed configuration aborts without replacing live plugins.
- A failed commit or post-commit validation rolls back the previous configuration and plugin directories.
- A healthy fallback with a failed primary is a degraded, serving state (`fallback_promoted`), not a total outage.
- LM Studio remains the process host. Forge prepares and verifies two hot connectors; LM Studio/operator policy determines which enabled connector receives a tool call.

## Trust boundaries

- Dashboard HTTP binds only to `localhost`, `127.0.0.1`, or `::1`.
- Browser mutations require same-origin JSON. Wildcard CORS is not emitted.
- Privileged tool invocation is not exposed over HTTP; it is available over the LM Studio MCP stdio boundary.
- Agent grant/deny lists and configured workspace roots are enforced before tool dispatch.
- Filesystem paths are canonicalized to prevent traversal and symlink escapes.
- HTTP bodies, MCP frames, file reads, subprocess capture, and returned shell output are bounded.
- Audit records redact commands and file contents.

`shell_exec` is intentionally a powerful local-model capability. It requires an active agent workspace, but it is not an operating-system sandbox; deployments should grant it only to trusted local agents.

## Persistence

`~/.forge-conductor` (or `FORGE_CONDUCTOR_HOME`) contains:

- `store.sqlite` for sessions, bindings, audit index, and presence
- `audit.jsonl` for append-only tool audit
- `logs/*.jsonl` for categorized diagnostics
- `agents/*.md` for replaceable playbook modules
- `config.json` for local configuration
- `memory/handoffs/*.json` and `memory/current-task.md` as readable continuity projections

## Build and run

```bash
./script/build_and_run.sh            # build, stage app bundle, launch
./script/build_and_run.sh --verify   # launch and verify the exact GUI process
swift test                           # full Core/CLI acceptance suite
```

Version: `0.7.0`
