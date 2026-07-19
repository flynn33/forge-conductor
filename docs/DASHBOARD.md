# Management engine (telemetry dashboard)

## Role

Always-on **control plane** for the orchestration layer. Lives on disk (not on the RAM volume) so UNLOAD does not kill the UI.

## URL

- Local: http://127.0.0.1:7788/  
- LAN: http://&lt;host-ip&gt;:7788/ (default bind `0.0.0.0`)  
- Auth: **none**

## Controls

| Control | Action |
|---------|--------|
| **LOAD** | Create RAM disk, hydrate, start keepers + supervise |
| **UNLOAD** | Snapshot, stop keepers, destroy RAM disk |
| **RESTART** | UNLOAD then LOAD |
| **SNAPSHOT** | Force durable snapshot while loaded |
| **WARM** | Reload process-RAM corpora |
| **HOST** | Agent backend = local model |
| **GROK** | Agent backend = Grok Build; **popup connect prompt** |
| **PROMPT** | Re-show Grok Build connect prompt |

## Implementation

- `server.js` — Express APIs + static UI  
- `static/app.js` — polling stack/backend status  
- `supervise.ps1` / scheduled task — auto-restart Node  

## Separation from MCP

Telemetry is a **separate process** so crashes and heavy dashboard work do not tear down host MCP stdio sessions.
