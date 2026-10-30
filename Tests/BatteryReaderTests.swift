import Foundation

@main
struct BatteryReaderTests {
    static func main() {
        var count = 0
        func expect(_ condition: Bool, _ message: String) {
            guard condition else { print("FAIL: \(message)"); exit(1) }
            count += 1
        }
        func decode(_ props: [String: Any]) -> BatteryState {
            var state = BatteryState()
            BatteryReader.applySmartBatteryProperties(props, to: &state)
            return state
        }
        // Sanitized snapshot observed on macOS 27.0.1 (26A434).
        let snapshot: [String: Any] = [
            "MaxCapacity": 100, "CurrentCapacity": 54, "CycleCount": 666,
            "Voltage": 11475, "Amperage": -562,
            "BatteryData": ["DesignCapacity": 6075, "FullChargeCapacity": 4854,
                            "NominalChargeCapacity": 5004, "MaxCapacity": 100,
                            "CurrentCapacity": 54]
        ]
        let state = decode(snapshot)
        expect(state.health == 80, "macOS 27 health must use nested mAh capacities")
        expect(state.percentage == 54 && state.cycleCount == 666, "charge and cycles")
        expect(state.voltage == 11.475 && state.amperage == -562, "voltage and signed current")
        expect(state.temperature == nil, "missing temperature must not be 0°C")
        expect(state.serviceRecommended == nil, "unknown condition must not be Normal")
        expect(decode([:]).health == nil, "missing health must not be 100%")
        expect(decode(["MaxCapacity": 100, "DesignCapacity": 6075]).health == nil,
               "normalized capacity must not be treated as mAh on ARM")
        expect(decode(["AppleRawMaxCapacity": 4800, "DesignCapacity": 6000]).health == 80,
               "older macOS root capacities")
        expect(decode(["BatteryData": ["NominalChargeCapacity": 4800, "DesignCapacity": 6000]]).health == 80,
               "nominal capacity fallback")
        expect(decode(["BatteryData": ["FullChargeCapacity": 0, "DesignCapacity": 6000],
                       "AppleRawMaxCapacity": 4800, "DesignCapacity": 6000]).health == 80,
               "invalid primary capacity must allow fallback")
        for invalid in [0, -1] {
            expect(decode(["AppleRawMaxCapacity": 4800, "DesignCapacity": invalid]).health == nil,
                   "invalid design capacity")
        }
        expect(decode(["AppleRawMaxCapacity": 6200, "DesignCapacity": 6000]).health == 100,
               "new batteries slightly above design cap at 100%")
        expect(decode(["Temperature": 3215]).temperature == 32.15, "legacy temperature")
        expect(decode(["BatteryData": ["Temperature": 3215]]).temperature == 32.15, "nested temperature")
        expect(decode(["Temperature": 0]).temperature == nil, "invalid temperature")
        expect(decode(["CurrentCapacity": 120, "MaxCapacity": 100]).percentage == 100, "bounded charge")
        expect(decode(["PowerTelemetryData": ["SystemPowerIn": 23000]]).systemPowerIn == 23000,
               "adapter telemetry")
        let reply = HelperReply<Int>()
        reply.finish(42)
        reply.finish(99)
        expect(reply.wait(timeout: 0.01) == 42, "first reply wins")
        let silent = HelperReply<Int>()
        expect(silent.wait(timeout: 0.01) == nil, "silent helper returns on timeout")
        silent.finish(99)
        expect(silent.wait(timeout: 0.01) == nil, "late callback cannot overwrite timeout")
        let error = HelperReply<Int>()
        error.finish(nil)
        expect(error.wait(timeout: 0.01) == nil, "XPC error completes wait")
        if CommandLine.arguments.contains("--live") {
            let reader = BatteryReader()
            reader.onUpdate = { state in
                print("LIVE: health=\(state.health.map(String.init) ?? "unavailable")%, temperature=\(state.temperature.map(String.init(describing:)) ?? "unavailable"), cycles=\(state.cycleCount.map(String.init) ?? "unavailable")")
            }
            reader.start()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            reader.stop()
        }
        print("PASS: \(count) battery decoding / helper reply checks")
    }
}
