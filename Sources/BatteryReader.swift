import Foundation
import IOKit
import IOKit.ps

struct BatteryState {
    var percentage: Int = 0
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var timeToEmpty: Int? = nil    // minutes
    var timeToCharge: Int? = nil   // minutes
    var health: Int? = nil
    var cycleCount: Int? = nil
    var voltage: Double = 0.0      // V
    var temperature: Double? = nil  // °C
    var amperage: Int = 0          // mA (negative = discharging)
    var adapterWatts: Int = 0      // AC adapter rated wattage
    var systemPowerIn: Int = 0     // mW actually drawn by the computer (adapter input)
    var manufactureDate: Date? = nil
    var serviceRecommended: Bool? = nil  // macOS's own battery condition flag

    var timeRemaining: Int? {
        if isCharging {
            return timeToCharge
        }
        return timeToEmpty
    }

    var timeRemainingFormatted: String? {
        guard let minutes = timeRemaining, minutes > 0, minutes < 6000 else { return nil }
        let h = minutes / 60
        let m = minutes % 60
        return "\(h):\(String(format: "%02d", m))"
    }
}

class BatteryReader {
    var onUpdate: ((BatteryState) -> Void)?
    private var runLoopSource: CFRunLoopSource?
    private var refreshTimer: Timer?

    func start() {
        stop()
        // Register for power source change notifications
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let ctx = context else { return }
            let reader = Unmanaged<BatteryReader>.fromOpaque(ctx).takeUnretainedValue()
            reader.readBatteryState()
        }, context)?.takeRetainedValue() {
            self.runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        // Power-source notifications need not fire for temperature/telemetry changes.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.readBatteryState()
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        // Initial read
        readBatteryState()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
    }

    /// Force a fresh battery state read (used after wake from sleep)
    func refresh() {
        readBatteryState()
    }

    private func readBatteryState() {
        var state = BatteryState()

        // Read from IOPowerSources for basic info
        readPowerSources(&state)

        // Read from AppleSmartBattery for detailed info
        readSmartBattery(&state)

        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(state)
        }
    }

    private func readPowerSources(_ state: inout BatteryState) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              !sources.isEmpty else { return }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            if let type = info[kIOPSTypeKey] as? String, type != kIOPSInternalBatteryType {
                continue
            }

            if let capacity = info[kIOPSCurrentCapacityKey] as? Int {
                state.percentage = capacity
            }
            if let charging = info[kIOPSIsChargingKey] as? Bool {
                state.isCharging = charging
            }
            if let source = info[kIOPSPowerSourceStateKey] as? String {
                state.isPluggedIn = (source == kIOPSACPowerValue)
            }
            if let timeToEmpty = info[kIOPSTimeToEmptyKey] as? Int, timeToEmpty > 0 {
                state.timeToEmpty = timeToEmpty
            }
            if let timeToCharge = info[kIOPSTimeToFullChargeKey] as? Int, timeToCharge > 0 {
                state.timeToCharge = timeToCharge
            }
            // Battery condition as System Settings reports it: powerd publishes
            // "Good" + an empty condition while the battery is Normal, and sets
            // BatteryHealthCondition (e.g. "Check Battery") when service is due.
            if let health = info[kIOPSBatteryHealthKey] as? String {
                state.serviceRecommended = health != kIOPSGoodValue
            }
            if let condition = info[kIOPSBatteryHealthConditionKey] as? String, !condition.isEmpty {
                state.serviceRecommended = true
            }
        }

        // AC adapter rated wattage (e.g., 67W, 96W, 140W)
        if let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
           let watts = details[kIOPSPowerAdapterWattsKey] as? Int {
            state.adapterWatts = watts
        }
    }

    private func readSmartBattery(_ state: inout BatteryState) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        if let props = getProperties(service) {
            Self.applySmartBatteryProperties(props, to: &state)
        }
    }

    /// Shared decoding path for live registry snapshots and regression fixtures.
    static func applySmartBatteryProperties(_ props: [String: Any], to state: inout BatteryState) {
        if let cycleCount = props["CycleCount"] as? Int {
            state.cycleCount = cycleCount
        }
        // macOS 27 moves the mAh capacities into BatteryData. Never divide
        // the normalized MaxCapacity (100 on Apple Silicon) by a mAh value.
        let data = props["BatteryData"] as? [String: Any] ?? [:]
        #if arch(arm64)
        let pairs: [(Any?, Any?)] = [
            (data["FullChargeCapacity"], data["DesignCapacity"]),
            (props["AppleRawMaxCapacity"], props["DesignCapacity"]),
            (data["NominalChargeCapacity"], data["DesignCapacity"]),
            (props["NominalChargeCapacity"], props["DesignCapacity"])
        ]
        #else
        let pairs: [(Any?, Any?)] = [(props["MaxCapacity"], props["DesignCapacity"])]
        #endif
        for (full, design) in pairs {
            guard let full = full as? Int, let design = design as? Int,
                  full > 0, design > 0 else { continue }
            let ratio = Double(full) / Double(design)
            guard ratio.isFinite, ratio <= 1.5 else { continue }
            state.health = min(100, Int((100 * ratio).rounded(.toNearestOrEven)))
            break
        }
        if let voltage = props["Voltage"] as? Int {
            state.voltage = Double(voltage) / 1000.0
        }
        if let temp = (props["Temperature"] ?? data["Temperature"]) as? Int,
           temp > 0, temp < 10000 {
            state.temperature = Double(temp) / 100.0
        }
        // Fallback for charging state from SMC level
        if let externalConnected = props["ExternalConnected"] as? Bool {
            state.isPluggedIn = externalConnected
        }
        if let isCharging = props["IsCharging"] as? Bool {
            state.isCharging = isCharging
        }
        if let currentCap = props["CurrentCapacity"] as? Int,
           let maxCap = props["MaxCapacity"] as? Int,
           maxCap > 0 {
            state.percentage = Int(min(100, max(0, Double(currentCap) / Double(maxCap) * 100)))
        }
        if let amperage = props["Amperage"] as? Int {
            state.amperage = amperage
        }
        // Actual power drawn by the computer from the adapter (mW), even when the
        // battery isn't charging. Present on Apple Silicon under PowerTelemetryData.
        if let telemetry = props["PowerTelemetryData"] as? [String: Any],
           let systemPowerIn = telemetry["SystemPowerIn"] as? Int, systemPowerIn > 0 {
            state.systemPowerIn = systemPowerIn
        }
        // Battery manufacture date. Intel exposes the SBS bitfield; Apple Silicon
        // encodes year + ISO week in the pack serial (same source coconutBattery uses —
        // BatteryData.ManufactureDate is a lot code, not a date).
        if let packed = props["ManufactureDate"] as? Int {
            state.manufactureDate = Self.dateFromSBS(packed)
        } else if let serial = props["Serial"] as? String {
            state.manufactureDate = Self.dateFromSerial(serial)
        }
        // Time values come from IOPowerSources only (same source as Stats app)
    }

    /// Apple Silicon pack serials encode the manufacture date after the 3-char site code:
    /// "F8Y13450…" → year digit 1, ISO week 34 → week of 23 August 2021. Returns that
    /// week's Monday. The year digit maps to the most recent matching year not in the future.
    private static func dateFromSerial(_ serial: String) -> Date? {
        let chars = Array(serial)
        guard chars.count >= 6,
              let yearDigit = chars[3].wholeNumberValue, chars[3].isNumber,
              let week = Int(String(chars[4...5])), (1...53).contains(week) else { return nil }
        let calendar = Calendar(identifier: .iso8601)
        let currentYear = calendar.component(.year, from: Date())
        var year = currentYear - ((currentYear - yearDigit) % 10)
        var comps = DateComponents()
        comps.yearForWeekOfYear = year
        comps.weekOfYear = week
        comps.weekday = 2  // Monday
        guard var date = calendar.date(from: comps) else { return nil }
        if date > Date() {  // week later this year than today → previous decade
            year -= 10
            comps.yearForWeekOfYear = year
            guard let earlier = calendar.date(from: comps) else { return nil }
            date = earlier
        }
        return date
    }

    /// SBS packed bitfield (Intel): day in bits 0–4, month in 5–8, year-1980 in 9–15.
    private static func dateFromSBS(_ packed: Int) -> Date? {
        let day = packed & 0x1F
        let month = (packed >> 5) & 0x0F
        let year = 1980 + ((packed >> 9) & 0x7F)
        guard (1...31).contains(day), (1...12).contains(month) else { return nil }
        return DateComponents(calendar: .current, year: year, month: month, day: day).date
    }

    private func getProperties(_ service: io_service_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS, let dict = props?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return dict
    }
}
