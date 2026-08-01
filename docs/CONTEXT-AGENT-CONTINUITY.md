# Context & Agent Continuity (v0.7.0)

## Summary

Forge Conductor owns **context handoff** and **agent session continuity** for LM Studio chats. Both ship over the existing **stdio MCP** server (`serve`). Deploy remains **Deploy to LM Studio** (primary + fallback mcpBridge). No HTTP dependency for agent resume.

## Product constraints

- Dependency-free (Foundation + system SQLite only)
- Same Mac app auto-deploy path (`LMStudioDeployService` / mcpBridge)
- Work developed in this repository; does not alter a running install until the operator deploys the next build

## Surfaces (stdio MCP)

| Tool | Purpose |
|------|---------|
| `session_checkpoint` | Soft save: write/update handoff packet; continue working |
| `session_handoff` | Finalize packet; mark resume-ready; return seed for new chat |
| `context_get` | Load latest (or id) packet for bootstrap in a new chat |
| `context_list` | List recent handoffs |

`forge_status` reports `continuity` (latest handoff id, resume_ready, open agent sessions).

## Packet (`schema_version: 1`)

- **meta** — id, timestamps, source (`model` \| `budget` \| `user`), chat_label, client_id
- **task** — goal, status, project_slug, cwd, blockers, next_actions
- **working_set** — key files / decisions
- **agents** — open sessions with session_id, agent_id, goal, cwd, status (reattach instructions)
- **narrative** — capped free text
- **resume** — bootstrap string, custom-seed marker, and continuation instructions

Durable copies:

- SQLite `context_handoffs` (authoritative, transactionally ordered by write sequence)
- `memory/handoffs/<id>.json`
- `memory/handoffs/LATEST`
- Projection into `memory/current-task.md`

Primary and fallback MCP processes serialize continuity mutations through a
home-scoped lock. A handoff row and its SQLite pointer notes commit in one
transaction. JSON and Markdown are rebuildable projections; bootstrap repairs
them from SQLite after an interrupted or older-version write.

## Triggers (hybrid)

1. **Model** — calls checkpoint/handoff tools
2. **Budget** — ToolRouter tracks canonical consecutive tool fingerprints. The fourth identical call writes a soft handoff signal; the ninth is blocked with `identical_call_loop`. Continuity calls do not count toward the loop.

## Phase 2 (later)

Optional LM Studio host automation to open a new chat. Memory remains in Forge stdio tools; not required for Phase 1.

## Bootstrap (new chat)

1. Enable `mcp/forge-conductor` (or fallback)
2. Call `context_get` (or read `forge_status.continuity`)
3. Reattach agents via `agent_run_status` / complete+restart as needed
4. Continue task from the packet
5. Pass the returned `handoff_id` to later checkpoints or handoffs so the resumed packet is updated explicitly

`agent_run_status(session_id)` transfers an open session binding to the calling
MCP client and restores its goal, workspace, tool policy, and output contract.
Only sessions owned by the calling client are included in new packet snapshots.

Packet identity and schema metadata are validated before projection. Narrative
text is capped at 4,000 characters, list limits are clamped to 1–100, and
continuity content is redacted from tool-audit arguments.
