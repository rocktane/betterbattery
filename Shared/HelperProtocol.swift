import Foundation

/// Mach service name the privileged helper listens on.
let kHelperMachService = "com.betterbattery.helper.xpc"

/// Helper version, bumped when the protocol or helper behavior changes.
/// The app compares it to its own to detect a stale approved daemon.
let kHelperVersion = "1"

/// XPC protocol between the app and the privileged helper daemon.
/// The daemon owns platform detection (Tahoe vs legacy keys) and enforces a
/// whitelist of SMC keys/values — a compromised app cannot write arbitrary
/// SMC keys through this interface.
@objc protocol HelperProtocol {
    func getVersion(reply: @escaping (String) -> Void)
    func probeCapabilities(reply: @escaping (_ tahoe: Bool, _ legacy: Bool) -> Void)
    func enableCharging(reply: @escaping (Bool) -> Void)
    func disableCharging(reply: @escaping (Bool) -> Void)
    /// ok=false means "could not determine" (maps to nil on the app side)
    func isChargingEnabled(reply: @escaping (_ ok: Bool, _ enabled: Bool) -> Void)
    func enableDischarge(reply: @escaping (Bool) -> Void)
    func disableDischarge(reply: @escaping (Bool) -> Void)
    func setMagSafeLED(_ raw: UInt8, reply: @escaping (Bool) -> Void)
    func readKey(_ key: String, reply: @escaping (Data?) -> Void)
    func setLowPowerMode(_ enabled: Bool, reply: @escaping (Bool) -> Void)
}
