import Cocoa

/// Stores timestamped battery percentage readings, pruning entries older than 24h.
class BatteryHistory {
    struct Entry {
        let date: Date
        let percentage: Int
        let isCharging: Bool
    }

    private(set) var entries: [Entry] = []
    private let maxAge: TimeInterval = 24 * 3600  // 24h

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
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        entries.removeAll { $0.date < cutoff }
    }
}

/// CoreGraphics-based graph view for the menu, showing battery % over the last 24h.
class BatteryGraphView: NSView {
    var history: BatteryHistory?

    private let graphInsetLeft: CGFloat = 8
    private let graphInsetRight: CGFloat = 42  // space for right-side labels
    private let graphInsetTop: CGFloat = 8
    private let graphInsetBottom: CGFloat = 18  // space for time labels

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let entries = history?.entries ?? []

        let graphRect = NSRect(
            x: graphInsetLeft,
            y: graphInsetBottom,
            width: bounds.width - graphInsetLeft - graphInsetRight,
            height: bounds.height - graphInsetTop - graphInsetBottom
        )

        drawGridLines(ctx: ctx, rect: graphRect)
        drawTimeline(ctx: ctx, rect: graphRect)

        if entries.count >= 2 {
            drawLine(ctx: ctx, rect: graphRect, entries: entries)
            drawRightLabels(ctx: ctx, rect: graphRect, entries: entries)
        } else {
            drawPlaceholder(rect: graphRect)
        }
    }

    // MARK: - Grid (horizontal lines every 10%)

    private func drawGridLines(ctx: CGContext, rect: NSRect) {
        let lineColor = NSColor.labelColor.withAlphaComponent(0.08)
        let textColor = NSColor.secondaryLabelColor
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)

        for step in 0...10 {
            let pct = step * 10
            let y = rect.minY + rect.height * CGFloat(pct) / 100.0

            // Horizontal line
            ctx.setStrokeColor(lineColor.cgColor)
            ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            ctx.strokePath()

            // Left label every 20%
            if pct % 20 == 0 {
                let str = "\(pct)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: textColor
                ]
                let size = str.size(withAttributes: attrs)
                str.draw(at: NSPoint(x: rect.maxX + 4, y: y - size.height / 2), withAttributes: attrs)
            }
        }
    }

    // MARK: - Timeline (bottom axis)

    private func drawTimeline(ctx: CGContext, rect: NSRect) {
        let textColor = NSColor.secondaryLabelColor
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]

        // Show markers: 24h, 18h, 12h, 6h, now
        let markers: [(hours: Int, label: String)] = [
            (24, "24h"), (18, "18h"), (12, "12h"), (6, "6h"), (0, "now")
        ]

        for marker in markers {
            let x = rect.minX + rect.width * CGFloat(24 - marker.hours) / 24.0
            let str = marker.label as NSString
            let size = str.size(withAttributes: attrs)

            // Tick mark
            ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.15).cgColor)
            ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: x, y: rect.minY))
            ctx.addLine(to: CGPoint(x: x, y: rect.minY - 3))
            ctx.strokePath()

            // Label
            let labelX = min(max(rect.minX, x - size.width / 2), rect.maxX - size.width)
            str.draw(at: NSPoint(x: labelX, y: rect.minY - 3 - size.height), withAttributes: attrs)
        }
    }

    // MARK: - Battery line

    private func drawLine(ctx: CGContext, rect: NSRect, entries: [BatteryHistory.Entry]) {
        let now = Date()
        let window: TimeInterval = 24 * 3600

        let path = NSBezierPath()
        var started = false

        for entry in entries {
            let age = now.timeIntervalSince(entry.date)
            guard age <= window else { continue }
            let x = rect.minX + rect.width * CGFloat(1.0 - age / window)
            let y = rect.minY + rect.height * CGFloat(entry.percentage) / 100.0

            if !started {
                path.move(to: CGPoint(x: x, y: y))
                started = true
            } else {
                path.line(to: CGPoint(x: x, y: y))
            }
        }

        guard started else { return }

        // Line stroke
        ctx.saveGState()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.stroke()
        ctx.restoreGState()

        // Fill under the line
        if let lastEntry = entries.last {
            let lastAge = now.timeIntervalSince(lastEntry.date)
            let lastX = rect.minX + rect.width * CGFloat(1.0 - lastAge / window)
            let firstAge = now.timeIntervalSince(entries.first(where: { now.timeIntervalSince($0.date) <= window })!.date)
            let firstX = rect.minX + rect.width * CGFloat(1.0 - firstAge / window)

            let fillPath = path.copy() as! NSBezierPath
            fillPath.line(to: CGPoint(x: lastX, y: rect.minY))
            fillPath.line(to: CGPoint(x: firstX, y: rect.minY))
            fillPath.close()

            ctx.saveGState()
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            fillPath.fill()
            ctx.restoreGState()
        }
    }

    // MARK: - Right-side value labels

    private func drawRightLabels(ctx: CGContext, rect: NSRect, entries: [BatteryHistory.Entry]) {
        guard let last = entries.last else { return }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]

        let str = "\(last.percentage)%" as NSString
        let size = str.size(withAttributes: attrs)
        let y = rect.minY + rect.height * CGFloat(last.percentage) / 100.0

        // Clamp Y to stay within graph bounds
        let clampedY = min(max(rect.minY, y - size.height / 2), rect.maxY - size.height)

        str.draw(at: NSPoint(x: rect.maxX + 4, y: clampedY), withAttributes: attrs)

        // Small dot at the current value on the line
        let now = Date()
        let age = now.timeIntervalSince(last.date)
        let dotX = rect.minX + rect.width * CGFloat(1.0 - age / (24 * 3600))
        let dotY = rect.minY + rect.height * CGFloat(last.percentage) / 100.0
        let dotRect = NSRect(x: dotX - 2.5, y: dotY - 2.5, width: 5, height: 5)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
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
