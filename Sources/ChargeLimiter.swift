import Foundation
import os.log

class ChargeLimiter {
    private let smc: SMCController
    private var timer: Timer?
    private let defaults: UserDefaults

    // Thermal protection thresholds (°C)
    private let thermalStopCharging: Double = 40.0
    private let thermalResumeCharging: Double = 35.0
    private(set) var thermalHold: Bool = false

    private var _limitPercentage: Int = 80

    var limitPercentage: Int {
        get { _limitPercentage }
        set {
            guard !smc.usesNativeChargeLimit || smc.nativeChargeLimits.contains(newValue) else {
                bbLog.warning("Unsupported native charge limit \(newValue)")
                return
            }
            let clamped = min(100, max(20, newValue))
            if clamped != newValue {
                bbLog.warning("Charge limit \(newValue) out of bounds, clamped to \(clamped)")
            }
            if clamped != _limitPercentage { limitNotified = false }
            _limitPercentage = clamped
            defaults.set(clamped, forKey: "chargeLimitPercentage")
        }
    }

    /// Hysteresis amplitude: ±N% around the limit percentage
    var hysteresisAmplitude: Int = 5 {
        didSet {
            defaults.set(hysteresisAmplitude, forKey: "hysteresisAmplitude")
        }
    }

    /// Top Up: temporarily override the limit to charge to 100%. Auto-resets on unplug.
    private(set) var topUpActive: Bool = false

    /// Disable charging just before macOS sleep to prevent charging to 100% during sleep.
    var stopChargingBeforeSleep: Bool = false {
        didSet {
            defaults.set(stopChargingBeforeSleep, forKey: "stopChargingBeforeSleep")
        }
    }

    private(set) var isActive: Bool = false
    private(set) var chargingEnabled: Bool = true

    /// One "Charge limit reached" notification per hold event: armed again only when a new
    /// event can start (unplug, limit change, top-up, limiter start/stop) — not on each
    /// hysteresis cycle or SMC state resync while hovering around the limit.
    private var limitNotified: Bool = false

    private var lastPercentage: Int = 0
    private var lastIsPluggedIn: Bool = false
    private var lastTemperature: Double? = nil
    private var wasPluggedIn: Bool = false
    private var lastLEDColor: MagSafeLEDColor?

    var onStateChange: (() -> Void)?

    var upperBound: Int {
        if topUpActive { return 105 } // Effectively no upper limit
        if smc.usesNativeChargeLimit { return limitPercentage }
        return min(100, limitPercentage + hysteresisAmplitude)
    }
    var lowerBound: Int { max(0, limitPercentage - (smc.usesNativeChargeLimit ? 5 : hysteresisAmplitude)) }

    init(smc: SMCController, defaults: UserDefaults = .standard) {
        self.smc = smc
        self.defaults = defaults
        let savedLimit = defaults.integer(forKey: "chargeLimitPercentage")
        if savedLimit > 0 {
            if savedLimit >= 20 && savedLimit <= 100 {
                _limitPercentage = savedLimit
            } else {
                bbLog.warning("Invalid saved charge limit \(savedLimit) — using default 80")
                defaults.removeObject(forKey: "chargeLimitPercentage")
            }
        }
        let savedAmplitude = defaults.integer(forKey: "hysteresisAmplitude")
        if savedAmplitude >= 2 && savedAmplitude <= 10 {
            hysteresisAmplitude = savedAmplitude
        } else if savedAmplitude != 0 {
            bbLog.warning("Invalid saved amplitude \(savedAmplitude) — using default 5")
            defaults.removeObject(forKey: "hysteresisAmplitude")
        }
        if smc.usesNativeChargeLimit && !smc.nativeChargeLimits.contains(_limitPercentage) {
            _limitPercentage = smc.nativeChargeLimits.first ?? 80
            defaults.set(_limitPercentage, forKey: "chargeLimitPercentage")
        }
        stopChargingBeforeSleep = defaults.bool(forKey: "stopChargingBeforeSleep")
    }

    func start() {
        isActive = true
        limitNotified = false
        defaults.set(true, forKey: "chargeLimitEnabled")

        if smc.usesNativeChargeLimit {
            if applyNativeLimit() { startTimer() }
            onStateChange?()
            return
        }

        // Assert SMC state: ensure charging is physically enabled.
        // Prevents desync if SMC was left in disabled state (crash, failed cleanup).
        if smc.enableCharging() {
            chargingEnabled = true
        } else {
            chargingEnabled = false
            bbLog.warning("Failed to enable charging on start — will retry on next check")
        }

        // Perform an immediate check
        check(percentage: lastPercentage, isPluggedIn: lastIsPluggedIn, temperature: lastTemperature)

        // Start periodic timer for safety (in case events are missed)
        startTimer()

        onStateChange?()
    }

    func stop() {
        if smc.usesNativeChargeLimit && !smc.setNativeChargeLimit(100) {
            Notifier.send("Charge limit still active", "macOS could not disable the limit. You can also change it in System Settings → Battery.", id: "native-limit-error")
            return
        }
        isActive = false
        thermalHold = false
        topUpActive = false
        limitNotified = false
        timer?.invalidate()
        timer = nil
        defaults.set(false, forKey: "chargeLimitEnabled")

        // Always re-enable charging — internal state may be
        // out of sync with actual SMC state (crash, failed write, sleep/wake race).
        let enabled: Bool
        if smc.usesNativeChargeLimit {
            enabled = true
        } else {
            enabled = smc.enableCharging() || smc.enableCharging() // retry once
        }
        if !enabled {
            bbLog.warning("Failed to re-enable charging on stop after retry")
        }
        smc.setMagSafeLED(.system)
        chargingEnabled = enabled

        onStateChange?()
    }

    // MARK: - Top Up

    func activateTopUp() {
        guard isActive else { return }
        if smc.usesNativeChargeLimit {
            guard smc.setNativeChargeLimit(100) else {
                Notifier.send("Top Up failed", "macOS could not change the charge limit.", id: "native-limit-error")
                return
            }
            topUpActive = true
            onStateChange?()
            return
        }
        topUpActive = true
        limitNotified = false
        check(percentage: lastPercentage, isPluggedIn: lastIsPluggedIn, temperature: lastTemperature)
        if !chargingEnabled && !thermalHold {
            if smc.enableCharging() {
                chargingEnabled = true
                smc.setMagSafeLED(.system)
            }
        }
        bbLog.info("Top Up activated")
        onStateChange?()
    }

    func deactivateTopUp() {
        topUpActive = false
        bbLog.info("Top Up deactivated")
        check(percentage: lastPercentage, isPluggedIn: lastIsPluggedIn, temperature: lastTemperature)
    }

    // MARK: - Timer

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.smc.isAvailable {
                self.smc.redetectCapabilities()
            }
            self.check(percentage: self.lastPercentage, isPluggedIn: self.lastIsPluggedIn, temperature: self.lastTemperature)
        }
        // Allow macOS to defer the timer during sleep — prevents dark wake → full wake
        timer?.tolerance = 30
    }

    // MARK: - Sleep / Wake

    /// Called before macOS sleep. Stops the timer and disables charging if configured.
    func onSleep() {
        timer?.invalidate()
        timer = nil
        bbLog.info("Timer suspended for sleep")

        // macOS enforces the native ceiling during sleep itself.
        guard !smc.usesNativeChargeLimit, isActive && stopChargingBeforeSleep else { return }
        // Write to SMC without changing chargingEnabled — onWake re-asserts the real state.
        if !smc.disableCharging() {
            bbLog.warning("Failed to disable charging before sleep — will retry on wake")
        }
        bbLog.info("Charging disabled before sleep")
    }

    /// Re-assert current charging state to SMC after wake from sleep.
    func onWake() {
        guard isActive else { return }

        // Restart the periodic safety timer
        startTimer()
        if smc.usesNativeChargeLimit {
            _ = applyNativeLimit()
            return
        }

        if chargingEnabled {
            if !smc.enableCharging() {
                bbLog.warning("Failed to re-enable charging on wake — will retry next cycle")
            }
        } else {
            if !smc.disableCharging() {
                bbLog.warning("Failed to re-assert disabled charging on wake — will retry next cycle")
            }
        }
    }

    private func reconcileChargingStateWithSMC() {
        guard let smcChargingEnabled = smc.isChargingEnabledInSMC() else { return }
        guard smcChargingEnabled != chargingEnabled else { return }

        bbLog.warning(
            "Charging state desync detected — internal=\(self.chargingEnabled ? "enabled" : "disabled"), SMC=\(smcChargingEnabled ? "enabled" : "disabled")"
        )
        chargingEnabled = smcChargingEnabled
        onStateChange?()
    }

    // MARK: - Main check

    func check(percentage: Int, isPluggedIn: Bool, temperature: Double?) {
        let previouslyPluggedIn = wasPluggedIn
        lastPercentage = percentage
        lastIsPluggedIn = isPluggedIn
        lastTemperature = temperature
        wasPluggedIn = isPluggedIn

        guard isActive else { return }

        if smc.usesNativeChargeLimit {
            if previouslyPluggedIn && !isPluggedIn { topUpActive = false }
            _ = applyNativeLimit()
            onStateChange?()
            return
        }

        // Anti-micro-charge + Top Up reset on unplug
        if previouslyPluggedIn && !isPluggedIn {
            if topUpActive {
                topUpActive = false
                bbLog.info("Top Up reset on unplug")
            }
            thermalHold = false
            limitNotified = false
            if !smc.disableCharging() {
                bbLog.warning("Failed to disable charging on unplug")
            }
            smc.setMagSafeLED(.system)
            chargingEnabled = false
            onStateChange?()
            return
        }

        guard isPluggedIn else { return }

        // Self-heal if another tool or a missed event changed the hardware state.
        reconcileChargingStateWithSMC()

        // Plug-in transition: re-enable charging if below limit
        if !previouslyPluggedIn && isPluggedIn && !chargingEnabled && !thermalHold && percentage < upperBound {
            if smc.enableCharging() {
                chargingEnabled = true
                smc.setMagSafeLED(.system)
                onStateChange?()
            }
        }

        // Thermal protection
        if let temperature = temperature, temperature > thermalStopCharging {
            if !chargingEnabled || smc.disableCharging() {
                chargingEnabled = false
                let newHold = !thermalHold
                thermalHold = true
                smc.setMagSafeLED(.orangeFastBlink)
                bbLog.info("Thermal hold — charging stopped at \(temperature, format: .fixed(precision: 1))°C")
                if newHold {
                    Notifier.send("Thermal protection",
                                  String(format: "Battery at %.1f°C — charging paused until it cools down.", temperature),
                                  id: "thermal")
                }
            }
            onStateChange?()
            return
        }

        if thermalHold, let temperature = temperature, temperature < thermalResumeCharging {
            thermalHold = false
            // Restore charging if below limit (avoids dead zone where neither hysteresis branch triggers)
            if !chargingEnabled && percentage < upperBound {
                if smc.enableCharging() {
                    chargingEnabled = true
                }
                smc.setMagSafeLED(.system)
                onStateChange?()
            }
            bbLog.info("Thermal hold cleared at \(temperature, format: .fixed(precision: 1))°C")
            Notifier.send("Thermal protection cleared",
                          String(format: "Battery cooled down to %.1f°C — normal charge control resumed.", temperature),
                          id: "thermal")
        }

        if thermalHold {
            // A missing sensor must not let an external SMC change bypass the hold.
            if chargingEnabled && smc.disableCharging() {
                chargingEnabled = false
                onStateChange?()
            }
            return
        }

        // Hysteresis charge control
        if percentage >= upperBound && chargingEnabled {
            if smc.disableCharging() {
                chargingEnabled = false
                if !limitNotified {
                    limitNotified = true
                    Notifier.send("Charge limit reached",
                                  "Battery held at \(limitPercentage)% — charging paused.",
                                  id: "limit-reached")
                }
            } else {
                bbLog.warning("Failed to disable charging at \(percentage)%%")
            }
            smc.setMagSafeLED(.green)
            onStateChange?()
        } else if percentage <= lowerBound && !chargingEnabled {
            if smc.enableCharging() {
                chargingEnabled = true
            } else {
                bbLog.warning("Failed to enable charging at \(percentage)%%")
            }
            smc.setMagSafeLED(.system)
            onStateChange?()
        }

        syncMagSafeLED(percentage: percentage)
    }

    /// Native macOS owns charging, hysteresis, thermal management and sleep.
    /// Never emulate a charge gate by disconnecting the power adapter.
    @discardableResult
    private func applyNativeLimit() -> Bool {
        let target = topUpActive ? 100 : limitPercentage
        if smc.nativeChargeLimit == target || smc.setNativeChargeLimit(target) {
            chargingEnabled = true
            thermalHold = false
            return true
        }
        isActive = false
        defaults.set(false, forKey: "chargeLimitEnabled")
        Notifier.send("Charge limit failed", "macOS could not apply the charge limit. Try enabling it again.", id: "native-limit-error")
        bbLog.error("Failed to apply native charge limit \(target)")
        return false
    }

    private func syncMagSafeLED(percentage: Int) {
        let desired: MagSafeLEDColor
        if thermalHold {
            desired = .orangeFastBlink
        } else if !chargingEnabled {
            desired = .green
        } else {
            desired = .system
        }
        if desired != lastLEDColor {
            if smc.setMagSafeLED(desired) {
                lastLEDColor = desired
            }
        }
    }
}
