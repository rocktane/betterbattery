# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
make build          # Compile → build/BetterBattery.app
open build/BetterBattery.app  # Launch the app
make install        # Copy to /Applications
make clean          # Remove build/
make uninstall      # Remove app, LaunchAgent, and sudoers entry
```

Compilation uses `swiftc` directly with `-O -whole-module-optimization` and links Cocoa + IOKit frameworks. No Xcode project or Swift Package Manager — all sources are compiled in a single `swiftc` invocation.

## Architecture

BetterBattery is a macOS menu bar utility (LSUIElement, no Dock icon) that monitors battery state and can limit charging via SMC to extend battery lifespan. Requires macOS 12+.

### Component Flow

```
AppDelegate (orchestrator)
  ├→ BatteryReader     — IOKit listener for power source changes, reads IOPowerSources + AppleSmartBattery
  ├→ ChargeLimiter     — hysteresis state machine (limit ±5% bands) that toggles charging via SMC
  ├→ SMCController     — executes /usr/local/bin/smc binary with sudo; detects Tahoe (Apple Silicon) vs Legacy (Intel) keys
  ├→ StatusBarController — NSStatusItem + NSMenu, rebuilds menu on every update
  │   └→ BatteryIconView — CoreGraphics custom NSView (battery shape + bolt/pause overlays)
  ├→ LaunchAtLogin      — writes/deletes ~/Library/LaunchAgents/com.betterbattery.plist
  └→ Setup              — first-run check: verifies smc binary, installs /etc/sudoers.d/battery via AppleScript
```

### Communication Pattern

Components communicate via **closures**, not delegates or NotificationCenter:
- `BatteryReader.onUpdate` → triggers `StatusBarController.update()` + `ChargeLimiter.check()`
- `ChargeLimiter.onStateChange` → triggers UI refresh
- All callbacks use `[weak self]` to prevent retain cycles

### Key Design Details

- **BatteryState** is a struct that flows immutably from BatteryReader through the system
- **ChargeLimiter** uses hysteresis (upper = limit+5%, lower = limit-5%) to prevent charge/discharge oscillation
- **SMCController** detects hardware at init: Tahoe keys (`CHTE`, `CHIE`, `ACLC`) for Apple Silicon, legacy keys (`CH0B`, `CH0C`, `CH0I`) for Intel — all via an external `smc` CLI tool run with sudo
- **Setup** uses `NSAppleScript` to run privileged commands (sudoers installation) with an admin prompt
- Settings persist via `UserDefaults` (charge limit %, display mode, setup completion flag)
