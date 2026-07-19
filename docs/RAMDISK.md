# RAM disk orchestration

## Intent

On **LOAD**, materialize the **entire live package** (app + venv + home state) onto a **true RAM volume** (Windows: ImDisk). On **UNLOAD**, snapshot durable state to disk and destroy the volume.

This is stronger than “process RAM caches only”: tools and launchers resolve paths under `R:\app` and `R:\home`.

## Defaults (config)

`ramdisk-config.json`:

| Key | Typical |
|-----|---------|
| letter | `R` |
| size_gb | 16 (min 16, max 32) |
| snapshot_interval_sec | 30 |
| tier_chunk_gb | 1 |
| durable_root | `~/.forge-conductor/durable` |

## Lifecycle

1. **ensure-image** — robocopy package into `durable/image/app`  
2. **create** — ImDisk volume (elevated)  
3. **hydrate** — copy image + `durable/state/current` → live  
4. **keepers + supervise** — start MCP keepers; periodic snapshot + tier  
5. **unload** — final snapshot → stop processes → destroy volume  

## Elevation

ImDisk NTFS format requires admin. Dashboard LOAD often runs **non-elevated**.

**Solution:** scheduled task `ForgeRamdiskElevated` → `forge-ramdisk-elevated-ops.ps1` with ops JSON request/response under `logs/`.

Install once (admin):

```powershell
pwsh -File $env:USERPROFILE\.forge-conductor\scripts\install-forge-ramdisk-elevated-task.ps1
```

## Snapshots & tiering

- Snapshot: sqlite checkpoint + copy corpora/config/agents/`agent_backend.json`  
- Tier: when free space low, move oldest logs/cache in ~1 GB chunks to `durable/tiered`  

## Failure modes

| Symptom | Cause | Mitigation |
|---------|-------|------------|
| timeout waiting for R: | format Access Denied / orphan ImDisk units | elevated task; cleanup ops |
| letter conflict | stale ImDisk devices | elevated `cleanup` / destroy |
| hydrate slow | large venv | image cache in durable |

## Mac note

ImDisk is Windows-specific. Product packaging must abstract “volatile volume” (e.g. ramdisk tools, tmpfs-like mounts, or process-RAM-only fallback on macOS).
