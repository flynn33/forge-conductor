# Roadmap — installable Windows / Mac product

## Phase 0 — Documentation & open source skeleton (current)

- [x] Public GitHub repo (productization docs + vendored source)  
- [x] Architecture / design / packaging docs  
- [x] Template home + Python package snapshot  
- [ ] LICENSE, CONTRIBUTING, CI  

## Phase 1 — Clean Windows portable installer

- [ ] Single installer (zip or setup.exe) producing:
  - app install under `%LOCALAPPDATA%\ForgeConductor`
  - home under `%USERPROFILE%\.forge-conductor`
  - ImDisk dependency check / optional installer chain  
  - elevated task registration  
  - telemetry autostart  
- [ ] `forge doctor` first-run wizard  
- [ ] Signed scripts / SmartScreen notes  

## Phase 2 — Host UX polish

- [ ] Reduce default tool count / progressive disclosure  
- [ ] Fix connect-prompt “stack loaded” live probe accuracy  
- [ ] Dashboard: job queue viewer for Grok Build  
- [ ] Optional merge of ram-memory into primary to reduce dual-server confusion  

## Phase 3 — Mac / cross-platform

- [ ] Abstract RAM volume provider (ImDisk | macOS alternative | process-RAM fallback)  
- [ ] LaunchAgents instead of Task Scheduler  
- [ ] Path/shim generators without hard-coded user paths  

## Phase 4 — Application shell

- [ ] Desktop app wrapper (Tauri/Electron) embedding dashboard + first-run  
- [ ] Optional integrated “attach Grok Build” deep link  
- [ ] Update channel / versioned releases  

## Success criteria for “1.0 installer”

1. Fresh Windows 11 machine → install → LOAD → LM Studio connects → tool call works.  
2. GROK mode → connect prompt → Grok Build attach → job complete without API key.  
3. UNLOAD leaves no orphan RAM disks.  
4. No secrets in repo or default templates.
