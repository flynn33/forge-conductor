# Forge Conductor — Xcode

## Open

```bash
open /Users/jim.daley/Forge-Conductor/ForgeConductor.xcworkspace
```

The workspace intentionally contains the single canonical Xcode project. Using
it keeps the entry point stable if additional native modules are added later.

## Schemes (pick the right one)

| Scheme | What it is | How to run |
|--------|------------|------------|
| **ForgeConductor** | Native SwiftUI + Metal **app** | ⌘R — opens the GUI |
| **forge-conductor** | CLI tool | ⌘R with args (`help`, `doctor`, `serve`) |

## Fix that was required

`ForgeConductorCore.framework` is **embedded** in the app (`Contents/Frameworks/`).
The CLI uses `@executable_path` so the framework must sit next to the binary when installed.

## Build / Test

```bash
cd /Users/jim.daley/Forge-Conductor

xcodebuild -project ForgeConductor.xcodeproj \
  -scheme ForgeConductor \
  -destination 'platform=macOS,arch=arm64' \
  build

xcodebuild -project ForgeConductor.xcodeproj \
  -scheme ForgeConductor \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ForgeConductorTests \
  test
```

The command above is headless. The `ForgeConductorUITests` target launches and
foregrounds the real app, so run it only when the Mac's screen is available:

```bash
xcodebuild -project ForgeConductor.xcodeproj \
  -scheme ForgeConductor \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ForgeConductorUITests \
  test
```

Debug app and UI-test targets use “Sign to Run Locally” so a development
certificate is not required. Release distribution still requires the
appropriate Apple signing identity and notarization.

## After building from Xcode

Products land in DerivedData. To install for daily use:

```bash
PROD=$(ls -d ~/Library/Developer/Xcode/DerivedData/ForgeConductor-*/Build/Products/Debug | head -1)
cp -f "$PROD/forge-conductor" ~/.forge-conductor/bin/
cp -R "$PROD/ForgeConductorCore.framework" ~/.forge-conductor/bin/
cp -R "$PROD/Forge Conductor.app" ~/.forge-conductor/
open ~/.forge-conductor/Forge\ Conductor.app
```

Or just **Run** the **ForgeConductor** scheme from Xcode (⌘R).
