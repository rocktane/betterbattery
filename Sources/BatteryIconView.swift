import Cocoa

class BatteryIconView: NSView {
    var percentage: Int = 100
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var chargeLimitActive: Bool = false
    var topUpActive: Bool = false
    var isLowPowerModeEnabled: Bool = false

    private let batteryWidth: CGFloat = 22.0
    private let batteryHeight: CGFloat = 12.0
    private let terminalWidth: CGFloat = 3.0
    private let terminalHeight: CGFloat = 4.0
    private let cornerRadius: CGFloat = 2.0
    private let borderWidth: CGFloat = 1.0

    private let leafWidth: CGFloat = 7.0
    private let leafGap: CGFloat = 2.0

    override var intrinsicContentSize: NSSize {
        // Height accommodates bolt tips extending beyond battery body
        let extraWidth = isLowPowerModeEnabled ? leafGap + leafWidth : 0
        return NSSize(width: batteryWidth + terminalWidth + 1 + extraWidth, height: 20)
    }

    func update(percentage: Int, isCharging: Bool, isPluggedIn: Bool, chargeLimitActive: Bool, topUpActive: Bool, isLowPowerModeEnabled: Bool) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.chargeLimitActive = chargeLimitActive
        self.topUpActive = topUpActive
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawBattery(in: context, bounds: bounds)
    }

    func toImage() -> NSImage {
        let size = intrinsicContentSize
        let image = NSImage(size: size, flipped: false) { [weak self] rect in
            guard let self = self,
                  let context = NSGraphicsContext.current?.cgContext else { return false }
            self.drawBattery(in: context, bounds: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Drawing

    private func drawBattery(in ctx: CGContext, bounds: NSRect) {
        let borderColor = NSColor.textColor.withAlphaComponent(0.5)
        let yOffset = (bounds.height - batteryHeight) / 2.0

        // 1. Battery body outline
        let bodyRect = NSRect(
            x: borderWidth / 2,
            y: yOffset + borderWidth / 2,
            width: batteryWidth - borderWidth,
            height: batteryHeight - borderWidth
        )
        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: cornerRadius, yRadius: cornerRadius)
        borderColor.set()
        bodyPath.lineWidth = borderWidth
        bodyPath.stroke()

        // 2. Terminal nub with destinationOut separator
        let nubX = batteryWidth
        let nubY = yOffset + (batteryHeight - terminalHeight) / 2.0
        let nubRect = NSRect(x: nubX - 1, y: nubY, width: terminalWidth, height: terminalHeight)
        let nubPath = NSBezierPath(roundedRect: nubRect, xRadius: 2, yRadius: 2)
        borderColor.set()
        nubPath.fill()

        let separator = NSBezierPath()
        separator.move(to: CGPoint(x: nubX, y: yOffset))
        separator.line(to: CGPoint(x: nubX, y: yOffset + batteryHeight))
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        NSColor.white.set()
        separator.lineWidth = borderWidth
        separator.stroke()
        ctx.restoreGState()

        // 3. Charge fill level
        let fillInset: CGFloat = borderWidth + 1
        let maxFillWidth = batteryWidth - fillInset * 2
        let fillWidth = max(0, maxFillWidth * CGFloat(max(0, min(100, percentage))) / 100.0)

        if fillWidth > 0 {
            let fillRect = NSRect(
                x: fillInset,
                y: yOffset + fillInset,
                width: fillWidth,
                height: batteryHeight - fillInset * 2
            )
            let innerRadius = max(0, cornerRadius - 1)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: innerRadius, yRadius: innerRadius)

            let fillColor: NSColor
            if percentage <= 15 {
                fillColor = .systemRed
            } else if percentage <= 25 {
                fillColor = .systemOrange
            } else {
                fillColor = .textColor
            }
            fillColor.set()
            fillPath.fill()
        }

        // 4. Overlay icons
        if isPluggedIn {
            let centerX = batteryWidth / 2.0
            let centerY = yOffset + batteryHeight / 2.0

            if topUpActive {
                drawPlus(ctx: ctx, centerX: centerX, centerY: centerY)
            } else if chargeLimitActive {
                drawPause(ctx: ctx, centerX: centerX, centerY: centerY)
            } else if isCharging {
                drawBolt(ctx: ctx, centerX: centerX, centerY: centerY)
            } else {
                drawPlug(ctx: ctx, centerX: centerX, centerY: centerY)
            }
        }

        // 5. Low Power Mode leaf indicator
        if isLowPowerModeEnabled {
            let leafX = batteryWidth + terminalWidth + leafGap
            let leafCenterY = yOffset + batteryHeight / 2.0
            drawLowPowerDot(ctx: ctx, x: leafX, centerY: leafCenterY)
        }
    }

    // MARK: - Stats-style overlay icons

    private func drawBolt(ctx: CGContext, centerX: CGFloat, centerY: CGFloat) {
        // Exact Stats lightning bolt: 6-point polygon, extends beyond battery body
        let iconHeight = batteryHeight + 6
        let minY = centerY - iconHeight / 2
        let maxY = centerY + iconHeight / 2
        let minX = centerX - 4.5
        let maxX = centerX + 4.5

        let bolt = NSBezierPath()
        bolt.move(to: CGPoint(x: centerX - 3, y: minY))
        bolt.line(to: CGPoint(x: maxX,        y: centerY + 1.5))
        bolt.line(to: CGPoint(x: centerX + 1, y: centerY + 1.5))
        bolt.line(to: CGPoint(x: centerX + 3, y: maxY))
        bolt.line(to: CGPoint(x: minX,        y: centerY - 1.5))
        bolt.line(to: CGPoint(x: centerX - 1, y: centerY - 1.5))
        bolt.close()

        NSColor.textColor.set()
        bolt.fill()

        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        NSColor.textColor.set()
        bolt.lineWidth = 1
        bolt.stroke()
        ctx.restoreGState()
    }

    private func drawPlug(ctx: CGContext, centerX: CGFloat, centerY: CGFloat) {
        // Exact Stats power plug: 17-point polygon
        let iconHeight = batteryHeight + 2
        let minY = centerY - iconHeight / 2
        let maxY = centerY + iconHeight / 2

        let plug = NSBezierPath()
        plug.move(to: CGPoint(x: centerX - 1.5,  y: minY + 0.5))
        plug.line(to: CGPoint(x: centerX + 1.5,  y: minY + 0.5))
        plug.line(to: CGPoint(x: centerX + 1.5,  y: centerY - 2.5))
        plug.line(to: CGPoint(x: centerX + 4,    y: centerY + 0.5))
        plug.line(to: CGPoint(x: centerX + 4,    y: centerY + 4.25))
        // Right prong
        plug.line(to: CGPoint(x: centerX + 2.75, y: centerY + 4.25))
        plug.line(to: CGPoint(x: centerX + 2.75, y: maxY - 0.25))
        plug.line(to: CGPoint(x: centerX + 0.25, y: maxY - 0.25))
        plug.line(to: CGPoint(x: centerX + 0.25, y: centerY + 4.25))
        // Left prong
        plug.line(to: CGPoint(x: centerX - 0.25, y: centerY + 4.25))
        plug.line(to: CGPoint(x: centerX - 0.25, y: maxY - 0.25))
        plug.line(to: CGPoint(x: centerX - 2.75, y: maxY - 0.25))
        plug.line(to: CGPoint(x: centerX - 2.75, y: centerY + 4.25))
        plug.line(to: CGPoint(x: centerX - 4,    y: centerY + 4.25))
        plug.line(to: CGPoint(x: centerX - 4,    y: centerY + 0.5))
        plug.line(to: CGPoint(x: centerX - 1.5,  y: centerY - 2.5))
        plug.close()

        NSColor.textColor.set()
        plug.fill()

        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        NSColor.textColor.set()
        plug.lineWidth = 1
        plug.stroke()
        ctx.restoreGState()
    }

    private func drawPlus(ctx: CGContext, centerX: CGFloat, centerY: CGFloat) {
        let armLength: CGFloat = 2.5
        let lineWidth: CGFloat = 1.5

        let plus = NSBezierPath()
        // Horizontal bar
        plus.move(to: CGPoint(x: centerX - armLength, y: centerY))
        plus.line(to: CGPoint(x: centerX + armLength, y: centerY))
        // Vertical bar
        plus.move(to: CGPoint(x: centerX, y: centerY - armLength))
        plus.line(to: CGPoint(x: centerX, y: centerY + armLength))

        NSColor.white.set()
        plus.lineWidth = lineWidth
        plus.lineCapStyle = .round
        plus.stroke()
    }

    private func drawPause(ctx: CGContext, centerX: CGFloat, centerY: CGFloat) {
        let tildeWidth: CGFloat = 8.0
        let amplitude: CGFloat = 2.0
        let lineWidth: CGFloat = 1.5

        let tilde = NSBezierPath()
        let startX = centerX - tildeWidth / 2
        let endX = centerX + tildeWidth / 2

        tilde.move(to: CGPoint(x: startX, y: centerY))
        tilde.curve(
            to: CGPoint(x: centerX, y: centerY),
            controlPoint1: CGPoint(x: startX + tildeWidth * 0.15, y: centerY + amplitude),
            controlPoint2: CGPoint(x: centerX - tildeWidth * 0.15, y: centerY + amplitude)
        )
        tilde.curve(
            to: CGPoint(x: endX, y: centerY),
            controlPoint1: CGPoint(x: centerX + tildeWidth * 0.15, y: centerY - amplitude),
            controlPoint2: CGPoint(x: endX - tildeWidth * 0.15, y: centerY - amplitude)
        )

        NSColor.white.set()
        tilde.lineWidth = lineWidth
        tilde.lineCapStyle = .round
        tilde.stroke()
    }

    // MARK: - Low Power Mode indicator

    private func drawLowPowerDot(ctx: CGContext, x: CGFloat, centerY: CGFloat) {
        let dotSize: CGFloat = 5.0
        let dotRect = NSRect(
            x: x + (leafWidth - dotSize) / 2.0,
            y: centerY - dotSize / 2.0,
            width: dotSize,
            height: dotSize
        )
        let dot = NSBezierPath(ovalIn: dotRect)
        NSColor.systemOrange.set()
        dot.fill()
    }
}
