import Foundation
import os.log

enum MagSafeLEDColor: UInt8 {
    case system = 0x00          // Contrôle par macOS (défaut)
    case green = 0x03           // Vert fixe (limite atteinte)
    case orangeFastBlink = 0x07 // Orange clignotement rapide (alerte thermique)
}

/// XPC client facade over the privileged helper daemon.
/// Keeps the same synchronous public API as the old sudo/smc implementation:
/// every call blocks for the (ms-scale) round trip; if the daemon is not
/// running or not approved, the error handler fires and methods return
/// false/nil — fail-closed, identical to the old semantics.
class SMCController {
    private(set) var supportsTahoe: Bool = false
    private(set) var supportsLegacy: Bool = false
    private(set) var isAvailable: Bool = false

    private var connection: NSXPCConnection?

    init() {
        detectCapabilities()
    }

    // MARK: - XPC plumbing

    private func proxy() -> HelperProtocol? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: kHelperMachService, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            c.invalidationHandler = { [weak self] in
                DispatchQueue.main.async { self?.connection = nil }
            }
            c.resume()
            connection = c
        }
        return connection?.synchronousRemoteObjectProxyWithErrorHandler { error in
            bbLog.warning("Helper XPC error: \(error.localizedDescription)")
        } as? HelperProtocol
    }

    // MARK: - Version

    /// Daemon protocol version, or nil if the daemon didn't answer within `timeout`.
    /// Uses the async proxy: a daemon that launchd cannot spawn must not hang the
    /// app at startup the way a synchronous call would.
    func helperVersion(timeout: TimeInterval = 3) -> String? {
        _ = proxy()  // ensure the connection exists
        guard let c = connection else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var version: String?
        let p = c.remoteObjectProxyWithErrorHandler { _ in sem.signal() } as? HelperProtocol
        p?.getVersion { v in
            version = v
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        return version
    }

    // MARK: - Key Operations

    func readKey(_ key: String) -> Data? {
        var result: Data?
        proxy()?.readKey(key) { result = $0 }
        return result
    }

    // MARK: - High-Level Charge Control

    func enableCharging() -> Bool {
        var ok = false
        proxy()?.enableCharging { ok = $0 }
        return ok
    }

    func disableCharging() -> Bool {
        var ok = false
        proxy()?.disableCharging { ok = $0 }
        return ok
    }

    /// Returns true when charging is enabled in SMC, false when explicitly disabled.
    /// Returns nil if the helper is unreachable or the value is unexpected.
    func isChargingEnabledInSMC() -> Bool? {
        var result: Bool?
        proxy()?.isChargingEnabled { ok, enabled in
            result = ok ? enabled : nil
        }
        return result
    }

    func enableDischarge() -> Bool {
        var ok = false
        proxy()?.enableDischarge { ok = $0 }
        return ok
    }

    func disableDischarge() -> Bool {
        var ok = false
        proxy()?.disableDischarge { ok = $0 }
        return ok
    }

    @discardableResult
    func setMagSafeLED(_ color: MagSafeLEDColor) -> Bool {
        var ok = false
        proxy()?.setMagSafeLED(color.rawValue) { ok = $0 }
        return ok
    }

    // MARK: - Low Power Mode

    func setLowPowerMode(_ enabled: Bool) -> Bool {
        var ok = false
        proxy()?.setLowPowerMode(enabled) { ok = $0 }
        return ok
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
        var tahoe = false
        var legacy = false
        var reached = false
        proxy()?.probeCapabilities { t, l in
            tahoe = t
            legacy = l
            reached = true
        }
        supportsTahoe = tahoe
        supportsLegacy = legacy
        isAvailable = reached && (tahoe || legacy)
        if !reached {
            bbLog.warning("Helper daemon unreachable — charge control unavailable")
        }
    }
}
