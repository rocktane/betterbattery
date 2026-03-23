import Foundation
import os.log

class ChargeLimiter {
    private let smc: SMCController
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    // Thermal protection thresholds (°C)
    private let thermalStopCharging: Double = 40.0
    private let thermalResumeCharging: Double = 35.0
    private(set) var thermalHold: Bool = false

    private var _limitPercentage: Int = 80

    var limitPercentage: Int {
        get { _limitPercentage }
        set {
            let clamped = min(100, max(20, newValue))
            if clamped != newValue {
                bbLog.warning("Charge limit \(newValue) out of bounds, clamped to \(clamped)")
            }
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

    private var lastPercentage: Int = 0
    private var lastIsPluggedIn: Bool = false
    private var lastTemperature: Double = 0.0
    private var wasPluggedIn: Bool = false
    private var lastLEDColor: MagSafeLEDColor?

    var onStateChange: (() -> Void)?

    var upperBound: Int {
        if topUpActive { return 105 } // Effectively no upper limit
        return min(100, limitPercentage + hysteresisAmplitude)
    }
    var lowerBound: Int { max(0, limitPercentage - hysteresisAmplitude) }

    init(smc: SMCController) {
        self.smc = smc
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
        stopChargingBeforeSleep = defaults.bool(forKey: "stopChargingBeforeSleep")
    }

    func start() {
        isActive = true
        defaults.set(true, forKey: "chargeLimitEnabled")

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
        isActive = false
        thermalHold = false
        topUpActive = false
        timer?.invalidate()
        timer = nil
        defaults.set(false, forKey: "chargeLimitEnabled")

        // Always re-enable charging — internal state may be
        // out of sync with actual SMC state (crash, failed write, sleep/wake race).
        let enabled = smc.enableCharging() || smc.enableCharging() // retry once
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
        topUpActive = true
        if !chargingEnabled {
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

        guard isActive && stopChargingBeforeSleep else { return }
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

    func check(percentage: Int, isPluggedIn: Bool, temperature: Double) {
        let previouslyPluggedIn = wasPluggedIn
        lastPercentage = percentage
        lastIsPluggedIn = isPluggedIn
        lastTemperature = temperature
        wasPluggedIn = isPluggedIn

        guard isActive else { return }

        // Anti-micro-charge + Top Up reset on unplug
        if previouslyPluggedIn && !isPluggedIn {
            if topUpActive {
                topUpActive = false
                bbLog.info("Top Up reset on unplug")
            }
            thermalHold = false
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
        if !previouslyPluggedIn && isPluggedIn && !chargingEnabled && percentage < upperBound {
            if smc.enableCharging() {
                chargingEnabled = true
                smc.setMagSafeLED(.system)
                onStateChange?()
            }
        }

        // Thermal protection
        if temperature > thermalStopCharging && chargingEnabled {
            if smc.disableCharging() {
                chargingEnabled = false
                thermalHold = true
                smc.setMagSafeLED(.orangeFastBlink)
                bbLog.info("Thermal hold — charging stopped at \(temperature, format: .fixed(precision: 1))°C")
            }
            onStateChange?()
            return
        }

        if thermalHold && temperature < thermalResumeCharging {
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
        }

        if thermalHold { return }

        // Hysteresis charge control
        if percentage >= upperBound && chargingEnabled {
            if smc.disableCharging() {
                chargingEnabled = false
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
