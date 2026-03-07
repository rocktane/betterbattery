import Foundation
import Cocoa
import os.log

struct Setup {
    private static let smcPath = "/usr/local/bin/smc"
    private static let sudoersPath = "/etc/sudoers.d/battery"

    static func checkFirstRun() {
        let defaults = UserDefaults.standard
        let hasRun = defaults.bool(forKey: "hasCompletedSetup")

        if !hasRun {
            performSetup()
            defaults.set(true, forKey: "hasCompletedSetup")
            defaults.set(true, forKey: "sudoersV5")
            defaults.set(NSUserName(), forKey: "sudoersInstalledUser")
        } else {
            verifySetup()
            // Upgrade sudoers if needed (V5 reduces ACLC whitelist to used values only)
            let needsUpgrade = !defaults.bool(forKey: "sudoersV5")
            let userChanged = defaults.string(forKey: "sudoersInstalledUser") != NSUserName()
            if needsUpgrade || userChanged {
                if FileManager.default.fileExists(atPath: sudoersPath) {
                    installSudoers()
                }
                defaults.set(true, forKey: "sudoersV5")
                defaults.set(NSUserName(), forKey: "sudoersInstalledUser")
            }
        }
    }

    private static func performSetup() {
        // Check smc binary
        if !FileManager.default.fileExists(atPath: smcPath) {
            showSMCMissingAlert()
            return
        }

        // Check/install sudoers
        if !FileManager.default.fileExists(atPath: sudoersPath) {
            installSudoers()
        }
    }

    private static func verifySetup() {
        if !FileManager.default.fileExists(atPath: smcPath) {
            // smc was removed — show warning but don't block
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "smc not found"
                alert.informativeText = "The binary /usr/local/bin/smc does not exist. Charge limiting will not work.\n\nInstall it from: github.com/actuallymentor/battery"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        } else if !FileManager.default.fileExists(atPath: sudoersPath) {
            // smc exists but sudoers was never installed (e.g., first setup ran without smc)
            installSudoers()
        }
    }

    private static func showSMCMissingAlert() {
        let alert = NSAlert()
        alert.messageText = "Initial setup"
        alert.informativeText = "Better Battery requires the 'smc' binary to control charging.\n\nIt was not found at /usr/local/bin/smc.\n\nYou can install it from:\n• github.com/actuallymentor/battery\n\nBattery reading will work, but charge limiting will not."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Install sudoers anyway")

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            installSudoers()
        }
    }

    static func installSudoers() {
        // Validate username before insertion
        let username = NSUserName()
        let usernameRegex = try? NSRegularExpression(pattern: "^[a-zA-Z0-9._-]+$")
        let usernameRange = NSRange(username.startIndex..<username.endIndex, in: username)
        guard let regex = usernameRegex, regex.firstMatch(in: username, range: usernameRange) != nil else {
            bbLog.error("Invalid username for sudoers: \(username)")
            return
        }

        // Restricted sudoers: only exact smc commands with known arguments are allowed.
        let sudoersContent = """
        # Better Battery - Restricted SMC access for charge control
        Cmnd_Alias BATTERY_CHARGE = /usr/local/bin/smc -k CHTE -r, /usr/local/bin/smc -k CHTE -w 00000000, /usr/local/bin/smc -k CHTE -w 01000000, /usr/local/bin/smc -k CH0B -r, /usr/local/bin/smc -k CH0B -w 00, /usr/local/bin/smc -k CH0B -w 02, /usr/local/bin/smc -k CH0C -r, /usr/local/bin/smc -k CH0C -w 00, /usr/local/bin/smc -k CH0C -w 02
        Cmnd_Alias BATTERY_DISCHARGE = /usr/local/bin/smc -k CHIE -r, /usr/local/bin/smc -k CHIE -w 00, /usr/local/bin/smc -k CHIE -w 08, /usr/local/bin/smc -k CH0I -r, /usr/local/bin/smc -k CH0I -w 00, /usr/local/bin/smc -k CH0I -w 01
        Cmnd_Alias BATTERY_LED = /usr/local/bin/smc -k ACLC -r, /usr/local/bin/smc -k ACLC -w 00, /usr/local/bin/smc -k ACLC -w 03, /usr/local/bin/smc -k ACLC -w 07
        Cmnd_Alias BATTERY_POWER = /usr/bin/pmset -a lowpowermode 0, /usr/bin/pmset -a lowpowermode 1
        \(username) ALL = NOPASSWD: BATTERY_CHARGE
        \(username) ALL = NOPASSWD: BATTERY_DISCHARGE
        \(username) ALL = NOPASSWD: BATTERY_LED
        \(username) ALL = NOPASSWD: BATTERY_POWER
        """

        // Write to temp file (no shell interpolation = no injection possible)
        let tmpPath = NSTemporaryDirectory() + "betterbattery_sudoers"
        let fm = FileManager.default

        // Clean up any existing temp file
        try? fm.removeItem(atPath: tmpPath)

        guard fm.createFile(atPath: tmpPath, contents: sudoersContent.data(using: .utf8),
                            attributes: [.posixPermissions: 0o600]) else {
            bbLog.error("Failed to create temporary sudoers file")
            return
        }

        defer { try? fm.removeItem(atPath: tmpPath) }

        // Privileged command: backup existing, copy temp file, validate, restore on failure
        let script = """
        do shell script "cp /etc/sudoers.d/battery /etc/sudoers.d/battery.bak 2>/dev/null; cp \(tmpPath) /etc/sudoers.d/battery && chmod 0440 /etc/sudoers.d/battery && /usr/sbin/visudo -c -f /etc/sudoers.d/battery 2>/dev/null || (mv /etc/sudoers.d/battery.bak /etc/sudoers.d/battery 2>/dev/null; false)" with administrator privileges
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                bbLog.error("Failed to install sudoers: \(error)")
            } else {
                bbLog.info("Sudoers installed successfully for user \(username)")
            }
        }
    }
}
