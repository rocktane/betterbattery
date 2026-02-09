import Foundation
import os.log

struct LaunchAtLogin {
    private static let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.betterbattery.plist"
    private static let bundleID = "com.betterbattery.app"

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    static func enable() {
        let fm = FileManager.default
        let appPath = Bundle.main.bundlePath + "/Contents/MacOS/BetterBattery"

        let plistContent: [String: Any] = [
            "Label": bundleID,
            "ProgramArguments": [appPath],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false]
        ]

        // Ensure LaunchAgents directory exists
        let launchAgentsDir = NSHomeDirectory() + "/Library/LaunchAgents"
        if !fm.fileExists(atPath: launchAgentsDir) {
            try? fm.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)
        }

        // Anti-symlink check: refuse to write if existing path is a symlink
        if fm.fileExists(atPath: plistPath) {
            if let attrs = try? fm.attributesOfItem(atPath: plistPath),
               let fileType = attrs[.type] as? FileAttributeType,
               fileType == .typeSymbolicLink {
                bbLog.error("LaunchAgent path is a symlink — refusing to write")
                return
            }
        }

        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plistContent,
            format: .xml,
            options: 0
        ) else {
            bbLog.error("Failed to serialize LaunchAgent plist")
            return
        }

        // Atomic write via temp file + replace
        let tmpPath = plistPath + ".tmp"

        // Clean up any stale temp file
        try? fm.removeItem(atPath: tmpPath)

        guard fm.createFile(atPath: tmpPath, contents: data,
                            attributes: [.posixPermissions: 0o600]) else {
            bbLog.error("Failed to create temporary LaunchAgent file")
            return
        }

        do {
            let targetURL = URL(fileURLWithPath: plistPath)
            let tmpURL = URL(fileURLWithPath: tmpPath)

            if fm.fileExists(atPath: plistPath) {
                _ = try fm.replaceItemAt(targetURL, withItemAt: tmpURL)
            } else {
                try fm.moveItem(at: tmpURL, to: targetURL)
            }

            // Ensure permissions are 0600 on final file
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistPath)
        } catch {
            bbLog.error("Failed to write LaunchAgent plist: \(error.localizedDescription)")
            try? fm.removeItem(atPath: tmpPath)
        }
    }

    static func disable() {
        try? FileManager.default.removeItem(atPath: plistPath)
    }
}
