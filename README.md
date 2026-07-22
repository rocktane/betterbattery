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

- macOS 13+
- Apple Silicon (M1, M2, M3, ...)

## Install

### Homebrew (recommended)

```bash
brew install --cask rocktane/tap/betterbattery
```

### Manual

Download the latest release from the [Releases](../../releases) page, unzip, and move `BetterBattery.app` to `/Applications`.

### From source

```bash
make cert      # one-time: create a local self-signed signing certificate
make build
make install
```

On first launch, approve the background helper in System Settings → General → Login Items & Extensions → "Allow in the Background" if prompted.

Since the app is not notarized, you'll need to right-click > Open the first time.

If you're upgrading from a version that used sudo, the app will ask for your admin password once to remove the old `/etc/sudoers.d/battery` entry. The `/usr/local/bin/smc` tool is no longer needed and can be removed manually.

## Uninstall

```
make uninstall
```

This removes the app, the LaunchAgent, the helper daemon registration, and any legacy sudoers entry.

## How it works

The app reads battery info through IOKit. Charging is controlled by a small privileged helper daemon (registered via `SMAppService`, running on demand) that writes SMC keys (`CHTE`, `CHIE`, `ACLC`) directly through IOKit. The app talks to the helper over XPC; the helper only accepts connections from the signed app and only allows a fixed whitelist of SMC keys and values. No sudo involved. Settings are stored in UserDefaults.

## License

MIT
