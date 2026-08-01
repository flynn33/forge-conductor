# Forge-Conductor Apple Icon Pack

A macOS application icon pack for **Forge-Conductor**, a Mac orchestration-server application.

## Included

- `Forge-Conductor.icns` — ready for a macOS app bundle.
- `Forge-Conductor.iconset/` — complete Apple iconset source.
- `Assets.xcassets/AppIcon.appiconset/` — Xcode-ready macOS AppIcon asset catalog.
- `png/` — standalone PNG exports from 16 through 1024 pixels.
- `preview/forge-conductor-icon-pack-preview.png` — presentation sheet.

## Xcode installation

1. Open the project asset catalog.
2. Replace the existing `AppIcon.appiconset` with the included folder, or copy its images and `Contents.json` into the existing AppIcon set.
3. Confirm the target's **App Icons Source** points to `AppIcon`.

## Direct `.icns` installation

Add `Forge-Conductor.icns` to the application target and set:

```xml
<key>CFBundleIconFile</key>
<string>Forge-Conductor</string>
```

For modern Xcode projects, the asset-catalog method is preferred.

## Visual concept

The icon combines a forged anvil with a conductor's baton and orchestration ring. The visual language represents controlled execution, durable infrastructure, and coordinated agent or service workflows.
