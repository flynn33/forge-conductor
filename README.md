# Forge Conductor

**Lightweight, on-demand orchestration layer for local AI development.**

Forge Conductor is a **host-driven MCP orchestration layer** designed for high-RAM Windows rigs (Mac packaging planned). It does **not** embed an LLM. Host models (LM Studio, Codex, Claude Code, Grok Build, etc.) call tools; Forge provides memory, agents, filesystem/shell/git, failover, and a browser **management dashboard**.

> **GitHub:** [flynn33/forge-conductor](https://github.com/flynn33/forge-conductor)  
> *(Repository name is historical spelling; product name is **Forge Conductor**.)*

---

## Why it exists

Local coding models need a **stable, privileged tool plane** with:

- **RAM-first** hot state (memory + agent orchestration) and durable disk backup  
- **On-demand load** of the full stack into a **RAM disk** (operator-controlled)  
- **Primary + fallback + memory** MCP keepers with fail-forward restarts  
- **Sub-agents** as playbooks (explore / plan / implement / …), not separate models  
- Optional **agent backend toggle**: local host model **or** **Grok Build** session as executor  
- A **telemetry dashboard** for stack control and status (no auth; trusted LAN)

---

## Architecture at a glance

```
┌─────────────────────────────────────────────────────────────┐
│  Management engine (always-on, disk)                        │
│  Node telemetry → http://127.0.0.1:7788/                    │
│  LOAD / UNLOAD / RESTART · HOST / GROK · SNAPSHOT           │
└───────────────────────────┬─────────────────────────────────┘
                            │ operator LOAD
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  RAM disk (e.g. R:) — full package + live home              │
│  keepers: primary · fallback · memory                       │
│  SQLite + JSON corpora = durable backup                     │
└───────────────────────────┬─────────────────────────────────┘
                            │ stdio MCP
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
   LM Studio             Grok Build          Other hosts
   (router or host)      (optional agent     (Codex, …)
                          executor)
```

See **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** for diagrams and component map.

---

## Repository layout

| Path | Purpose |
|------|---------|
| `packages/forge_conductor/` | Python package (MCP server, tools, RAM memory, agents) |
| `home-template/` | Template for `~/.forge-conductor` (scripts, telemetry UI, defaults) |
| `docs/` | Design, architecture, packaging roadmap |
| `tests/` | Pytest suite (from product worktree) |
| `pyproject.toml` | Package metadata |

**Not shipped:** secrets, live `store.sqlite` user data, logs, `node_modules`, RAM-disk durable snapshots.

---

## Quick start (Windows, developer)

1. Install Python 3.12+, Node 20+, [ImDisk Toolkit](https://sourceforge.net/projects/imdisk-toolkit/) (for RAM disk).  
2. Create venv and install package from `packages/` / `pyproject.toml`.  
3. Copy `home-template` → `%USERPROFILE%\.forge-conductor` (merge carefully).  
4. Register elevated task: `scripts/install-forge-ramdisk-elevated-task.ps1` (admin once).  
5. Start telemetry: `telemetry/run.ps1` or scheduled task.  
6. Open http://127.0.0.1:7788/ → **LOAD**.  
7. Point LM Studio `mcp.json` at `bin/forge-serve.cmd` (and optional fallback / ram-memory).

Full notes: **[docs/PACKAGING.md](docs/PACKAGING.md)**.

---

## Agent backend (HOST / GROK Build)

| Mode | Who runs `agent_run_*` playbooks |
|------|-----------------------------------|
| **HOST** | Local chat model (e.g. Qwen in LM Studio) |
| **GROK** | **Grok Build** session — dashboard shows a **connect prompt** to paste; no cloud API key required |

When GROK is active, the local model is **router only** (mandatory offload + tool middleware blocks freestyle mutators).

See **[docs/AGENT-BACKEND.md](docs/AGENT-BACKEND.md)**.

---

## Documentation map

| Doc | Content |
|------|---------|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Components, data flow, process model |
| [DESIGN.md](docs/DESIGN.md) | Design principles, decisions, trade-offs |
| [RAMDISK.md](docs/RAMDISK.md) | On-demand ImDisk volume, elevated ops, snapshots |
| [DASHBOARD.md](docs/DASHBOARD.md) | Telemetry UI / control plane |
| [AGENT-BACKEND.md](docs/AGENT-BACKEND.md) | HOST vs Grok Build executor |
| [ROADMAP.md](docs/ROADMAP.md) | Product path to Windows/Mac installers |
| [PACKAGING.md](docs/PACKAGING.md) | What to ship; exclusions; install sketch |

---

## Security model

Intentionally **permissive** (full user privileges for tools). **No authentication** on the dashboard (trusted local/LAN). Treat MCP registration like granting full local account access to the host model.

---

## License

# Non-Commercial Open Source License (NC-OSL) v1.0

**Copyright (c) 2026 James Daley**

## Permission Notice

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, and sublicense copies of the Software, **subject to the following conditions**:

1. **Non-Commercial Use Only**: The Software may only be used, copied, modified, distributed, or sublicensed for non-commercial purposes. Commercial use, including but not limited to selling, licensing for a fee, incorporating into commercial products/services, or using in any revenue-generating activity, is strictly prohibited.

2. **Attribution**: All copies or substantial portions of the Software must include the above copyright notice, this permission notice, and the full license text.

3. **No Warranty**: THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Additional Terms

- This license is intended for open-source sharing and collaboration in educational, research, personal, or other non-profit contexts.
- If you wish to use this Software for commercial purposes, please contact the copyright holder at contact@ravenforgesoftware.com to discuss licensing options.
- Derivative works must carry this same license (or a compatible non-commercial license) and clearly indicate modifications.
- This license does not grant permission to use the names, trademarks, or logos of the copyright holder for endorsement or promotion without explicit prior written consent.

---

**License Version**: 1.0  
**Type**: Permissive, Non-Commercial  

---

## Status

Productization **documentation + vendored source snapshot** of a working rig implementation (2026-07). Not yet a one-click installer.
