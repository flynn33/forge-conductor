# Architecture — Forge Conductor

## 1. Design goals

1. **No embedded LLM** — host models provide intelligence; Forge provides tools + state.  
2. **Local-first** — stdio MCP; optional LAN dashboard.  
3. **Fail-forward** — primary/fallback keepers, soft tool errors, agent recovery.  
4. **Hot path in RAM** — memory + orchestration catalogs; disk is backup.  
5. **Operator control** — full stack loads only when the management engine says LOAD.  
6. **Pluggable agent executor** — host model **or** Grok Build session.

## 2. Component map

| Component | Runtime | Location (rig reference) | Role |
|-----------|---------|--------------------------|------|
| **Telemetry / management engine** | Node (Express) | `home-template/telemetry` | Always-on UI + stack/backend APIs |
| **Stack controller** | PowerShell | `home-template/scripts/forge-stack.ps1` | load/unload/supervise keepers |
| **RAM disk controller** | PowerShell + ImDisk | `forge-ramdisk.ps1` + elevated task | Create/destroy R: volume |
| **MCP package** | Python 3.12 | `packages/forge_conductor` | tools, RAM memory, agents, supervise |
| **Keepers** | Python | `forge-mcp-keeper.py` | Always-warm stdio hosts for primary/fallback/memory |
| **Grok Build control** | Python CLI | `grok-build-agent-ctl.py` | attach / claim / complete jobs |
| **Durable home** | Files + SQLite | `~/.forge-conductor` or `R:\home` | config, store, corpora, logs |

## 3. Process model (loaded stack)

```
[ForgeRigTelemetry / Node :7788]
        │
        │ LOAD
        ▼
[ImDisk R:]  ── app\ (.venv + package)
             └── home\ (FORGE_CONDUCTOR_HOME)
                    ├── store.sqlite (+ WAL)
                    ├── memory_corpus.json
                    ├── orchestration_corpus.json
                    ├── agent_backend.json
                    └── bin\forge-*.cmd

[supervise loop]
   ├── keeper primary  → forge-serve.cmd → supervise → serve
   ├── keeper fallback → forge-serve-fallback.cmd
   └── keeper memory   → forge-memory-serve.cmd

[Host: LM Studio / other]
   spawns same .cmd shims → R:\ when loaded
```

## 4. MCP surface

### Full server (`forge-conductor`)

Packs include: memory, orchestration, meta, inventory, agent_backend, filesystem, shell, git, github_gh, vsbuild, python_exec, search, browser, research, agents, coord.

### Memory-only server (`ram-memory`)

Subset for continuity tools + `ram_status` (listed first in some hosts for UX).

### Fallback

Same family as primary; spare connection for host dual-toggle failover.

## 5. RAM memory & orchestration

| Module | Responsibility |
|--------|----------------|
| `memory_ram.py` | Full note corpus in process RAM; write-through SQLite + JSON snapshot |
| `ram_orchestration.py` | Agents, sessions, docs, audit ring, config hot; `super_context` for agent runs |
| `store.py` | SQLite schema: memory, agent_sessions, jobs, leases, presence, audit |

Reads prefer RAM; multi-process coordination via SQLite generation / WAL.

## 6. Sub-agents

Sub-agents are **markdown playbooks** + session rows, **not** separate model processes.

| API | Behavior |
|-----|----------|
| `agent_run_start` | Create session; inject `super_context`; dispatch by backend mode |
| `agent_run_status` | Session + job terminal state |
| `agent_run_complete` | End session + report |

**HOST mode:** host model executes playbook.  
**GROK mode:** job queued (`jobs` table, type `agent_grok`); Grok Build claims and executes; host polls.

## 7. Agent backend

State: `agent_backend.json` (`mode`: `host` | `grok`).

| Mode | Enforcement |
|------|-------------|
| host | Soft preferences |
| grok | Middleware blocks host mutators (`fs_write`, `shell_exec`, …); continuity tools allowed |

LM Studio notify: dual system prompts + preset patch on mode change.  
Grok Build: connect prompt popup + `grok-build-agent-ctl.py`.

## 8. Dashboard APIs

| Endpoint | Purpose |
|----------|---------|
| `GET /api/health` | Service health |
| `GET /api/stack` | Stack + RAM disk status |
| `POST /api/stack/load\|unload\|restart\|snapshot\|warm` | Stack control |
| `GET/POST /api/agent-backend` | HOST/GROK mode |
| `GET /api/agent-backend/connect-prompt` | Grok Build paste text |
| `GET /api/snapshot` | System + forge telemetry |

## 9. Elevations & Windows specifics

ImDisk create/format requires **admin**. Dashboard is often non-elevated → **Scheduled Task** `ForgeRamdiskElevated` runs `forge-ramdisk-elevated-ops.ps1` at Highest run level.

## 10. Data durability

| Hot | Backup |
|-----|--------|
| Process RAM banks | `store.sqlite`, `memory_corpus.json`, `orchestration_corpus.json` |
| Live `R:\home` | `durable/state/current` + rotating `durable/snapshots` |

UNLOAD forces final snapshot before destroy.

## 11. Trust boundary

- No dashboard auth (trusted LAN).  
- Tools run as the user.  
- Audit JSONL + SQLite for forensics, not sandboxing.
