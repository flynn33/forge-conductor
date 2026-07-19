# Forge Rig Telemetry

Browser dashboard for **system** (CPU / GPU / RAM / disk) and **Forge-Conductor** (MCP load, agents, presence, audit).

- **Local:** http://127.0.0.1:7788/
- **LAN:** http://&lt;this-pc-ip&gt;:7788/ (binds `0.0.0.0` by default)
- **Auth:** none (trusted LAN; read-only dashboard)
- **MCP-safe:** separate process; read-only SQLite + audit tail

## Always-on (recommended)

Install a Windows Scheduled Task that starts at logon and **auto-restarts** on crash:

```powershell
pwsh -File $env:USERPROFILE\.forge-conductor\telemetry\install-task.ps1 -StartNow
```

| Piece | Role |
|---|---|
| `install-task.ps1` | Registers task `ForgeRigTelemetry` (logon + restart) |
| `supervise.ps1` | Process loop: start Node → wait → restart on exit |
| `uninstall-task.ps1` | Remove task + stop processes |

Task Scheduler also sets `RestartCount=999` / 1 minute if the supervise host itself dies.

## Manual / foreground

```powershell
pwsh -File $env:USERPROFILE\.forge-conductor\telemetry\run.ps1
# or supervised loop without Task Scheduler:
pwsh -File $env:USERPROFILE\.forge-conductor\telemetry\run.ps1 -Supervised
```

## API

- `GET /api/health`
- `GET /api/snapshot`
- `GET /api/stream?interval=2` (SSE)
- Frontend uses **poll + SSE** so metrics still update if EventSource flakes.

## Logs

`~\.forge-conductor\telemetry\logs\`

- `supervise.log` — restarts
- `server.out.log` / `server.err.log` — Node stdout/stderr
