# Design decisions — Forge Conductor

## Principles

1. **Host is the brain** — avoids shipping model weights or vendor lock-in for inference.  
2. **Privileged tools by design** — developer rigs need real fs/shell/git; document risk instead of fake sandbox.  
3. **Fail forward** — soft MCP errors, retries, circuits, dual keepers; prefer degraded progress over hard fail.  
4. **RAM as primary store for hot data** — 128GB-class machines; disk is durability.  
5. **Operator-gated heavy stack** — management engine always light; orchestration LOADs on demand.  
6. **Visible agent control** — Grok Build paste-prompt pattern for human-in-the-loop specialist work.

## Key decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Transport | MCP stdio | Works with LM Studio, Codex, etc. |
| Language | Python 3.12 + FastMCP | Fast iteration, host ecosystem |
| Dashboard | Separate Node process | MCP-safe sidecar; LAN UI |
| Full package in RAM | ImDisk volume | True filesystem install, not only process heap |
| Elevation | Scheduled task Highest | Dashboard cannot always elevate ImDisk format |
| Sub-agents | Playbooks + sessions | No second model tax unless operator chooses Grok Build / API |
| Grok Build vs API | Prefer Grok Build session | Operator visibility; no API key; learning loop |
| Memory MCP split | Optional `ram-memory` | Host UX for “memory toggle”; trade-off: model may over-use small server |
| Auth | None on dashboard | Explicit trusted-LAN product choice |

## Trade-offs

| Benefit | Cost |
|---------|------|
| Huge tool surface | Local models may ignore agents / stick to small MCP |
| Soft tool errors | Host must still interpret soft failures |
| RAM disk 16–32 GB | Needs free RAM + ImDisk + elevation path |
| Dual prompts for HOST/GROK | Old LM Studio chats keep stale system prompt until new chat |
| Permissive tools | Not multi-tenant safe |

## Non-goals (current)

- Cloud multi-user control plane  
- Strong sandbox / container isolation  
- Embedding or fine-tuning models  
- One-click Mac installer (roadmap only)

## Evolution path

See [ROADMAP.md](ROADMAP.md) for installer packaging, cross-platform RAM disk abstractions, and thinner default tool packs.
