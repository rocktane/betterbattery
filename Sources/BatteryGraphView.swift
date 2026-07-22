import Cocoa

/// Stores timestamped battery percentage readings, pruning entries older than 7 days.
class BatteryHistory {
    struct Entry: Codable {
        let date: Date
        let percentage: Int
        let isCharging: Bool
    }

    private(set) var entries: [Entry] = []
    private let maxAge: TimeInterval = 7 * 24 * 3600  // 7 days
    private var lastSave = Date.distantPast
    private let saveInterval: TimeInterval = 60

    /// ~/Library/Application Support/BetterBattery/history.json
    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("BetterBattery", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    init() {
        load()
    }

    func record(percentage: Int, isCharging: Bool) {
        let now = Date()
        // Deduplicate: skip if same percentage as last entry and less than 60s ago
        if let last = entries.last,
           last.percentage == percentage,
           now.timeIntervalSince(last.date) < 60 {
            return
        }
        entries.append(Entry(date: now, percentage: percentage, isCharging: isCharging))
        prune()
        // Throttled save: at most once a minute, enough for the graph's granularity.
        if now.timeIntervalSince(lastSave) >= saveInterval {
            save()
            lastSave = now
        }
    }

    func saveNow() { save() }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        entries.removeAll { $0.date < cutoff }
    }

    private func load() {
        guard let url = Self.fileURL,
              let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = saved
        prune()
    }

    private func save() {
        guard let url = Self.fileURL,
              let data = try? JSONEncoder().encode(entries)
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Apple Settings-style battery histogram: one green bar per hour over the last 7 days,
/// with day labels on the axis and 0/50/100% gridlines on the right.
class BatteryGraphView: NSView {
    var history: BatteryHistory?

    private let insetLeft: CGFloat = 12
    private let insetRight: CGFloat = 40   // space for % labels
    private let insetTop: CGFloat = 14
    private let insetBottom: CGFloat = 24  // space for day labels

    private let windowSeconds: TimeInterval = 7 * 24 * 3600
    private let bucketSeconds: TimeInterval = 3600   // one bar per hour
    private static let barGreen = NSColor(srgbRed: 52/255.0, green: 211/255.0, blue: 153/255.0, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let entries = history?.entries ?? []

        let rect = NSRect(
            x: insetLeft,
            y: insetBottom,
            width: bounds.width - insetLeft - insetRight,
            height: bounds.height - insetTop - insetBottom
        )

        drawGrid(ctx: ctx, rect: rect)
        drawDayLabels(ctx: ctx, rect: rect)

        if entries.count >= 2 {
            drawBars(ctx: ctx, rect: rect, entries: entries)
        } else {
            drawPlaceholder(rect: rect)
        }
    }

    // MARK: - Grid (0 / 20 / 40 / 60 / 80 / 100%)

    private func drawGrid(ctx: CGContext, rect: NSRect) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        for pct in stride(from: 0, through: 100, by: 20) {
            let y = rect.minY + rect.height * CGFloat(pct) / 100.0
            ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(pct == 0 ? 0.20 : 0.08).cgColor)
            ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            ctx.strokePath()

            if pct % 50 == 0 {
                let str = "\(pct)%" as NSString
                let size = str.size(withAttributes: attrs)
                str.draw(at: NSPoint(x: rect.maxX + 6, y: y - size.height / 2), withAttributes: attrs)
            }
        }
    }

    // MARK: - Day labels (one per midnight)

    private func drawDayLabels(ctx: CGContext, rect: NSRect) {
        let font = NSFont.systemFont(ofSize: 9, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"

        let now = Date()
        let cal = Calendar.current
        var midnight = cal.startOfDay(for: now)

        while now.timeIntervalSince(midnight) <= windowSeconds {
            let age = now.timeIntervalSince(midnight)
            let x = rect.minX + rect.width * CGFloat(1.0 - age / windowSeconds)

            // Tick
            ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.15).cgColor)
            ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: x, y: rect.minY))
            ctx.addLine(to: CGPoint(x: x, y: rect.minY - 4))
            ctx.strokePath()

            let str = formatter.string(from: midnight) as NSString
            let size = str.size(withAttributes: attrs)
            let labelX = min(max(rect.minX, x + 3), rect.maxX - size.width)
            str.draw(at: NSPoint(x: labelX, y: rect.minY - 5 - size.height), withAttributes: attrs)

            guard let prev = cal.date(byAdding: .day, value: -1, to: midnight) else { break }
            midnight = prev
        }
    }

    // MARK: - Bars (hourly average, rounded tops)

    private func drawBars(ctx: CGContext, rect: NSRect, entries: [BatteryHistory.Entry]) {
        let now = Date()
        let bucketCount = Int(windowSeconds / bucketSeconds)

        // Average percentage per hourly bucket (0 = oldest, last = current hour)
        var sums = [Int](repeating: 0, count: bucketCount)
        var counts = [Int](repeating: 0, count: bucketCount)
        for e in entries {
            let age = now.timeIntervalSince(e.date)
            guard age >= 0, age < windowSeconds else { continue }
            let idx = bucketCount - 1 - Int(age / bucketSeconds)
            guard idx >= 0, idx < bucketCount else { continue }
            sums[idx] += e.percentage
            counts[idx] += 1
        }

        let slot = rect.width / CGFloat(bucketCount)
        let barWidth = max(1, slot * 0.72)   // small gap between bars, Apple-style

        ctx.saveGState()
        Self.barGreen.setFill()
        for i in 0..<bucketCount {
            guard counts[i] > 0 else { continue }
            let pct = CGFloat(sums[i]) / CGFloat(counts[i])
            let h = max(2, rect.height * pct / 100.0)
            let x = rect.minX + CGFloat(i) * slot + (slot - barWidth) / 2
            let bar = NSRect(x: x, y: rect.minY, width: barWidth, height: h)
            let radius = min(barWidth / 2, 2)
            NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
        }
        ctx.restoreGState()
    }

    // MARK: - Placeholder

    private func drawPlaceholder(rect: NSRect) {
        let str = "Collecting data..." as NSString
        let font = NSFont.systemFont(ofSize: 11)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let size = str.size(withAttributes: attrs)
        str.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attrs
        )
    }
}
