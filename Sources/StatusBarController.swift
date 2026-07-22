import Cocoa
import IOKit.pwr_mgt

enum MenuBarDisplayMode: Int {
    case percentage = 0
    case timeRemaining = 1
    case iconOnly = 2
}

/// Borderless panels can't become key by default, which stops their controls from
/// receiving clicks. Allow it (without becoming main / activating the app).
final class DropdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // The dropdown anchors its top edge just under the menu bar and grows downward.
    // Returning the rect unchanged disables AppKit's screen-clamping so the panel keeps
    // the exact frame we set (it never needs to move once positioned).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

/// Theme-aware flat tint over the window's vibrancy: #313131 in dark, lighter grey in light.
private final class WindowTintView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = (dark
            ? NSColor(srgbRed: 0x31/255.0, green: 0x31/255.0, blue: 0x31/255.0, alpha: 0.20)
            : NSColor(srgbRed: 0xD8/255.0, green: 0xD8/255.0, blue: 0xD8/255.0, alpha: 0.20)).cgColor
    }
}

class StatusBarController: NSObject, WidgetActionDelegate {
    private var statusItem: NSStatusItem!
    private var iconView: BatteryIconView!
    private let batteryReader: BatteryReader
    private let chargeLimiter: ChargeLimiter
    private let smc: SMCController
    private let defaults = UserDefaults.standard

    private var currentState = BatteryState()
    private var displayMode: MenuBarDisplayMode = .percentage
    private let batteryHistory = BatteryHistory()

    // Custom widget dropdown (borderless panel — no arrow, fixed position once shown)
    private var panel: DropdownPanel!
    private var effectView: NSVisualEffectView!
    private var widgetVC: WidgetViewController!
    private var globalClickMonitor: Any?
    private var anchorTopY: CGFloat = 0        // screen Y of the panel's top edge, fixed while open
    private var contentSize: NSSize = NSSize(width: 300, height: 300)
    private let windowRadius: CGFloat = 16

    // Auto Low Power Mode
    private enum AutoLPMState { case idle, activated, userOverridden }
    private var autoLPMThreshold: Int = 0  // 0 = disabled
    private var autoLPMState: AutoLPMState = .idle

    // App theme: 0 = system, 1 = light, 2 = dark
    private var appTheme: Int = 0

    // Keep-awake (caffeine) power assertion
    private var caffeineAssertionID: IOPMAssertionID = 0
    private var caffeineActive = false

    init(batteryReader: BatteryReader, chargeLimiter: ChargeLimiter, smc: SMCController) {
        self.batteryReader = batteryReader
        self.chargeLimiter = chargeLimiter
        self.smc = smc
        super.init()

        let savedMode = defaults.integer(forKey: "displayMode")
        displayMode = MenuBarDisplayMode(rawValue: savedMode) ?? .percentage

        let savedLPM = defaults.integer(forKey: "autoLPMThreshold")
        autoLPMThreshold = [0, 10, 20, 30, 40, 50].contains(savedLPM) ? savedLPM : 0

        let savedTheme = defaults.integer(forKey: "appTheme")
        appTheme = [0, 1, 2].contains(savedTheme) ? savedTheme : 0
        applyAppTheme()

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
        checkDischarge(state: state)
        refreshWidget()
        if historyWindow?.isVisible == true {
            historyGraphView?.needsDisplay = true
        }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        iconView = BatteryIconView()

        widgetVC = WidgetViewController()
        widgetVC.delegate = self
        // Assign onResize BEFORE the view ever loads. The first layout is triggered the
        // moment `widgetVC.view` is accessed below; if onResize is still nil at that point,
        // relayout() falls back to setting `preferredContentSize`, which installs an Auto
        // Layout constraint that permanently pins the panel to the collapsed height (the
        // window then snaps back on every setFrame(display:true) via the constraint engine).
        widgetVC.onResize = { [weak self] size in
            self?.resizeDropdown(to: size)
        }

        // Borderless, non-activating panel used as the dropdown (no popover arrow).
        panel = DropdownPanel(contentRect: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height),
                              styleMask: [.borderless, .nonactivatingPanel, .resizable],
                              backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.minSize = NSSize(width: contentSize.width, height: 1)
        panel.maxSize = NSSize(width: contentSize.width, height: 5000)
        panel.contentMinSize = NSSize(width: contentSize.width, height: 1)
        panel.contentMaxSize = NSSize(width: contentSize.width, height: 5000)

        // Rounded container clips both the vibrancy and the content (clipping the
        // NSVisualEffectView directly leaves a faint edge/border).
        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        container.wantsLayer = true
        container.layer?.cornerRadius = windowRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]

        effectView = NSVisualEffectView(frame: container.bounds)
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.autoresizingMask = [.width, .height]
        container.addSubview(effectView)

        // Flat tint at 20% over the vibrancy, under the content:
        // #313131 in dark theme, a lighter grey in light theme.
        let tintView = WindowTintView(frame: container.bounds)
        tintView.autoresizingMask = [.width, .height]
        container.addSubview(tintView)

        widgetVC.view.frame = container.bounds
        widgetVC.view.autoresizingMask = [.width, .height]
        container.addSubview(widgetVC.view)
        panel.contentView = container

        applyAppTheme()

        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - Dropdown

    @objc private func togglePopover() {
        if panel.isVisible {
            closeDropdown()
        } else {
            openDropdown()
        }
    }

    private func openDropdown() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        refreshWidget()
        widgetVC.applyModel(force: true)
        widgetVC.layoutNow()   // capture the current collapsed size before positioning

        // Position under the status item, centred, clamped to the screen. Captured once.
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonScreenRect = buttonWindow.convertToScreen(buttonRectInWindow)
        let screen = buttonWindow.screen ?? NSScreen.main
        let margin: CGFloat = 8
        var x = buttonScreenRect.midX - contentSize.width / 2
        // Top sits just under the menu bar (visibleFrame.maxY = top of the usable area).
        anchorTopY = (screen?.visibleFrame.maxY ?? buttonScreenRect.minY) - 2
        if let visible = screen?.visibleFrame {
            x = min(max(visible.minX + margin, x), visible.maxX - contentSize.width - margin)
        }
        let frame = NSRect(x: x, y: anchorTopY - contentSize.height,
                           width: contentSize.width, height: contentSize.height)
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        installClickMonitor()
    }

    private func closeDropdown() {
        removeClickMonitor()
        panel.orderOut(nil)
        widgetVC.resetSettings()
    }

    /// Resize the panel to the new content size, keeping its top edge fixed (grows downward).
    /// The smooth motion comes from the internal content animation (clipping container +
    /// sliding chevron); the window frame itself snaps (animating it made it jump).
    ///
    /// Growing snaps immediately so the revealed cards animate inside an already-tall window.
    /// Shrinking is deferred until the collapse animation finishes — otherwise the window's
    /// bottom edge crops the cards while they're still sliding out.
    private func resizeDropdown(to size: NSSize) {
        contentSize = size
        guard panel != nil, panel.isVisible else { return }
        let frame = NSRect(x: panel.frame.origin.x, y: anchorTopY - size.height,
                           width: size.width, height: size.height)
        let shrinking = size.height < panel.frame.height
        resizeGeneration += 1
        let gen = resizeGeneration
        let delay = shrinking ? WidgetViewController.detailAnimationDuration : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // Skip a stale deferred shrink if a newer resize (e.g. re-expand) has since run.
            guard let self = self, self.panel != nil, gen == self.resizeGeneration else { return }
            self.panel.setFrame(frame, display: true)
        }
    }
    private var resizeGeneration = 0

    private func installClickMonitor() {
        removeClickMonitor()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.panel.isVisible else { return }
            // Ignore clicks on the status item itself (its button action handles the toggle).
            if let btnFrame = self.statusItem.button?.window?.frame, btnFrame.contains(NSEvent.mouseLocation) {
                return
            }
            self.closeDropdown()
        }
    }

    private func removeClickMonitor() {
        if let m = globalClickMonitor {
            NSEvent.removeMonitor(m)
            globalClickMonitor = nil
        }
    }

    // MARK: - Widget model

    private func refreshWidget() {
        guard widgetVC != nil else { return }
        var model = WidgetModel()
        model.percentage = currentState.percentage
        let status = statusText()
        model.statusText = status.text
        model.showStatusPill = !status.sourceOnly
        model.etaText = etaText()
        model.isCharging = currentState.isCharging
        model.limitActive = chargeLimiter.isActive
        model.limitPercentage = chargeLimiter.limitPercentage
        model.lowerBound = chargeLimiter.lowerBound
        model.upperBound = chargeLimiter.upperBound
        model.topUpActive = chargeLimiter.topUpActive
        model.stopChargingBeforeSleep = chargeLimiter.stopChargingBeforeSleep
        model.lowPowerModeOn = ProcessInfo.processInfo.isLowPowerModeEnabled
        model.displayMode = displayMode
        model.autoLPMThreshold = autoLPMThreshold
        model.launchAtLogin = LaunchAtLogin.isEnabled
        model.appTheme = appTheme
        model.health = currentState.health
        model.cycleCount = currentState.cycleCount
        model.temperature = currentState.temperature
        model.uptime = formatUptimeCompact(bootUptime())
        model.isPluggedIn = currentState.isPluggedIn
        model.adapterWatts = currentState.adapterWatts
        // Actual power drawn by the computer: adapter input when available (works even when
        // the battery isn't charging), otherwise the battery flow (discharge on battery).
        model.drawWatts = currentState.systemPowerIn > 0
            ? Int(round(Double(currentState.systemPowerIn) / 1000.0))
            : Int(round(currentState.voltage * (Double(abs(currentState.amperage)) / 1000.0)))
        model.powerSource = currentState.isPluggedIn ? "AC Power" : "Battery"
        model.caffeineActive = caffeineActive
        model.dischargeActive = dischargeActive

        widgetVC.model = model
        if panel != nil && panel.isVisible {
            widgetVC.applyModel()
        }
    }

    /// Text shown under the bar: the remaining time when known, otherwise a contextual
    /// message so the line is never empty.
    private func etaText() -> String {
        if let t = effectiveTimeRemaining() {
            return "\(formatMinutesVerbose(t.minutes)) \(t.label)"
        }
        guard currentState.isPluggedIn else {
            return "Estimating time remaining…"   // on battery, time not computed yet
        }
        if currentState.percentage >= 100 {
            return "Fully charged"
        }
        if chargeLimiter.isActive && !chargeLimiter.chargingEnabled {
            // Only claim it's "held at" the limit when actually near it (within the hold band).
            // Above the band (e.g. 99% with an 80% limit) charging is just paused — the app
            // doesn't force-discharge, so don't pretend it's sitting at the limit.
            if currentState.percentage > chargeLimiter.upperBound {
                return "Above \(chargeLimiter.limitPercentage)% limit"
            }
            return "Held at \(chargeLimiter.limitPercentage)% ±\(chargeLimiter.hysteresisAmplitude)%"
        }
        if currentState.isCharging {
            return "Estimating time remaining…"   // charging, time not computed yet
        }
        return "On adapter"   // plugged in, idle, below 100%
    }

    /// The pill text plus whether it merely restates the power source the icon already shows
    /// (the two idle states). When `sourceOnly` is true the pill collapses to just the icon.
    private func statusText() -> (text: String, sourceOnly: Bool) {
        if chargeLimiter.thermalHold && currentState.isPluggedIn {
            return ("Cooling", false)
        } else if dischargeActive {
            return ("Discharging", false)
        } else if chargeLimiter.topUpActive && currentState.isPluggedIn {
            return ("Topping Up", false)
        } else if chargeLimiter.isActive && !chargeLimiter.chargingEnabled && currentState.isPluggedIn {
            // Charging held by the limiter. Keep the "Paused" pill while held below 100%
            // (the limit is actively protecting the battery); collapse to just the plug icon
            // only once genuinely fully charged (100%), same as the other idle states.
            return ("Paused", currentState.percentage >= 100)
        } else if currentState.isCharging {
            return ("Charging", false)
        } else if currentState.isPluggedIn {
            return ("Power Adapter", true)   // redundant with the plug icon
        } else {
            return ("Battery", true)          // redundant with the battery icon
        }
    }

    // MARK: - Smart time remaining

    /// Returns the effective time remaining and label based on charge limiter state.
    private func effectiveTimeRemaining() -> (minutes: Int, label: String)? {
        let state = currentState

        if !state.isPluggedIn {
            // Discharging on battery
            guard let minutes = state.timeToEmpty, minutes > 0, minutes < 6000 else { return nil }
            return (minutes, "left")
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

        let totalHeight = batteryImage.size.height

        // Leading coffee-cup glyph when keep-awake is active
        let cupSide: CGFloat = 13
        let cupImage = caffeineActive ? tintedCupImage(side: cupSide) : nil
        let cupW: CGFloat = cupImage != nil ? cupSide : 0
        let cupGap: CGFloat = cupImage != nil ? 3 : 0

        let gap: CGFloat = textSize.width > 0 ? 2 : 0
        let totalWidth = cupW + cupGap + textSize.width + gap + batteryImage.size.width

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { _ in
            var x: CGFloat = 0
            if let cup = cupImage {
                cup.draw(in: NSRect(x: 0, y: (totalHeight - cupSide) / 2, width: cupSide, height: cupSide))
                x += cupW + cupGap
            }
            if let text = text, !text.isEmpty {
                let textY = (totalHeight - textSize.height) / 2
                (text as NSString).draw(at: NSPoint(x: x, y: textY), withAttributes: attrs)
                x += textSize.width + gap
            }
            batteryImage.draw(
                in: NSRect(x: x, y: 0, width: batteryImage.size.width, height: batteryImage.size.height),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Coffee-cup SF Symbol tinted to the menu bar text color.
    private func tintedCupImage(side: CGFloat) -> NSImage? {
        guard let base = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Éveil") else {
            return nil
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let symbol = base.withSymbolConfiguration(cfg) ?? base
        symbol.isTemplate = true

        // Resolve the tint against the *menu bar's* appearance, not the app's. This image is
        // drawn eagerly (lockFocus) here, so a plain `NSColor.textColor` would resolve against
        // whatever appearance is current at build time and come out white on a light menu bar.
        // (The %/battery are drawn in a deferred handler and already track the menu bar.)
        var tint = NSColor.textColor
        if let appearance = statusItem.button?.effectiveAppearance {
            appearance.performAsCurrentDrawingAppearance {
                tint = NSColor.textColor.usingColorSpace(.sRGB) ?? .textColor
            }
        }

        let size = NSSize(width: side, height: side)
        let out = NSImage(size: size)
        out.lockFocus()
        tint.set()
        let rect = NSRect(origin: .zero, size: size)
        symbol.draw(in: rect)
        rect.fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    // MARK: - Actions (WidgetActionDelegate)

    func widgetToggleLimit() {
        if chargeLimiter.isActive {
            chargeLimiter.stop()
        } else {
            chargeLimiter.start()
        }
        refreshWidget()
    }

    func widgetToggleTopUp() {
        if chargeLimiter.topUpActive {
            chargeLimiter.deactivateTopUp()
        } else {
            chargeLimiter.activateTopUp()
        }
        refreshWidget()
    }

    func widgetSetDisplayMode(_ mode: MenuBarDisplayMode) {
        displayMode = mode
        defaults.set(displayMode.rawValue, forKey: "displayMode")
        update(state: currentState)
    }

    func widgetSetLimit(_ value: Int) {
        chargeLimiter.limitPercentage = value
        if chargeLimiter.isActive {
            chargeLimiter.check(percentage: currentState.percentage, isPluggedIn: currentState.isPluggedIn, temperature: currentState.temperature)
        }
        refreshWidget()
    }

    func widgetSetAmplitude(_ value: Int) {
        chargeLimiter.hysteresisAmplitude = value
        if chargeLimiter.isActive {
            chargeLimiter.check(percentage: currentState.percentage, isPluggedIn: currentState.isPluggedIn, temperature: currentState.temperature)
        }
        refreshWidget()
    }

    func widgetToggleStopChargingBeforeSleep() {
        chargeLimiter.stopChargingBeforeSleep.toggle()
        refreshWidget()
    }

    func widgetToggleLowPowerMode() {
        let enable = !ProcessInfo.processInfo.isLowPowerModeEnabled
        setLowPowerMode(enable)

        // If auto-LPM activated and user manually toggles, stop auto from re-enabling
        if autoLPMState == .activated {
            autoLPMState = .userOverridden
        }
    }

    func widgetSetAutoLPM(_ threshold: Int) {
        autoLPMThreshold = threshold
        defaults.set(autoLPMThreshold, forKey: "autoLPMThreshold")
        autoLPMState = .idle
        refreshWidget()
    }

    func widgetToggleCaffeine() {
        setCaffeine(!caffeineActive)
    }

    // MARK: - Active discharge (drain to the limit while plugged in)

    private(set) var dischargeActive = false

    func widgetToggleDischarge() {
        if dischargeActive {
            stopDischarge(notify: false)
        } else {
            guard smc.enableDischarge() else {
                bbLog.warning("Failed to enable discharge")
                return
            }
            dischargeActive = true
            // LED off while draining — the charger is virtually disconnected.
            chargeLimiter.ledOverride = .off
            smc.setMagSafeLED(.off)
            bbLog.info("Active discharge started at \(self.currentState.percentage)%")
        }
        updateStatusBarImage(state: currentState)
        refreshWidget()
    }

    /// Stop draining (SMC reconnects the adapter). Called on target reached, unplug, or toggle.
    func stopDischarge(notify: Bool) {
        guard dischargeActive else { return }
        if !smc.disableDischarge() {
            bbLog.error("Failed to disable discharge — retrying once")
            _ = smc.disableDischarge()
        }
        dischargeActive = false
        chargeLimiter.ledOverride = nil
        smc.setMagSafeLED(.system)   // limiter re-syncs (e.g. back to green) on next check
        if notify {
            Notifier.send("Discharge complete",
                          "Battery drained to \(currentState.percentage)% — back on the adapter.",
                          id: "discharge")
        }
        bbLog.info("Active discharge stopped at \(self.currentState.percentage)%")
    }

    /// Auto-stop the drain when the limit is reached or the charger is unplugged.
    private func checkDischarge(state: BatteryState) {
        guard dischargeActive else { return }
        if !state.isPluggedIn {
            stopDischarge(notify: false)
        } else if state.percentage <= chargeLimiter.limitPercentage {
            stopDischarge(notify: true)
        }
    }

    private func setCaffeine(_ on: Bool) {
        if on {
            if caffeineAssertionID == 0 {
                var aid: IOPMAssertionID = 0
                let result = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "BetterBattery — Éveil actif" as CFString,
                    &aid
                )
                if result == kIOReturnSuccess {
                    caffeineAssertionID = aid
                    caffeineActive = true
                } else {
                    bbLog.warning("Failed to create keep-awake assertion (\(result))")
                }
            }
        } else {
            if caffeineAssertionID != 0 {
                IOPMAssertionRelease(caffeineAssertionID)
                caffeineAssertionID = 0
            }
            caffeineActive = false
        }
        updateStatusBarImage(state: currentState)
        refreshWidget()
    }

    func widgetSetTheme(_ mode: Int) {
        appTheme = [0, 1, 2].contains(mode) ? mode : 0
        defaults.set(appTheme, forKey: "appTheme")
        applyAppTheme()
        refreshWidget()
    }

    private func applyAppTheme() {
        let appearance: NSAppearance?
        switch appTheme {
        case 1: appearance = NSAppearance(named: .aqua)
        case 2: appearance = NSAppearance(named: .darkAqua)
        default: appearance = nil   // follow system
        }
        NSApp.appearance = appearance
        panel?.appearance = appearance
        effectView?.appearance = appearance
    }

    /// Flush the battery history to disk (called on app termination).
    func saveHistory() { batteryHistory.saveNow() }

    func widgetShowHistory() { showHistory() }
    func widgetShowAbout() { showAbout() }

    // MARK: - History window

    private var historyWindow: NSWindow?
    private var historyGraphView: BatteryGraphView?

    private func showHistory() {
        closeDropdown()
        if let w = historyWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let graph = BatteryGraphView(frame: NSRect(x: 0, y: 0, width: 560, height: 280))
        graph.history = batteryHistory
        graph.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 280),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Battery History — Last 7 Days"
        window.contentView = graph
        window.minSize = NSSize(width: 360, height: 200)
        window.isReleasedWhenClosed = false
        window.center()
        historyWindow = window
        historyGraphView = graph
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func widgetUninstall() { uninstall() }
    func widgetQuit() { quit() }

    private func checkAutoLPM(percentage: Int) {
        guard autoLPMThreshold > 0, percentage > 0 else { return }

        let disableThreshold = autoLPMThreshold + 20
        let isPluggedIn = currentState.isPluggedIn

        switch autoLPMState {
        case .idle:
            if percentage <= autoLPMThreshold && !isPluggedIn {
                setLowPowerMode(true)
                autoLPMState = .activated
                Notifier.send("Low Power Mode enabled",
                              "Battery at \(percentage)% — Low Power Mode turned on automatically.",
                              id: "auto-lpm")
            }
        case .activated:
            if percentage >= disableThreshold || isPluggedIn {
                setLowPowerMode(false)
                autoLPMState = .idle
                Notifier.send("Low Power Mode disabled",
                              isPluggedIn ? "Charger connected — Low Power Mode turned off automatically."
                                          : "Battery back to \(percentage)% — Low Power Mode turned off automatically.",
                              id: "auto-lpm")
            }
        case .userOverridden:
            if percentage >= disableThreshold || isPluggedIn {
                autoLPMState = .idle
            }
        }
    }

    private func setLowPowerMode(_ enabled: Bool) {
        if !smc.setLowPowerMode(enabled) {
            bbLog.warning("Failed to set Low Power Mode via helper")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.update(state: self.currentState)
        }
    }

    func widgetToggleLaunchAtLogin() {
        if LaunchAtLogin.isEnabled {
            LaunchAtLogin.disable()
        } else {
            LaunchAtLogin.enable()
        }
        refreshWidget()
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
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let versionLabel = NSTextField(labelWithString: "v\(appVersion)")
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
        let linkParagraph = NSMutableParagraphStyle()
        linkParagraph.alignment = .center
        let linkLabel = NSTextField(labelWithAttributedString: NSAttributedString(
            string: "github.com/rocktane/betterbattery",
            attributes: [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .font: NSFont.systemFont(ofSize: 12),
                .cursor: NSCursor.pointingHand,
                .paragraphStyle: linkParagraph
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

    /// Verbose remaining time in English, e.g. "12 minutes" or "1 hour 23 minutes".
    private func formatMinutesVerbose(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 && m > 0 { return "\(h) hour\(h > 1 ? "s" : "") \(m) minute\(m > 1 ? "s" : "")" }
        if h > 0 { return "\(h) hour\(h > 1 ? "s" : "")" }
        return "\(m) minute\(m > 1 ? "s" : "")"
    }

    /// Wall-clock time since boot, including time spent asleep (matches the `uptime` command).
    /// `ProcessInfo.systemUptime` excludes sleep, which understates uptime badly on laptops.
    private func bootUptime() -> TimeInterval {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boottime, &size, nil, 0) == 0, boottime.tv_sec > 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        return Date().timeIntervalSince1970 - TimeInterval(boottime.tv_sec)
    }

    /// Compact single-unit uptime in full words: days if ≥1 day, else hours if ≥1 h, else minutes.
    private func formatUptimeCompact(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86400
        let hours = total / 3600
        let minutes = total / 60
        if days >= 1 { return "\(days) day\(days > 1 ? "s" : "")" }
        if hours >= 1 { return "\(hours) hour\(hours > 1 ? "s" : "")" }
        return "\(minutes) minute\(minutes > 1 ? "s" : "")"
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
