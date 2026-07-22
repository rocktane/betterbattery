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

        LegacyCleanup.runIfNeeded()
        HelperManager.ensureRegistered()

        Notifier.setup()
        smcController = SMCController()

        // An already-approved daemon survives app upgrades (SMAppService stays
        // .enabled), so a stale binary would keep serving an old protocol and
        // fail silently. Version mismatch, a daemon pinning another signing
        // identity (rejects us → no answer), or a registration launchd can no
        // longer spawn all land here: re-register to reload the daemon.
        // A registration issued too soon after the unregister can itself yield
        // a stale launch constraint ("spawn failed"), so verify the daemon
        // actually answers and retry the whole cycle with a growing settle delay.
        if HelperManager.service.status == .enabled {
            var daemonVersion = smcController.helperVersion()
            var attempt = 0
            while daemonVersion != kHelperVersion && attempt < 3 {
                attempt += 1
                bbLog.info("Helper stale or unreachable (\(daemonVersion ?? "no answer"), attempt \(attempt)) — re-registering daemon")
                HelperManager.reregister()
                Thread.sleep(forTimeInterval: Double(attempt))
                smcController.redetectCapabilities()
                daemonVersion = smcController.helperVersion()
            }
            if daemonVersion != kHelperVersion {
                bbLog.error("Helper still unreachable after \(attempt) re-registrations")
            }
        }
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
        }

        installSignalHandler()
        registerForWakeNotifications()
        batteryReader.start()

        // If the helper isn't approved yet, poll until it becomes enabled,
        // then re-probe capabilities and re-assert the SMC state.
        if HelperManager.service.status != .enabled || !smcController.isAvailable {
            startHelperApprovalWatch()
        }
    }

    /// Poll the daemon status while the user approves it in System Settings.
    private var helperWatchTimer: Timer?

    private func startHelperApprovalWatch() {
        helperWatchTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard HelperManager.service.status == .enabled else { return }
            self.smcController.redetectCapabilities()
            if self.smcController.isAvailable {
                bbLog.info("Helper daemon approved and reachable")
                self.helperWatchTimer?.invalidate()
                self.helperWatchTimer = nil
                if !self.chargeLimiter.isActive {
                    _ = self.smcController.enableCharging()
                    self.smcController.setMagSafeLED(.system)
                } else {
                    self.batteryReader.refresh()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.saveHistory()
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
        // A duplicate instance terminates from the instance-lock guard before
        // init completes: nothing to clean up, and the force-unwraps below
        // would trap — worse, touching SMC would undo the primary instance's
        // charging state.
        guard batteryReader != nil else { return }
        batteryReader.stop()

        // Stop an active drain so the Mac isn't left running off the battery while plugged in
        statusBarController?.stopDischarge(notify: false)

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
    }
}

// Used by `make uninstall` to remove the daemon registration
if CommandLine.arguments.contains("--uninstall-helper") {
    HelperManager.unregister()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
