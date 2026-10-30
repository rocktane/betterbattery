import Foundation
import os.log

let bbLog = Logger(subsystem: "com.betterbattery.tests", category: "limiter")
enum MagSafeLEDColor { case system, green, orangeFastBlink }
final class SMCController {
    var usesNativeChargeLimit = false
    var nativeChargeLimits = [80, 85, 90, 95, 100]
    var nativeChargeLimit: Int? = 100
    var nativeWriteSucceeds = true
    var nativeWrites: [Int] = []
    func setNativeChargeLimit(_ limit: Int) -> Bool {
        nativeWrites.append(limit)
        guard nativeWriteSucceeds else { return false }
        nativeChargeLimit = limit
        return true
    }
    var isAvailable = true
    var enabled = true
    var enableCount = 0
    func enableCharging() -> Bool { enabled = true; enableCount += 1; return true }
    func disableCharging() -> Bool { enabled = false; return true }
    func isChargingEnabledInSMC() -> Bool? { enabled }
    @discardableResult func setMagSafeLED(_ color: MagSafeLEDColor) -> Bool { true }
    func redetectCapabilities() {}
}
enum Notifier {
    static func send(_ title: String, _ body: String, id: String) {}
}

@main
struct ChargeLimiterTests {
    static func main() {
        let domain = "com.betterbattery.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let smc = SMCController()
        let limiter = ChargeLimiter(smc: smc, defaults: defaults)
        var count = 0
        func expect(_ condition: Bool, _ message: String) {
            guard condition else { print("FAIL: \(message)"); exit(1) }
            count += 1
        }
        limiter.check(percentage: 60, isPluggedIn: true, temperature: 30)
        limiter.start()
        limiter.check(percentage: 60, isPluggedIn: true, temperature: 42)
        expect(limiter.thermalHold && !smc.enabled, "hot battery stops charge")
        let before = smc.enableCount
        limiter.activateTopUp()
        expect(!smc.enabled && smc.enableCount == before, "Top Up must respect thermal hold")
        limiter.check(percentage: 60, isPluggedIn: true, temperature: nil)
        expect(limiter.thermalHold && !smc.enabled, "missing sensor cannot clear thermal hold")
        smc.enabled = true // macOS or another charge utility changed the hardware.
        limiter.check(percentage: 60, isPluggedIn: true, temperature: nil)
        expect(limiter.thermalHold && !smc.enabled, "unknown temperature preserves hold after SMC desync")
        limiter.check(percentage: 60, isPluggedIn: true, temperature: 34)
        expect(!limiter.thermalHold && smc.enabled, "valid cool reading releases hold")
        limiter.deactivateTopUp()
        limiter.check(percentage: 85, isPluggedIn: true, temperature: 30)
        expect(!smc.enabled, "upper bound stops charging")
        limiter.check(percentage: 80, isPluggedIn: true, temperature: 30)
        expect(!smc.enabled, "hysteresis holds")
        limiter.check(percentage: 75, isPluggedIn: true, temperature: 30)
        expect(smc.enabled, "lower bound resumes charging")
        limiter.check(percentage: 85, isPluggedIn: true, temperature: 42)
        limiter.activateTopUp()
        expect(!smc.enabled && limiter.thermalHold, "Top Up cannot bypass heat while already paused")
        limiter.check(percentage: 60, isPluggedIn: false, temperature: nil)
        expect(!limiter.topUpActive, "unplug resets Top Up")
        limiter.stop()
        expect(smc.enabled, "stop restores charging")
        smc.usesNativeChargeLimit = true
        let native = ChargeLimiter(smc: smc, defaults: defaults)
        native.start()
        expect(native.isActive && smc.nativeChargeLimit == 80, "native start applies 80%")
        expect(native.upperBound == 80 && native.lowerBound == 75, "native bounds use macOS hysteresis")
        let writes = smc.nativeWrites.count
        native.check(percentage: 90, isPluggedIn: true, temperature: nil)
        expect(smc.nativeWrites.count == writes, "native check avoids unnecessary writes")
        native.onSleep()
        native.onWake()
        expect(smc.nativeChargeLimit == 80, "native limit stays set through sleep/wake")
        native.activateTopUp()
        expect(native.topUpActive && smc.nativeChargeLimit == 100, "native Top Up applies 100%")
        native.check(percentage: 90, isPluggedIn: false, temperature: nil)
        expect(!native.topUpActive && smc.nativeChargeLimit == 80, "native unplug restores limit")
        native.limitPercentage = 60
        expect(native.limitPercentage == 80, "native rejects unsupported limits")
        native.limitPercentage = 85
        native.check(percentage: 60, isPluggedIn: true, temperature: nil)
        expect(smc.nativeChargeLimit == 85, "native accepts supported limit changes")
        smc.nativeWriteSucceeds = false
        native.stop()
        expect(native.isActive && smc.nativeChargeLimit == 85, "failed native disable must keep active state")
        smc.nativeWriteSucceeds = true
        native.stop()
        expect(smc.nativeChargeLimit == 100, "native off releases the limit")
        smc.nativeWriteSucceeds = false
        native.start()
        expect(!native.isActive, "native failure must not claim the limiter is active")
        native.stop()
        print("PASS: \(count) charge limiter checks")
    }
}
