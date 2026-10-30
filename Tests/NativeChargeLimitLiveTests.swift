import Foundation
import os.log

let bbLog = Logger(subsystem: "com.betterbattery.tests", category: "native-live")
enum Notifier {
    static func send(_ title: String, _ body: String, id: String) { print("\(title): \(body)") }
}

/// Explicit hardware test: temporarily exercises Top Up, then leaves the user's
/// existing BetterBattery target active. Never run implicitly in CI.
@main
struct NativeChargeLimitLiveTests {
    static func main() {
        guard CommandLine.arguments.contains("--apply-user-limit") else {
            print("Use --apply-user-limit to exercise real native charge limits.")
            exit(2)
        }
        let user = UserDefaults(suiteName: "com.betterbattery.app")!
        let target = user.integer(forKey: "chargeLimitPercentage")
        let smc = SMCController()
        guard smc.usesNativeChargeLimit, smc.nativeChargeLimits.contains(target) else {
            print("FAIL: requested limit \(target)% is unavailable through native control")
            exit(1)
        }
        let domain = "com.betterbattery.tests.native.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(target, forKey: "chargeLimitPercentage")
        let limiter = ChargeLimiter(smc: smc, defaults: defaults)
        func expect(_ condition: Bool, _ description: String) {
            guard condition else {
                _ = smc.setNativeChargeLimit(target)
                print("FAIL: \(description)")
                exit(1)
            }
            print("PASS: \(description)")
        }
        limiter.start()
        expect(limiter.isActive && smc.nativeChargeLimit == target, "production limiter sets and reads back \(target)%")
        limiter.activateTopUp()
        expect(limiter.topUpActive && smc.nativeChargeLimit == 100, "Top Up sets and reads back 100%")
        limiter.deactivateTopUp()
        expect(!limiter.topUpActive && smc.nativeChargeLimit == target, "Top Up cancellation restores \(target)%")
        limiter.onSleep()
        limiter.onWake()
        expect(smc.nativeChargeLimit == target, "sleep/wake hooks preserve the native target")
        print("Native limit left at \(target)%.")
    }
}
