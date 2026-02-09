import Foundation
import CryptoKit
import Security
import os.log

enum MagSafeLEDColor: UInt8 {
    case system = 0x00          // Contrôle par macOS (défaut)
    case off = 0x01             // LED éteinte
    case green = 0x03           // Vert fixe (plein / limite atteinte)
    case orange = 0x04          // Orange fixe (limite active, maintien)
    case orangeSlowBlink = 0x06 // Orange clignotement lent (en charge)
    case orangeFastBlink = 0x07 // Orange clignotement rapide
}

class SMCController {
    private let smcPath = "/usr/local/bin/smc"
    private(set) var supportsTahoe: Bool = false
    private(set) var supportsLegacy: Bool = false
    private(set) var isAvailable: Bool = false
    private(set) var needsSudoersReinstall: Bool = false

    // SHA-256 integrity cache
    private var cachedSmcHash: String? = nil
    private var cachedSmcModDate: Date? = nil

    private let keychainService = "com.betterbattery.smc-hash"
    private let keychainAccount = "sha256"

    init() {
        detectCapabilities()
    }

    // MARK: - Keychain helpers

    private func loadHashFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let hash = String(data: data, encoding: .utf8) else {
            return nil
        }
        return hash
    }

    private func saveHashToKeychain(_ hash: String) {
        guard let data = hash.data(using: .utf8) else { return }

        // Try update first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    // MARK: - SMC Binary Integrity

    private func validateSmcFileProperties() -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: smcPath) else {
            bbLog.warning("Cannot read attributes of smc binary")
            return false
        }

        // Reject symlinks
        if let fileType = attrs[.type] as? FileAttributeType, fileType == .typeSymbolicLink {
            bbLog.error("smc binary is a symlink — refusing to execute")
            return false
        }

        // Must be a regular file
        if let fileType = attrs[.type] as? FileAttributeType, fileType != .typeRegular {
            bbLog.error("smc binary is not a regular file (type: \(String(describing: fileType)))")
            return false
        }

        // Owner must be root (uid 0) or current user
        if let ownerID = attrs[.ownerAccountID] as? NSNumber {
            let uid = ownerID.uint32Value
            if uid != 0 && uid != getuid() {
                bbLog.error("smc binary owned by unexpected uid \(uid)")
                return false
            }
        }

        // No group/other write bits (mask 022)
        if let perms = attrs[.posixPermissions] as? NSNumber {
            let mode = perms.uint16Value
            if mode & 0o022 != 0 {
                bbLog.warning("smc binary has group/other write permissions (mode: \(String(mode, radix: 8)))")
                return false
            }
        }

        return true
    }

    func verifySMCBinary() -> Bool {
        guard validateSmcFileProperties() else { return false }

        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: smcPath),
              let modDate = attrs[.modificationDate] as? Date else {
            bbLog.warning("Cannot read modification date of smc binary")
            return false
        }

        // Cache hit: mod date unchanged since last check
        if let cached = cachedSmcModDate, cached == modDate {
            return cachedSmcHash != nil
        }

        // Compute hash
        guard let fileData = fm.contents(atPath: smcPath) else {
            bbLog.error("Cannot read smc binary for hashing")
            return false
        }
        let digest = SHA256.hash(data: fileData)
        let currentHash = digest.map { String(format: "%02x", $0) }.joined()

        // Compare to stored hash
        let storedHash = loadHashFromKeychain()
        if storedHash == nil {
            // First launch — trust the current binary
            bbLog.info("No stored smc hash — trusting current binary and saving hash")
            saveHashToKeychain(currentHash)
            cachedSmcHash = currentHash
            cachedSmcModDate = modDate
            return true
        }

        if currentHash != storedHash {
            bbLog.error("smc binary hash mismatch — binary may have been tampered with")
            cachedSmcHash = nil
            cachedSmcModDate = modDate
            return false
        }

        // Hash matches
        cachedSmcHash = currentHash
        cachedSmcModDate = modDate
        return true
    }

    /// Recalculate hash and store in Keychain. Only call after interactive user confirmation.
    func trustCurrentSMCBinary() {
        let fm = FileManager.default
        guard let fileData = fm.contents(atPath: smcPath) else {
            bbLog.error("Cannot read smc binary for re-trust")
            return
        }
        let digest = SHA256.hash(data: fileData)
        let newHash = digest.map { String(format: "%02x", $0) }.joined()
        saveHashToKeychain(newHash)

        if let attrs = try? fm.attributesOfItem(atPath: smcPath),
           let modDate = attrs[.modificationDate] as? Date {
            cachedSmcHash = newHash
            cachedSmcModDate = modDate
        }
        bbLog.info("smc binary re-trusted with new hash")
    }

    // MARK: - Key Operations

    func readKey(_ key: String) -> String? {
        let output = runSMC(args: ["-k", key, "-r"])
        guard let output = output, !output.contains("no data") else { return nil }
        return output
    }

    func writeKey(_ key: String, value: String) -> Bool {
        guard runSMC(args: ["-k", key, "-w", value]) != nil else { return false }

        // Read-after-write verification: the SMC may silently reject or clamp values.
        guard let readBack = runSMC(args: ["-k", key, "-r"]) else {
            bbLog.warning("SMC read-back failed for key \(key) — assuming write failed (fail-closed)")
            return false
        }

        let writtenHex = value.lowercased().replacingOccurrences(of: " ", with: "")
        guard let readHex = extractHexBytes(from: readBack) else {
            bbLog.warning("Cannot parse SMC output for key \(key) — assuming write failed (fail-closed)")
            return false
        }

        if readHex != writtenHex {
            bbLog.error("SMC write verification failed for key \(key): wrote \(writtenHex), read back \(readHex)")
            return false
        }
        return true
    }

    /// Extract hex byte values from smc read output.
    /// Typical format: "  CHTE  [ui32]  (bytes 01 00 00 00)"
    private func extractHexBytes(from output: String) -> String? {
        guard let start = output.range(of: "(bytes ") else { return nil }
        let afterBytes = output[start.upperBound...]
        guard let end = afterBytes.firstIndex(of: ")") else { return nil }
        return String(afterBytes[..<end])
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    // MARK: - High-Level Charge Control

    func enableCharging() -> Bool {
        if supportsTahoe {
            return writeKey("CHTE", value: "00000000")
        } else if supportsLegacy {
            let a = writeKey("CH0B", value: "00")
            let b = writeKey("CH0C", value: "00")
            return a && b
        }
        return false
    }

    func disableCharging() -> Bool {
        if supportsTahoe {
            return writeKey("CHTE", value: "01000000")
        } else if supportsLegacy {
            let a = writeKey("CH0B", value: "02")
            let b = writeKey("CH0C", value: "02")
            return a && b
        }
        return false
    }

    func enableDischarge() -> Bool {
        if supportsTahoe {
            return writeKey("CHIE", value: "08")
        } else if supportsLegacy {
            return writeKey("CH0I", value: "01")
        }
        return false
    }

    func disableDischarge() -> Bool {
        if supportsTahoe {
            return writeKey("CHIE", value: "00")
        } else if supportsLegacy {
            return writeKey("CH0I", value: "00")
        }
        return false
    }

    @discardableResult
    func setMagSafeLED(_ color: MagSafeLEDColor) -> Bool {
        writeKey("ACLC", value: String(format: "%02x", color.rawValue))
    }

    // MARK: - Capabilities Detection

    /// Re-probe SMC capabilities (useful if smc binary was temporarily unavailable)
    func redetectCapabilities() {
        supportsTahoe = false
        supportsLegacy = false
        isAvailable = false
        detectCapabilities()
    }

    private func detectCapabilities() {
        guard FileManager.default.fileExists(atPath: smcPath) else {
            isAvailable = false
            return
        }

        guard verifySMCBinary() else {
            bbLog.error("smc binary failed integrity check — marking unavailable")
            isAvailable = false
            return
        }

        isAvailable = true

        // Try Tahoe keys (M1+)
        if let result = readKey("CHTE"), !result.isEmpty {
            supportsTahoe = true
        }

        // Try Legacy keys (Intel)
        if !supportsTahoe {
            if let result = readKey("CH0B"), !result.isEmpty {
                supportsLegacy = true
            }
        }
    }

    // MARK: - Process Execution

    private func runSMC(args: [String]) -> String? {
        // Verify binary integrity before every execution (TOCTOU mitigation)
        guard verifySMCBinary() else {
            bbLog.error("smc binary integrity check failed — refusing to execute")
            return nil
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", smcPath] + args
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            // Check stderr for sudoers issues
            if let stderrStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !stderrStr.isEmpty {
                bbLog.warning("smc stderr: \(stderrStr)")
                if stderrStr.contains("a password is required") || stderrStr.contains("no tty present") {
                    bbLog.error("Sudo requires password — sudoers may not be installed correctly")
                    needsSudoersReinstall = true
                }
            }

            if process.terminationStatus != 0 {
                return nil
            }
            return output
        } catch {
            bbLog.error("Failed to launch smc process: \(error.localizedDescription)")
            return nil
        }
    }
}
