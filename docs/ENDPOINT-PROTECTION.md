# Endpoint protection & Login Items (managed Mac)

This machine runs a corporate stack that can blank or block the local dashboard:

| Product | Type | Where to manage |
|---------|------|-----------------|
| **CrowdStrike Falcon** | Endpoint Security Extension | System Settings → General → **Login Items & Extensions** → Endpoint Security Extensions |
| **Jamf Protect** | Endpoint Security Extension | same |
| **Palo Alto Cortex / Traps** | Endpoint Security + Network Extension | Endpoint Security + Network Extensions |
| **GlobalProtect** | Network Extension | Network Extensions |
| **macOS Application Firewall** | Host firewall | System Settings → Network → Firewall |

We **do not** install a custom Endpoint Security extension (that requires Apple entitlements + IT signing).
We install a normal **Login Item / LaunchAgent** and document allowlists for IT.

## Symptoms

- Chrome shows a **blank page** on `http://127.0.0.1:7788/`
- Safari is unreliable for this UI — **use Google Chrome** with `127.0.0.1` (not `localhost`)
- `connection refused` when manager is not running
- Silent block of ad-hoc unsigned binaries under Falcon / Protect / Cortex

## Correct binary path

**Do not** use:

- `~/.forge-conductor/bin/forge-serve` / `forge-serve-fallback` (removed legacy bash→Python launchers)
- `~/.local/bin/forge-conductor` if it still symlinks to
  `~/Library/Application Support/ForgeConductor/app/.venv/bin/forge-conductor` (old Python)

Canonical Swift binary after install:

```text
~/.forge-conductor/bin/forge-conductor
```

LM Studio `~/.lmstudio/mcp.json` entry (written by `forge-conductor install`):

```json
"forge-conductor": {
  "command": "/Users/<you>/.forge-conductor/bin/forge-conductor",
  "args": ["serve"]
}
```

Convenience link:

```text
~/.local/bin/forge-conductor-swift
```

## Install + login start

```bash
cd /Users/jim.daley/Forge-Conductor
swift build -c release
.build/release/forge-conductor install --from .build/release/forge-conductor

# Remove legacy agents that appear as "bash" / "python3" in Login Items
~/.forge-conductor/bin/forge-conductor manager cleanup-stale

# Install app bundle + LaunchAgent (shows as "Forge Conductor")
~/.forge-conductor/bin/forge-conductor manager install-login

~/.forge-conductor/bin/forge-conductor manager allowlist
~/.forge-conductor/bin/forge-conductor doctor
```

### Why it did not show before

Legacy LaunchAgents (`com.forge.orchestrator`, `com.forge.telemetry`, `com.forge.watchdog`)
ran `/bin/bash` scripts, so Login Items listed them as **bash** / **python3**.

The Swift installer now creates:

- `~/.forge-conductor/Forge Conductor.app` (display name for Login Items)
- `~/Library/LaunchAgents/com.forge-conductor.manager.plist` with `AssociatedBundleIdentifiers`

Look under **Allow in the Background** for **Forge Conductor** (not under Endpoint Security Extensions — those are Falcon/Jamf/Cortex only).

Ghost entries for removed agents can linger until **log out/in** or reboot.

Open UI (Chrome only):

```bash
open -a "Google Chrome" http://127.0.0.1:7788/
```

## Login Items & Extensions (what you enable)

1. Open **System Settings → General → Login Items & Extensions**.
2. **Allow in the Background**: allow `forge-conductor` / `com.forge-conductor.manager` when macOS prompts after `install-login`.
3. **Endpoint Security Extensions**: keep Falcon / Jamf Protect / Cortex **enabled** (IT requirement).
   If they are disabled, the Mac may be non-compliant — do not turn them off to “fix” Forge; request an **exception** instead.
4. **Network Extensions**: GlobalProtect / Cortex can interfere with loopback. If localhost is blocked, open an IT ticket.

## Ask IT for allowlist

Send this package:

| Item | Value |
|------|--------|
| Process image | `/Users/jim.daley/.forge-conductor/bin/forge-conductor` |
| Parent | `launchd` (`com.forge-conductor.manager`) |
| Listen | `127.0.0.1:7788` (or your `dashboard.port`) TCP |
| Purpose | Local operator dashboard / MCP control plane (loopback only) |
| Code signature | Ad-hoc (Swift SPM). Upgrade to Developer ID if policy requires |

Products: CrowdStrike Falcon prevention/IOA, Jamf Protect analytics, Cortex XDR local network, macOS firewall.

## Port conflict (old Forge telemetry)

Legacy LaunchAgent `com.forge.telemetry` runs Node telemetry on **port 7788** while LM Studio is up. That collides with the Swift manager.

Options:

1. Stop legacy agent: `launchctl bootout gui/$(id -u)/com.forge.telemetry`
2. Or change Swift port in `~/.forge-conductor/config.json`:

```json
"dashboard": { "host": "127.0.0.1", "port": 7790 }
```

Then reinstall login agent and open `http://127.0.0.1:7790/`.

## Firewall CLI (if admin allowed)

```bash
BIN="$HOME/.forge-conductor/bin/forge-conductor"
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "$BIN"
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "$BIN"
```
