# Packaging guide

## What to ship

| Include | Source in this repo |
|---------|---------------------|
| Python package | `packages/forge_conductor/` |
| Tests (optional for end users) | `tests/` |
| Home template | `home-template/` (scripts, telemetry static, defaults) |
| Docs | `docs/` |

## What never to ship

- `secrets.env`, API keys  
- Live `store.sqlite` / user memory corpora from a personal rig  
- `logs/**`  
- `durable/snapshots/**` (user data)  
- `telemetry/node_modules` (run `npm ci` on target)  
- Hard-coded absolute paths unique to one developer (generate at install)

## Windows install sketch

1. Detect Python 3.12+, Node 20+, optional ImDisk.  
2. `pip install` / `uv sync` into app `.venv`.  
3. Copy home-template → `~/.forge-conductor` if missing.  
4. Rewrite `bin/*.cmd` and scripts with install paths.  
5. `npm ci --prefix telemetry`.  
6. Register `ForgeRigTelemetry` + `ForgeRamdiskElevated` tasks.  
7. `forge-conductor register lmstudio` (optional).  

## Mac install sketch (future)

1. Same Python package.  
2. Replace ImDisk scripts with platform provider.  
3. LaunchAgent for telemetry.  
4. No drive-letter semantics — use mount path under `/Volumes` or app cache.

## Versioning

Align package version in `pyproject.toml` with GitHub releases. Keep `agent_backend.json` `version` field independent (schema version).
