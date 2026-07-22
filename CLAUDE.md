# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
make cert           # One-time: create the self-signed code-signing certificate
make build          # Compile → build/BetterBattery.app (app + privileged helper)
make install        # Copy to /Applications (required for the daemon to register)
make clean          # Remove build/
make uninstall      # Remove app, LaunchAgent, daemon registration, legacy sudoers
```

Compilation uses `swiftc` directly with `-O -whole-module-optimization` — two invocations, one for the app (Sources/ + Shared/), one for the privileged helper (Helper/ + Shared/). No Xcode project or Swift Package Manager. Both binaries are signed with a local self-signed certificate (`BetterBattery Signing`, created by `make cert`); the helper pins this certificate's SHA-1 (injected at build time into `build/CertHash.swift`) for XPC client validation.

## Architecture

BetterBattery is a macOS menu bar utility (LSUIElement, no Dock icon) that monitors battery state and can limit charging via SMC to extend battery lifespan. Requires macOS 13+.

Privileged operations go through a **root helper daemon** (`com.betterbattery.helper`, registered via `SMAppService.daemon`, embedded at `Contents/Library/LaunchDaemons/`) that talks to AppleSMC directly via IOKit. No sudo, no sudoers, no external smc binary. The app talks to the daemon over XPC (`com.betterbattery.helper.xpc`); the daemon validates each connection via audit token + code-signing requirement (pinned cert + bundle id) and enforces a whitelist of SMC keys/values server-side.

### Component Flow

```
AppDelegate (orchestrator)
  ├→ BatteryReader     — IOKit listener for power source changes, reads IOPowerSources + AppleSmartBattery
  ├→ ChargeLimiter     — hysteresis state machine (limit ±5% bands) that toggles charging via SMC
  ├→ SMCController     — synchronous XPC facade over the helper daemon; same public API as before
  ├→ StatusBarController — NSStatusItem + NSMenu, rebuilds menu on every update
  │   └→ BatteryIconView — CoreGraphics custom NSView (battery shape + bolt/pause overlays)
  ├→ LaunchAtLogin      — writes/deletes ~/Library/LaunchAgents/com.betterbattery.plist
  └→ Setup              — HelperManager (SMAppService registration/approval) + LegacyCleanup (one-time removal of old sudoers/Keychain hash)

Helper/ (root daemon, on-demand via launchd)
  ├→ main.swift        — NSXPCListener + audit-token client validation (SecCodeCheckValidity)
  ├→ HelperService     — HelperProtocol impl: whitelist, read-after-write verified SMC writes, pmset lowpowermode
  └→ SMCKernel         — raw IOKit AppleSMC user client (80-byte SMCParamStruct, selectors read/write/keyinfo)
```

### Communication Pattern

Components communicate via **closures**, not delegates or NotificationCenter:
- `BatteryReader.onUpdate` → triggers `StatusBarController.update()` + `ChargeLimiter.check()`
- `ChargeLimiter.onStateChange` → triggers UI refresh
- All callbacks use `[weak self]` to prevent retain cycles

### Key Design Details

- **BatteryState** is a struct that flows immutably from BatteryReader through the system
- **ChargeLimiter** uses hysteresis (upper = limit+5%, lower = limit-5%) to prevent charge/discharge oscillation
- **The helper daemon** detects hardware on first request: Tahoe keys (`CHTE`, `CHIE`, `ACLC`) for Apple Silicon, legacy keys (`CH0B`, `CH0C`, `CH0I`) for Intel — via IOKit directly
- **LegacyCleanup** uses `NSAppleScript` once to remove the old `/etc/sudoers.d/battery` with an admin prompt
- Settings persist via `UserDefaults` (charge limit %, display mode, setup completion flag)
