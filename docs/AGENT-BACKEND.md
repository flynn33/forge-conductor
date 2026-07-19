# Agent backend — HOST vs Grok Build

## Modes

| Mode | Executor | Local host model role |
|------|----------|------------------------|
| `host` | Same chat model (e.g. Qwen) | Runs playbooks after `agent_run_start` |
| `grok` | **Grok Build** session | **Router only** — start/poll agents |

State file: `agent_backend.json` (snapshotted with durable state).

## GROK mode operator flow

1. Dashboard **LOAD** (if using RAM stack).  
2. Click **GROK** → modal **connect prompt** → **Copy**.  
3. Paste into a **Grok Build** session.  
4. Grok Build runs `grok-build-agent-ctl.py attach`.  
5. LM Studio: new chat, `mcp/forge-conductor` ON.  
6. Qwen: `session_bootstrap` → `agent_run_start` only for specialist work.  
7. Grok Build: `list` / `claim` / execute / `complete`.

**No cloud API key** for the Grok Build path.

## Enforcement

When `mode=grok`, tool middleware blocks host mutators (`fs_write`, `shell_exec`, git mutators, …). Continuity tools (`memory_*`, `handoff_*`, `project_*`) remain allowed.

## Job queue

`agent_run_start` in grok mode inserts into SQLite `jobs` (`type=agent_grok`).  
Grok Build claims via `claim_next_job` / CLI.

## LM Studio notification

On mode change: rewrite system prompt assets, patch presets/model defaults, write  
`~/.lmstudio/.internal/forge-agent-backend-notify.json`.  
**New chat** recommended so the system prompt refreshes; middleware enforces immediately.

## Optional future

- `executor: xai_api` headless worker (API key) — not the primary product path.  
- Auto mode heuristics (trivial → host, multi-file → Grok Build).
