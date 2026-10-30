import Foundation
import os.log

enum MagSafeLEDColor: UInt8 {
    case system = 0x00          // Contrôle par macOS (défaut)
    case green = 0x03           // Vert fixe (limite atteinte)
    case orangeFastBlink = 0x07 // Orange clignotement rapide (alerte thermique)
}

/// Bounded XPC facade: a missing or stalled helper returns false/nil, so the
/// menu bar remains usable even after background approval is revoked.
class SMCController {
    private(set) var supportsTahoe: Bool = false
    private(set) var supportsLegacy: Bool = false
    private(set) var isAvailable: Bool = false

    private var nativeController: NativeChargeLimit?
    var usesNativeChargeLimit: Bool { nativeController != nil && !supportsTahoe && !supportsLegacy }
    var nativeChargeLimits: [Int] { nativeController?.availableLimits ?? [] }
    var nativeChargeLimit: Int? { nativeController?.currentLimit }

    func setNativeChargeLimit(_ limit: Int) -> Bool {
        nativeController?.setLimit(limit) ?? false
    }

    init() {
        detectCapabilities()
    }

    // Each request owns its connection. Invalidating a timed-out request cannot
    // accidentally invalidate a newer connection or accept its late reply.
    private static func request<Value>(
        timeout: TimeInterval = 3,
        _ perform: (HelperProtocol, @escaping (Value) -> Void) -> Void
    ) -> Value? {
        let reply = HelperReply<Value>()
        let connection = NSXPCConnection(machServiceName: kHelperMachService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.invalidationHandler = { reply.finish(nil) }
        connection.interruptionHandler = { reply.finish(nil) }
        connection.resume()
        defer { connection.invalidate() }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            bbLog.warning("Helper XPC error: \(error.localizedDescription)")
            reply.finish(nil)
        }) as? HelperProtocol else { return nil }
        perform(proxy) { reply.finish($0) }
        return reply.wait(timeout: timeout)
    }

    static func probeHelperVersion(timeout: TimeInterval = 3) -> String? {
        request(timeout: timeout) { proxy, reply in proxy.getVersion(reply: reply) }
    }

    // MARK: - Key Operations

    func readKey(_ key: String) -> Data? {
        let result: Data?? = Self.request { proxy, reply in proxy.readKey(key, reply: reply) }
        return result ?? nil
    }

    func enableCharging() -> Bool {
        // Native limits are managed explicitly by ChargeLimiter; startup must
        // not erase a limit the user configured in System Settings.
        if usesNativeChargeLimit { return true }
        return Self.request { proxy, reply in proxy.enableCharging(reply: reply) } ?? false
    }

    func disableCharging() -> Bool {
        Self.request { proxy, reply in proxy.disableCharging(reply: reply) } ?? false
    }

    /// nil means the helper could not determine the hardware state.
    func isChargingEnabledInSMC() -> Bool? {
        let result: (Bool, Bool)? = Self.request { proxy, reply in
            proxy.isChargingEnabled { reply(($0, $1)) }
        }
        guard let (ok, enabled) = result, ok else { return nil }
        return enabled
    }

    func enableDischarge() -> Bool {
        Self.request { proxy, reply in proxy.enableDischarge(reply: reply) } ?? false
    }

    func disableDischarge() -> Bool {
        Self.request { proxy, reply in proxy.disableDischarge(reply: reply) } ?? false
    }

    @discardableResult
    func setMagSafeLED(_ color: MagSafeLEDColor) -> Bool {
        Self.request { proxy, reply in proxy.setMagSafeLED(color.rawValue, reply: reply) } ?? false
    }

    func setLowPowerMode(_ enabled: Bool) -> Bool {
        Self.request { proxy, reply in proxy.setLowPowerMode(enabled, reply: reply) } ?? false
    }

    // MARK: - Capabilities Detection

    /// Re-probe SMC capabilities (e.g., after the daemon gets approved)
    func redetectCapabilities() {
        supportsTahoe = false
        supportsLegacy = false
        isAvailable = false
        detectCapabilities()
    }

    private func detectCapabilities() {
        let result: (Bool, Bool)? = Self.request { proxy, reply in
            proxy.probeCapabilities { reply(($0, $1)) }
        }
        supportsTahoe = result?.0 ?? false
        supportsLegacy = result?.1 ?? false
        if !supportsTahoe && !supportsLegacy {
            nativeController = NativeChargeLimit.connect()
            if nativeController?.availableLimits.isEmpty == true { nativeController = nil }
        } else {
            nativeController = nil
        }
        isAvailable = supportsTahoe || supportsLegacy || usesNativeChargeLimit
        if result == nil && !usesNativeChargeLimit {
            bbLog.warning("Helper daemon unreachable — charge control unavailable")
        }
    }
}
