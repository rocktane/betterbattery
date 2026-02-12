import Cocoa
import os.log

let bbLog = Logger(subsystem: "com.betterbattery.app", category: "general")

/// Atomic single-instance lock via flock(). Fd kept open for process lifetime.
private var instanceLockFd: Int32 = -1

private func acquireInstanceLock() -> Bool {
    let lockPath = NSTemporaryDirectory() + "com.betterbattery.lock"
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return false }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        close(fd)
        return false
    }
    instanceLockFd = fd
    return true
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController!
    var batteryReader: BatteryReader!
    var chargeLimiter: ChargeLimiter!
    var smcController: SMCController!
    private var sigTermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance guard (kernel-level flock)
        if !acquireInstanceLock() {
            bbLog.warning("Another instance is already running, exiting.")
            NSApp.terminate(nil)
            return
        }

        smcController = SMCController()
        batteryReader = BatteryReader()
        chargeLimiter = ChargeLimiter(smc: smcController)
        statusBarController = StatusBarController(
            batteryReader: batteryReader,
            chargeLimiter: chargeLimiter,
            smc: smcController
        )

        batteryReader.onUpdate = { [weak self] state in
            guard let self = self else { return }
            self.statusBarController.update(state: state)
            self.chargeLimiter.check(percentage: state.percentage, isPluggedIn: state.isPluggedIn, temperature: state.temperature)
        }

        // Restore saved settings (crash-safe: relies on UserDefaults persisted by ChargeLimiter)
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "chargeLimitEnabled") != nil {
            if defaults.bool(forKey: "chargeLimitEnabled") {
                let limit = defaults.integer(forKey: "chargeLimitPercentage")
                chargeLimiter.limitPercentage = (limit >= 20 && limit <= 100) ? limit : 80
                chargeLimiter.start()
            }
        }

        // If limiter is not active, always ensure SMC allows charging.
        // Covers: crash recovery, desync between internal state and SMC, external tools.
        if !chargeLimiter.isActive {
            if !smcController.enableCharging() {
                bbLog.warning("Failed to re-enable charging at startup")
            }
            smcController.setMagSafeLED(.system)
            defaults.set(false, forKey: "chargingWasDisabled")
        }

        installSignalHandler()
        registerForWakeNotifications()
        Setup.checkFirstRun()
        batteryReader.start()

        // Post-startup checks (after first battery cycle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }
            // Check if sudoers needs reinstallation
            if self.smcController.needsSudoersReinstall {
                bbLog.warning("Sudoers reinstallation needed — prompting user")
                let alert = NSAlert()
                alert.messageText = "Missing sudo permissions"
                alert.informativeText = "Sudo permissions are not working correctly. Would you like to reinstall the sudoers rules?"
                alert.addButton(withTitle: "Reinstall")
                alert.addButton(withTitle: "Later")
                alert.alertStyle = .warning
                if alert.runModal() == .alertFirstButtonReturn {
                    Setup.installSudoers()
                }
            }
            // Check if SMC binary failed integrity (hash mismatch)
            if !self.smcController.isAvailable && FileManager.default.fileExists(atPath: "/usr/local/bin/smc") {
                let alert = NSAlert()
                alert.messageText = "smc binary modified"
                alert.informativeText = "The /usr/local/bin/smc binary has changed since the last check. If you updated it intentionally, click 'Trust'."
                alert.addButton(withTitle: "Trust")
                alert.addButton(withTitle: "Don't run")
                alert.alertStyle = .critical
                if alert.runModal() == .alertFirstButtonReturn {
                    self.smcController.trustCurrentSMCBinary()
                    self.smcController.redetectCapabilities()
                    bbLog.info("User chose to trust updated smc binary")
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanupAndRestore()
    }

    // MARK: - SIGTERM handler

    private func installSignalHandler() {
        // Ignore default SIGTERM so we can handle it ourselves
        signal(SIGTERM, SIG_IGN)

        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            // NSApp.terminate triggers applicationWillTerminate → cleanupAndRestore
            NSApp.terminate(nil)
        }
        source.resume()
        sigTermSource = source
    }

    // MARK: - Wake from sleep

    private func registerForWakeNotifications() {
        let nc = NSWorkspace.shared.notificationCenter

        // Before sleep: disable charging if configured
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.chargeLimiter.onSleep()
        }

        // After wake: re-assert SMC state and refresh battery data
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.chargeLimiter.onWake()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.batteryReader.refresh()
            }
        }
    }

    private func cleanupAndRestore() {
        batteryReader.stop()

        // Remember whether the limit was active before stopping
        let wasActive = chargeLimiter.isActive

        // Re-enable charging if we had it disabled
        if chargeLimiter.isActive && !chargeLimiter.chargingEnabled {
            if !smcController.enableCharging() {
                bbLog.warning("Failed to re-enable charging during cleanup")
            }
            smcController.setMagSafeLED(.system)
        }

        chargeLimiter.stop()

        // Restore the enabled flag so the limit is re-applied on next launch
        if wasActive {
            UserDefaults.standard.set(true, forKey: "chargeLimitEnabled")
        }
        UserDefaults.standard.set(false, forKey: "chargingWasDisabled")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
