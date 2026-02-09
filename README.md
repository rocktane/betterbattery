# BetterBattery

Menu bar app for macOS that limits battery charging via SMC to preserve battery health.

**Apple Silicon only** (M1 and later). Does not work on Intel Macs.

## What it does

- Stops charging at a configurable percentage (default 80%) and resumes when it drops below the lower threshold (hysteresis to avoid on/off flickering)
- Thermal protection: pauses charging above 40°C, resumes below 35°C
- Top Up mode: temporarily charge to 100% when you need it, auto-resets when you unplug
- Controls the MagSafe LED color to reflect charging state
- Optionally stops charging before sleep so macOS doesn't charge to 100% overnight
- Low Power Mode toggle
- Launch at login

## Requirements

- macOS 12+
- Apple Silicon (M1, M2, M3, ...)
- The [`smc`](https://github.com/beltex/SMCKit) command-line tool installed at `/usr/local/bin/smc`

## Install

### Homebrew (recommended)

```bash
brew install --cask rocktane/tap/betterbattery
```

### Manual

Download the latest release from the [Releases](../../releases) page, unzip, and move `BetterBattery.app` to `/Applications`.

### From source

```bash
make build
make install
```

On first launch the app will ask for your admin password to install a sudoers entry (needed to talk to the SMC).

Since the app is unsigned, you'll need to right-click > Open the first time.

## Uninstall

```
make uninstall
```

This removes the app, the LaunchAgent, and the sudoers entry.

## How it works

The app reads battery info through IOKit and controls charging by writing to SMC keys (`CHTE`, `CHIE`, `ACLC`) via the `smc` binary with passwordless sudo. Settings are stored in UserDefaults.

## License

MIT
