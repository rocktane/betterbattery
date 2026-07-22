import Foundation
import os.log

let helperLog = Logger(subsystem: "com.betterbattery.helper", category: "general")

/// Implements HelperProtocol on top of SMCKernel.
/// Security posture mirrors the old sudoers whitelist: only known keys with
/// known values can be written, regardless of what the app requests.
final class HelperService: NSObject, HelperProtocol {
    static let shared = HelperService()

    private let smc = SMCKernel()
    private var probed = false
    private var supportsTahoe = false
    private var supportsLegacy = false
    private let queue = DispatchQueue(label: "com.betterbattery.helper.smc")

    /// Keys the app may read directly.
    private let readableKeys: Set<String> = ["CHTE", "CHIE", "CH0B", "CH0C", "CH0I", "ACLC"]

    // MARK: - Capability detection

    /// Must run on `queue` — `probed`/`supportsTahoe`/`supportsLegacy` have no
    /// synchronization of their own; the serial queue is their only barrier.
    private func ensureProbed() {
        guard !probed else { return }
        probed = true
        guard smc.open() else {
            helperLog.error("Cannot open AppleSMC service")
            return
        }
        if smc.read("CHTE") != nil {
            supportsTahoe = true
        } else if smc.read("CH0B") != nil {
            supportsLegacy = true
        }
        helperLog.info("SMC capabilities: tahoe=\(self.supportsTahoe), legacy=\(self.supportsLegacy)")
    }

    // MARK: - Verified write (fail-closed, replicates old writeKey semantics)

    private func writeVerified(_ key: String, _ bytes: [UInt8]) -> Bool {
        let data = Data(bytes)
        guard smc.write(key, data) else {
            helperLog.error("SMC write failed for key \(key)")
            return false
        }
        guard let readBack = smc.read(key) else {
            helperLog.warning("SMC read-back failed for key \(key) — fail-closed")
            return false
        }
        if readBack != data {
            helperLog.error("SMC write verification failed for key \(key)")
            return false
        }
        return true
    }

    // MARK: - HelperProtocol

    func getVersion(reply: @escaping (String) -> Void) {
        reply(kHelperVersion)
    }

    func probeCapabilities(reply: @escaping (Bool, Bool) -> Void) {
        queue.async {
            self.ensureProbed()
            reply(self.supportsTahoe, self.supportsLegacy)
        }
    }

    func enableCharging(reply: @escaping (Bool) -> Void) {
        queue.async {
            self.ensureProbed()
            if self.supportsTahoe {
                reply(self.writeVerified("CHTE", [0x00, 0x00, 0x00, 0x00]))
            } else if self.supportsLegacy {
                let a = self.writeVerified("CH0B", [0x00])
                let b = self.writeVerified("CH0C", [0x00])
                reply(a && b)
            } else {
                reply(false)
            }
        }
    }

    func disableCharging(reply: @escaping (Bool) -> Void) {
        queue.async {
            self.ensureProbed()
            if self.supportsTahoe {
                reply(self.writeVerified("CHTE", [0x01, 0x00, 0x00, 0x00]))
            } else if self.supportsLegacy {
                let a = self.writeVerified("CH0B", [0x02])
                let b = self.writeVerified("CH0C", [0x02])
                reply(a && b)
            } else {
                reply(false)
            }
        }
    }

    func isChargingEnabled(reply: @escaping (Bool, Bool) -> Void) {
        queue.async {
            self.ensureProbed()
            if self.supportsTahoe {
                guard let data = self.smc.read("CHTE"), data.count == 4 else {
                    reply(false, false)
                    return
                }
                switch [UInt8](data) {
                case [0x00, 0x00, 0x00, 0x00]: reply(true, true)
                case [0x01, 0x00, 0x00, 0x00]: reply(true, false)
                default:
                    helperLog.warning("Unexpected CHTE value")
                    reply(false, false)
                }
            } else if self.supportsLegacy {
                guard let b = self.smc.read("CH0B"), let c = self.smc.read("CH0C"),
                      b.count == 1, c.count == 1 else {
                    reply(false, false)
                    return
                }
                if b[0] == 0x00 && c[0] == 0x00 {
                    reply(true, true)
                } else if b[0] == 0x02 && c[0] == 0x02 {
                    reply(true, false)
                } else {
                    helperLog.warning("Unexpected legacy charging values")
                    reply(false, false)
                }
            } else {
                reply(false, false)
            }
        }
    }

    func enableDischarge(reply: @escaping (Bool) -> Void) {
        queue.async {
            self.ensureProbed()
            if self.supportsTahoe {
                reply(self.writeVerified("CHIE", [0x08]))
            } else if self.supportsLegacy {
                reply(self.writeVerified("CH0I", [0x01]))
            } else {
                reply(false)
            }
        }
    }

    func disableDischarge(reply: @escaping (Bool) -> Void) {
        queue.async {
            self.ensureProbed()
            if self.supportsTahoe {
                reply(self.writeVerified("CHIE", [0x00]))
            } else if self.supportsLegacy {
                reply(self.writeVerified("CH0I", [0x00]))
            } else {
                reply(false)
            }
        }
    }

    func setMagSafeLED(_ raw: UInt8, reply: @escaping (Bool) -> Void) {
        // Whitelist: system (0x00), green (0x03), orange fast blink (0x07)
        guard [0x00, 0x03, 0x07].contains(raw) else {
            helperLog.error("Rejected ACLC value \(raw)")
            reply(false)
            return
        }
        queue.async {
            self.ensureProbed()
            // LED is cosmetic — unverified write because macOS may override
            // ACLC (e.g., .system writes 0x00 but macOS sets 0x04)
            reply(self.smc.write("ACLC", Data([raw])))
        }
    }

    func readKey(_ key: String, reply: @escaping (Data?) -> Void) {
        guard readableKeys.contains(key) else {
            helperLog.error("Rejected read of non-whitelisted key \(key)")
            reply(nil)
            return
        }
        queue.async {
            self.ensureProbed()
            reply(self.smc.read(key))
        }
    }

    func setLowPowerMode(_ enabled: Bool, reply: @escaping (Bool) -> Void) {
        queue.async {
            // Daemon runs as root — pmset directly, no sudo.
            // Battery profile only (-b): Low Power Mode applies on battery and
            // macOS itself suspends it on AC, even if the app never gets to.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-b", "lowpowermode", enabled ? "1" : "0"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                reply(process.terminationStatus == 0)
            } catch {
                helperLog.error("pmset failed: \(error.localizedDescription)")
                reply(false)
            }
        }
    }
}
