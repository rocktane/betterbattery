import Cocoa

enum MenuBarDisplayMode: Int {
    case percentage = 0
    case timeRemaining = 1
    case iconOnly = 2
}

class StatusBarController {
    private var statusItem: NSStatusItem!
    private var iconView: BatteryIconView!
    private let batteryReader: BatteryReader
    private let chargeLimiter: ChargeLimiter
    private let smc: SMCController
    private let defaults = UserDefaults.standard

    private var currentState = BatteryState()
    private var displayMode: MenuBarDisplayMode = .percentage
    private let batteryHistory = BatteryHistory()

    // Auto Low Power Mode
    private enum AutoLPMState { case idle, activated, userOverridden }
    private var autoLPMThreshold: Int = 0  // 0 = disabled
    private var autoLPMState: AutoLPMState = .idle

    init(batteryReader: BatteryReader, chargeLimiter: ChargeLimiter, smc: SMCController) {
        self.batteryReader = batteryReader
        self.chargeLimiter = chargeLimiter
        self.smc = smc

        let savedMode = defaults.integer(forKey: "displayMode")
        displayMode = MenuBarDisplayMode(rawValue: savedMode) ?? .percentage

        let savedLPM = defaults.integer(forKey: "autoLPMThreshold")
        autoLPMThreshold = [0, 10, 20, 30, 40, 50].contains(savedLPM) ? savedLPM : 0

        setupStatusItem()

        chargeLimiter.onStateChange = { [weak self] in
            guard let self = self else { return }
            self.update(state: self.currentState)
        }

        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.update(state: self.currentState)
        }
    }

    func update(state: BatteryState) {
        currentState = state
        batteryHistory.record(percentage: state.percentage, isCharging: state.isCharging)

        iconView.update(
            percentage: state.percentage,
            isCharging: state.isCharging,
            isPluggedIn: state.isPluggedIn,
            chargeLimitActive: chargeLimiter.isActive && !chargeLimiter.chargingEnabled,
            topUpActive: chargeLimiter.topUpActive,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )

        updateStatusBarImage(state: state)
        checkAutoLPM(percentage: state.percentage)
        rebuildMenu()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        iconView = BatteryIconView()
        rebuildMenu()
    }

    // MARK: - Smart time remaining

    /// Returns the effective time remaining and label based on charge limiter state.
    private func effectiveTimeRemaining() -> (minutes: Int, label: String)? {
        let state = currentState

        if !state.isPluggedIn {
            // Discharging on battery
            guard let minutes = state.timeToEmpty, minutes > 0, minutes < 6000 else { return nil }
            return (minutes, "remaining")
        }

        // Plugged in
        if chargeLimiter.topUpActive {
            // Top up: show time to 100%
            guard state.percentage < 100,
                  let timeToCharge = state.timeToCharge, timeToCharge > 0, timeToCharge < 6000 else { return nil }
            return (timeToCharge, "until full")
        }

        if chargeLimiter.isActive {
            // Limit active
            if chargeLimiter.thermalHold { return nil }
            guard chargeLimiter.chargingEnabled else { return nil } // paused at/above upperBound

            let upper = chargeLimiter.upperBound
            guard state.percentage < upper,
                  let timeToCharge = state.timeToCharge, timeToCharge > 0, timeToCharge < 6000,
                  state.percentage < 100 else { return nil }

            // Linear approximation: scale IOKit's time-to-100% to time-to-upperBound
            let remaining = upper - state.percentage
            let total = 100 - state.percentage
            let estimated = Int(round(Double(timeToCharge) * Double(remaining) / Double(total)))
            guard estimated > 0 else { return nil }
            return (estimated, "until \(upper)%")
        }

        // No limit active
        if state.isCharging {
            guard let timeToCharge = state.timeToCharge, timeToCharge > 0, timeToCharge < 6000 else { return nil }
            return (timeToCharge, "until full")
        }

        return nil
    }

    private func formatMinutes(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 {
            return "\(h):\(String(format: "%02d", m))"
        }
        return "0:\(String(format: "%02d", m))"
    }

    // MARK: - Composite image (text + battery icon in one image, tight spacing)

    private func updateStatusBarImage(state: BatteryState) {
        guard let button = statusItem.button else { return }

        let text: String?
        switch displayMode {
        case .percentage:
            text = "\(state.percentage)%"
        case .timeRemaining:
            if let time = effectiveTimeRemaining() {
                text = formatMinutes(time.minutes)
            } else {
                text = nil
            }
        case .iconOnly:
            text = nil
        }

        let batteryImage = iconView.toImage()
        button.image = compositeImage(text: text, batteryImage: batteryImage)
        button.title = ""
    }

    private func compositeImage(text: String?, batteryImage: NSImage) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor
        ]

        let textSize: CGSize
        if let text = text, !text.isEmpty {
            textSize = (text as NSString).size(withAttributes: attrs)
        } else {
            textSize = .zero
        }

        let gap: CGFloat = textSize.width > 0 ? 2 : 0
        let totalWidth = textSize.width + gap + batteryImage.size.width
        let totalHeight = batteryImage.size.height

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { rect in
            if let text = text, !text.isEmpty {
                let textY = (totalHeight - textSize.height) / 2
                (text as NSString).draw(at: NSPoint(x: 0, y: textY), withAttributes: attrs)
            }

            let iconX = textSize.width + gap
            batteryImage.draw(
                in: NSRect(x: iconX, y: 0, width: batteryImage.size.width, height: batteryImage.size.height),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // ── Battery info section ──

        func infoItem(_ text: String, bold: Bool = false) -> NSMenuItem {
            let label = NSTextField(labelWithString: text)
            label.font = bold ? NSFont.boldSystemFont(ofSize: 13) : NSFont.menuFont(ofSize: 13)
            label.textColor = .labelColor
            label.sizeToFit()
            let container = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.width + 40, height: label.frame.height + 4))
            label.frame.origin = CGPoint(x: 20, y: 2)
            container.addSubview(label)
            let item = NSMenuItem()
            item.view = container
            return item
        }

        // Line 1: 94% — Paused (bold)
        let statusText: String
        if chargeLimiter.thermalHold && currentState.isPluggedIn {
            statusText = "Paused (🔥)"
        } else if chargeLimiter.topUpActive && currentState.isPluggedIn {
            statusText = "Topping Up"
        } else if chargeLimiter.isActive && !chargeLimiter.chargingEnabled && currentState.isPluggedIn {
            statusText = "Paused"
        } else if currentState.isCharging {
            statusText = "Charging"
        } else if currentState.isPluggedIn {
            statusText = "Power Adapter"
        } else {
            statusText = "Battery"
        }
        menu.addItem(infoItem("\(currentState.percentage)% — \(statusText)", bold: true))

        // Line 2: 1:32 until 85% (optional, context-aware)
        if let time = effectiveTimeRemaining() {
            menu.addItem(infoItem("\(formatMinutes(time.minutes)) \(time.label)"))
        }

        // Line 3: Power adapter: 60W (when plugged in)
        if currentState.isPluggedIn && currentState.adapterWatts > 0 {
            menu.addItem(infoItem("Power adapter: \(currentState.adapterWatts)W"))
        }

        // Line 4: 30°C • 12.44V • 0W
        let power = Int(round(currentState.voltage * (Double(abs(currentState.amperage)) / 1000.0)))
        let temp = Int(round(currentState.temperature))
        menu.addItem(infoItem(String(format: "%d°C • %.2fV • %dW", temp, currentState.voltage, power)))

        // Line 5: Health: 77% (538 cycles)
        menu.addItem(infoItem("Health: \(currentState.health)% (\(currentState.cycleCount) cycles)"))

        // Line 6: Uptime: 6d 0h 42min
        let uptime = ProcessInfo.processInfo.systemUptime
        menu.addItem(infoItem("Uptime: \(formatUptime(uptime))"))

        // Battery history graph
        let graphWidth: CGFloat = 280
        let graphHeight: CGFloat = 120
        let graphView = BatteryGraphView(frame: NSRect(x: 0, y: 0, width: graphWidth, height: graphHeight))
        graphView.history = batteryHistory
        let graphContainer = NSView(frame: NSRect(x: 0, y: 0, width: graphWidth + 20, height: graphHeight + 8))
        graphView.frame.origin = CGPoint(x: 10, y: 4)
        graphContainer.addSubview(graphView)
        let graphItem = NSMenuItem()
        graphItem.view = graphContainer
        menu.addItem(graphItem)

        menu.addItem(.separator())

        // ── Charge control section ──

        let limitItem = NSMenuItem(
            title: chargeLimiter.isActive ? "Limit active at \(chargeLimiter.limitPercentage)%" : "Limit to \(chargeLimiter.limitPercentage)%",
            action: #selector(toggleChargeLimit),
            keyEquivalent: ""
        )
        limitItem.target = self
        limitItem.state = chargeLimiter.isActive ? .on : .off
        menu.addItem(limitItem)

        // Top Up — only when limiter is active
        if chargeLimiter.isActive {
            let topUpTitle = chargeLimiter.topUpActive ? "Top Up in progress..." : "Top Up (charge to 100%)"
            let topUpItem = NSMenuItem(title: topUpTitle, action: #selector(toggleTopUp), keyEquivalent: "")
            topUpItem.target = self
            topUpItem.state = chargeLimiter.topUpActive ? .on : .off
            menu.addItem(topUpItem)
        }

        menu.addItem(.separator())

        // ── Settings section ──

        // Display mode submenu
        let displaySubmenu = NSMenu()
        let modes: [(String, MenuBarDisplayMode)] = [
            ("Percentage", .percentage),
            ("Time remaining", .timeRemaining),
            ("Icon only", .iconOnly)
        ]
        for (title, mode) in modes {
            let item = NSMenuItem(title: title, action: #selector(setDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            item.state = displayMode == mode ? .on : .off
            displaySubmenu.addItem(item)
        }
        let displayItem = NSMenuItem(title: "Menu bar display", action: nil, keyEquivalent: "")
        displayItem.submenu = displaySubmenu
        menu.addItem(displayItem)

        // Limit submenu
        let limitSubmenu = NSMenu()
        for limit in [60, 70, 80, 90, 100] {
            let item = NSMenuItem(title: "\(limit)%", action: #selector(setLimit(_:)), keyEquivalent: "")
            item.target = self
            item.tag = limit
            item.state = chargeLimiter.limitPercentage == limit ? .on : .off
            limitSubmenu.addItem(item)
        }
        let limitMenuItem = NSMenuItem(title: "Change limit...", action: nil, keyEquivalent: "")
        limitMenuItem.submenu = limitSubmenu
        menu.addItem(limitMenuItem)

        // Amplitude submenu
        let amplitudeSubmenu = NSMenu()
        let currentLimit = chargeLimiter.limitPercentage
        for amp in [2, 5, 8, 10] {
            let lower = max(0, currentLimit - amp)
            let upper = min(100, currentLimit + amp)
            let item = NSMenuItem(
                title: "±\(amp)% (\(lower)-\(upper)%)",
                action: #selector(setAmplitude(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = amp
            item.state = chargeLimiter.hysteresisAmplitude == amp ? .on : .off
            amplitudeSubmenu.addItem(item)
        }
        let ampItem = NSMenuItem(title: "Amplitude (±\(chargeLimiter.hysteresisAmplitude)%)", action: nil, keyEquivalent: "")
        ampItem.submenu = amplitudeSubmenu
        menu.addItem(ampItem)

        menu.addItem(.separator())

        // Stop charging before sleep toggle
        let sleepItem = NSMenuItem(
            title: "Stop charging on sleep",
            action: #selector(toggleStopChargingBeforeSleep),
            keyEquivalent: ""
        )
        sleepItem.target = self
        sleepItem.state = chargeLimiter.stopChargingBeforeSleep ? .on : .off
        menu.addItem(sleepItem)

        // Auto Low Power Mode submenu
        let autoLPMSubmenu = NSMenu()
        let lpmOptions: [(String, Int)] = [
            ("Désactivé", 0), ("10%", 10), ("20%", 20),
            ("30%", 30), ("40%", 40), ("50%", 50)
        ]
        for (title, value) in lpmOptions {
            let item = NSMenuItem(title: title, action: #selector(setAutoLPMThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            item.state = autoLPMThreshold == value ? .on : .off
            autoLPMSubmenu.addItem(item)
        }
        let autoLPMItem = NSMenuItem(title: "Auto Low Power Mode", action: nil, keyEquivalent: "")
        autoLPMItem.submenu = autoLPMSubmenu
        autoLPMItem.state = autoLPMThreshold > 0 ? .on : .off
        menu.addItem(autoLPMItem)

        // Low Power Mode toggle
        let lowPowerItem = NSMenuItem(
            title: "Low Power Mode",
            action: #selector(toggleLowPowerMode),
            keyEquivalent: ""
        )
        lowPowerItem.target = self
        lowPowerItem.state = ProcessInfo.processInfo.isLowPowerModeEnabled ? .on : .off
        menu.addItem(lowPowerItem)

        // Launch at login
        let launchItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())

        // About
        let aboutItem = NSMenuItem(title: "About BetterBattery", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        // Uninstall
        let uninstallItem = NSMenuItem(title: "Uninstall", action: #selector(uninstall), keyEquivalent: "")
        uninstallItem.target = self
        menu.addItem(uninstallItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleChargeLimit() {
        if chargeLimiter.isActive {
            chargeLimiter.stop()
        } else {
            chargeLimiter.start()
        }
        rebuildMenu()
    }

    @objc private func toggleTopUp() {
        if chargeLimiter.topUpActive {
            chargeLimiter.deactivateTopUp()
        } else {
            chargeLimiter.activateTopUp()
        }
        rebuildMenu()
    }

    @objc private func setDisplayMode(_ sender: NSMenuItem) {
        displayMode = MenuBarDisplayMode(rawValue: sender.tag) ?? .percentage
        defaults.set(displayMode.rawValue, forKey: "displayMode")
        update(state: currentState)
    }

    @objc private func setLimit(_ sender: NSMenuItem) {
        chargeLimiter.limitPercentage = sender.tag
        if chargeLimiter.isActive {
            chargeLimiter.check(percentage: currentState.percentage, isPluggedIn: currentState.isPluggedIn, temperature: currentState.temperature)
        }
        rebuildMenu()
    }

    @objc private func setAmplitude(_ sender: NSMenuItem) {
        chargeLimiter.hysteresisAmplitude = sender.tag
        if chargeLimiter.isActive {
            chargeLimiter.check(percentage: currentState.percentage, isPluggedIn: currentState.isPluggedIn, temperature: currentState.temperature)
        }
        rebuildMenu()
    }

    @objc private func toggleStopChargingBeforeSleep() {
        chargeLimiter.stopChargingBeforeSleep.toggle()
        rebuildMenu()
    }

    @objc private func toggleLowPowerMode() {
        let enable = !ProcessInfo.processInfo.isLowPowerModeEnabled
        setLowPowerMode(enable)

        // If auto-LPM activated and user manually toggles, stop auto from re-enabling
        if autoLPMState == .activated {
            autoLPMState = .userOverridden
        }
    }

    @objc private func setAutoLPMThreshold(_ sender: NSMenuItem) {
        autoLPMThreshold = sender.tag
        defaults.set(autoLPMThreshold, forKey: "autoLPMThreshold")
        autoLPMState = .idle
        rebuildMenu()
    }

    private func checkAutoLPM(percentage: Int) {
        guard autoLPMThreshold > 0, percentage > 0 else { return }

        let disableThreshold = autoLPMThreshold + 20
        let isPluggedIn = currentState.isPluggedIn

        switch autoLPMState {
        case .idle:
            if percentage <= autoLPMThreshold && !isPluggedIn {
                setLowPowerMode(true)
                autoLPMState = .activated
            }
        case .activated:
            if percentage >= disableThreshold || isPluggedIn {
                setLowPowerMode(false)
                autoLPMState = .idle
            }
        case .userOverridden:
            if percentage >= disableThreshold || isPluggedIn {
                autoLPMState = .idle
            }
        }
    }

    private func setLowPowerMode(_ enabled: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "lowpowermode", enabled ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.update(state: self.currentState)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        if LaunchAtLogin.isEnabled {
            LaunchAtLogin.disable()
        } else {
            LaunchAtLogin.enable()
        }
        rebuildMenu()
    }

    @objc private func showAbout() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "About BetterBattery"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.center()

        let contentView = NSView(frame: panel.contentView!.bounds)

        // App icon
        let iconView = NSImageView(frame: NSRect(x: 126, y: 170, width: 48, height: 48))
        iconView.image = NSApp.applicationIconImage
        contentView.addSubview(iconView)

        // App name
        let nameLabel = NSTextField(labelWithString: "BetterBattery")
        nameLabel.font = NSFont.boldSystemFont(ofSize: 16)
        nameLabel.alignment = .center
        nameLabel.frame = NSRect(x: 0, y: 142, width: 300, height: 22)
        contentView.addSubview(nameLabel)

        // Version
        let versionLabel = NSTextField(labelWithString: "v1.1.1")
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.frame = NSRect(x: 0, y: 122, width: 300, height: 18)
        contentView.addSubview(versionLabel)

        // Description
        let descLabel = NSTextField(labelWithString: "Monitor and limit battery charging on macOS")
        descLabel.font = NSFont.systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        descLabel.alignment = .center
        descLabel.frame = NSRect(x: 0, y: 96, width: 300, height: 18)
        contentView.addSubview(descLabel)

        // Author
        let authorLabel = NSTextField(labelWithString: "By rocktane")
        authorLabel.font = NSFont.systemFont(ofSize: 12)
        authorLabel.alignment = .center
        authorLabel.frame = NSRect(x: 0, y: 70, width: 300, height: 18)
        contentView.addSubview(authorLabel)

        // GitHub link
        let linkLabel = NSTextField(labelWithAttributedString: NSAttributedString(
            string: "github.com/rocktane/betterbattery",
            attributes: [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .font: NSFont.systemFont(ofSize: 12),
                .cursor: NSCursor.pointingHand
            ]
        ))
        linkLabel.alignment = .center
        linkLabel.frame = NSRect(x: 0, y: 48, width: 300, height: 18)
        linkLabel.isSelectable = false
        contentView.addSubview(linkLabel)

        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(openGitHub))
        linkLabel.addGestureRecognizer(clickGesture)

        // License
        let licenseLabel = NSTextField(labelWithString: "MIT License")
        licenseLabel.font = NSFont.systemFont(ofSize: 11)
        licenseLabel.textColor = .tertiaryLabelColor
        licenseLabel.alignment = .center
        licenseLabel.frame = NSRect(x: 0, y: 20, width: 300, height: 16)
        contentView.addSubview(licenseLabel)

        panel.contentView = contentView
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/rocktane/betterbattery")!)
    }

    @objc private func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Better Battery?"
        alert.informativeText = "This will remove the app, LaunchAgent, and restore normal charging."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            // Re-enable charging
            _ = smc.enableCharging()
            smc.setMagSafeLED(.system)

            // Remove LaunchAgent
            LaunchAtLogin.disable()

            // Remove sudoers
            let script = "do shell script \"rm -f /etc/sudoers.d/battery\" with administrator privileges"
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }

            // Remove app
            let appPath = Bundle.main.bundlePath
            try? FileManager.default.removeItem(atPath: appPath)

            NSApp.terminate(nil)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h \(String(format: "%02d", minutes))min"
        } else if hours > 0 {
            return "\(hours)h \(String(format: "%02d", minutes))min"
        }
        return "\(minutes)min"
    }
}
