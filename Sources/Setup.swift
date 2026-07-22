import Foundation
import Cocoa
import ServiceManagement
import os.log

/// Registers and monitors the privileged helper daemon via SMAppService.
enum HelperManager {
    static let service = SMAppService.daemon(plistName: "com.betterbattery.helper.plist")

    /// Register the daemon, guiding the user through approval if needed.
    /// Returns the resulting status.
    @discardableResult
    static func ensureRegistered() -> SMAppService.Status {
        switch service.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            promptForApproval()
            return .requiresApproval
        default:
            do {
                try service.register()
            } catch {
                bbLog.error("Helper registration failed: \(error.localizedDescription)")
            }
            if service.status == .requiresApproval {
                promptForApproval()
            }
            return service.status
        }
    }

    private static func promptForApproval() {
        let alert = NSAlert()
        alert.messageText = "Approval required"
        alert.informativeText = "BetterBattery needs its background helper approved to control charging.\n\nIn System Settings → General → Login Items & Extensions, enable BetterBattery under \"Allow in the Background\"."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    static func unregister() {
        do {
            try service.unregister()
            bbLog.info("Helper daemon unregistered")
        } catch {
            bbLog.error("Helper unregistration failed: \(error.localizedDescription)")
        }
    }

    /// Unregister then register again, reloading the daemon binary.
    /// BTM completes the removal asynchronously: right after unregister() the
    /// status can still read .enabled, where register() is a silent no-op. Wait
    /// for the removal to land, then register (retrying while the system settles).
    static func reregister() {
        unregister()
        var registered = false
        for _ in 0..<10 {
            if service.status != .enabled {
                do {
                    try service.register()
                    bbLog.info("Helper daemon re-registered")
                    registered = true
                    break
                } catch {
                    bbLog.info("Helper re-register attempt failed: \(error.localizedDescription)")
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if service.status == .requiresApproval {
            promptForApproval()
        } else if !registered {
            bbLog.error("Helper re-registration failed (status \(service.status.rawValue))")
        }
    }
}

/// One-time cleanup of the pre-daemon architecture (external smc binary +
/// sudoers + Keychain hash). Retries on next launch if the user cancels the
/// admin prompt.
enum LegacyCleanup {
    private static let sudoersPath = "/etc/sudoers.d/battery"
    private static let doneKey = "legacySudoersCleaned"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }

        var sudoersRemoved = true
        if FileManager.default.fileExists(atPath: sudoersPath) {
            sudoersRemoved = removeSudoers()
        }

        deleteKeychainHash()
        defaults.removeObject(forKey: "hasCompletedSetup")
        defaults.removeObject(forKey: "sudoersV5")
        defaults.removeObject(forKey: "sudoersV6")
        defaults.removeObject(forKey: "sudoersInstalledUser")

        if sudoersRemoved {
            defaults.set(true, forKey: doneKey)
        }
    }

    private static func removeSudoers() -> Bool {
        let alert = NSAlert()
        alert.messageText = "One-time cleanup"
        alert.informativeText = "BetterBattery no longer uses sudo to control charging. Your administrator password is needed one last time to remove the old configuration (/etc/sudoers.d/battery)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let script = """
        do shell script "rm -f /etc/sudoers.d/battery /etc/sudoers.d/battery.bak" with administrator privileges
        """
        guard let appleScript = NSAppleScript(source: script) else { return false }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error = error {
            bbLog.error("Failed to remove legacy sudoers: \(error)")
            return false
        }
        bbLog.info("Legacy sudoers removed")
        return true
    }

    private static func deleteKeychainHash() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.betterbattery.smc-hash",
            kSecAttrAccount as String: "sha256"
        ]
        SecItemDelete(query as CFDictionary)
    }
}
