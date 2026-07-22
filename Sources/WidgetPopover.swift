import Cocoa

// MARK: - Palette (matches the HTML design)

extension NSColor {
    /// HTML --accent: #34d399
    static let bbGreen = NSColor(srgbRed: 52/255.0, green: 211/255.0, blue: 153/255.0, alpha: 1)
    /// HTML --amber: #f5b661
    static let bbAmber = NSColor(srgbRed: 245/255.0, green: 182/255.0, blue: 97/255.0, alpha: 1)
    /// HTML text-on-green ink: #052e22
    static let bbGreenInk = NSColor(srgbRed: 5/255.0, green: 46/255.0, blue: 34/255.0, alpha: 1)
}

/// Shared corner radius for badges, dock buttons and cards. Chosen to sit concentric
/// with the popover's rounded window: ~popover corner radius (≈26) minus the 16px padding.
private let kCornerRadius: CGFloat = 10

// MARK: - Data model pushed from StatusBarController on every update

struct WidgetModel: Equatable {
    var percentage = 0
    var statusText = ""
    // False when statusText only restates the power source the icon already shows
    // ("Battery" / "Power Adapter"): the pill collapses to just the source icon.
    var showStatusPill = true
    var etaText: String? = nil
    var isCharging = false
    var limitActive = false
    var limitPercentage = 80
    var lowerBound = 75
    var upperBound = 85
    var topUpActive = false
    var stopChargingBeforeSleep = false
    var lowPowerModeOn = false
    var displayMode: MenuBarDisplayMode = .percentage
    var autoLPMThreshold = 0
    var launchAtLogin = false
    var appTheme = 0   // 0 = system, 1 = light, 2 = dark
    var health = 100
    var cycleCount = 0
    var temperature = 0.0
    var uptime = ""
    var isPluggedIn = false
    var adapterWatts = 0
    var drawWatts = 0          // actual power drawn by the computer
    var powerSource = ""
    var caffeineActive = false
    var dischargeActive = false
}

// MARK: - Actions the widget triggers, handled by StatusBarController

protocol WidgetActionDelegate: AnyObject {
    func widgetToggleLimit()
    func widgetToggleTopUp()
    func widgetToggleDischarge()
    func widgetSetLimit(_ value: Int)
    func widgetSetAmplitude(_ value: Int)
    func widgetSetDisplayMode(_ mode: MenuBarDisplayMode)
    func widgetSetAutoLPM(_ threshold: Int)
    func widgetToggleLowPowerMode()
    func widgetToggleCaffeine()
    func widgetToggleStopChargingBeforeSleep()
    func widgetToggleLaunchAtLogin()
    func widgetSetTheme(_ mode: Int)
    func widgetShowHistory()
    func widgetShowAbout()
    func widgetUninstall()
    func widgetQuit()
}

// MARK: - Flipped container so manual layout uses top-left origin

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

// MARK: - Custom segmented picker (HTML .segc look)

final class SegmentedPicker: NSView {
    private let labels: [String]
    private let pad: CGFloat = 3
    var selectedIndex = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?

    init(labels: [String]) {
        self.labels = labels
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }

    private var segWidth: CGFloat { (bounds.width - 2 * pad) / CGFloat(max(1, labels.count)) }

    private var knobColor: NSColor {
        NSColor(name: nil) { ap in
            ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 0.40, alpha: 1) : .white
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()

        let sw = segWidth
        if selectedIndex >= 0 && selectedIndex < labels.count {
            let kx = pad + CGFloat(selectedIndex) * sw
            let knob = NSRect(x: kx, y: pad, width: sw, height: r.height - 2 * pad)
            knobColor.setFill()
            let path = NSBezierPath(roundedRect: knob, xRadius: 7, yRadius: 7)
            path.fill()
        }

        for (i, label) in labels.enumerated() {
            let selected = (i == selectedIndex)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .medium),
                .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor
            ]
            let size = (label as NSString).size(withAttributes: attrs)
            let cx = pad + CGFloat(i) * sw + (sw - size.width) / 2
            let cyy = (r.height - size.height) / 2
            (label as NSString).draw(at: NSPoint(x: cx, y: cyy), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = max(0, min(labels.count - 1, Int((p.x - pad) / segWidth)))
        selectedIndex = idx
        onSelect?(idx)
    }
}

// MARK: - Custom toggle switch (HTML .sw look)

final class ToggleSwitch: NSView {
    var isOn = false { didSet { needsDisplay = true } }
    var onToggle: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let radius = r.height / 2
        (isOn ? NSColor.bbGreen : NSColor.labelColor.withAlphaComponent(0.22)).setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()

        let d = r.height - 4
        let kx = isOn ? r.width - d - 2 : 2
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: kx, y: 2, width: d, height: d)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        onToggle?(isOn)
    }
}

// MARK: - Chevron handle: rotates in place (sublayer, centred anchor) and slides vertically

final class ChevronView: NSView {
    var onClick: (() -> Void)?
    private let shape = CAShapeLayer()
    private var rotated = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shape.fillColor = NSColor.clear.cgColor
        shape.lineWidth = 1.6
        shape.lineCap = .round
        shape.lineJoin = .round
        layer?.addSublayer(shape)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    @objc private func clicked() { onClick?() }

    override func layout() {
        super.layout()
        // The shape spans the whole view; anchor at its centre so rotation stays in place.
        shape.bounds = bounds
        shape.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
        shape.strokeColor = NSColor.tertiaryLabelColor.cgColor

        let cw: CGFloat = 12, cy = bounds.midY, x0 = (bounds.width - cw) / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x0, y: cy - 3))
        path.addLine(to: CGPoint(x: bounds.midX, y: cy + 3))
        path.addLine(to: CGPoint(x: x0 + cw, y: cy - 3))
        shape.path = path
        shape.transform = CATransform3DMakeRotation(rotated ? .pi : 0, 0, 0, 1)
    }

    /// Rotate the chevron 180° about its own centre (independent of the view's position).
    func setRotated(_ value: Bool, animated: Bool) {
        rotated = value
        let angle: CGFloat = value ? .pi : 0
        if animated {
            let current = (shape.presentation() ?? shape).value(forKeyPath: "transform.rotation.z") as? CGFloat ?? 0
            let anim = CABasicAnimation(keyPath: "transform.rotation.z")
            anim.fromValue = current
            anim.toValue = angle
            anim.duration = 0.32
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shape.add(anim, forKey: "rot")
        }
        shape.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
    }
}

// MARK: - Battery bar (layer-backed fill + amplitude outline that slide on change)

final class BatteryBarView: NSView {
    private let fillView = NSView()
    private let bandView = NSView()
    private let radius: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

        fillView.wantsLayer = true
        fillView.layer?.cornerRadius = radius
        fillView.layer?.backgroundColor = NSColor.bbGreen.cgColor
        addSubview(fillView)

        bandView.wantsLayer = true
        bandView.layer?.cornerRadius = 3
        bandView.layer?.borderWidth = 1.5
        bandView.layer?.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
        addSubview(bandView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }

    private func px(_ pct: Int) -> CGFloat { bounds.width * CGFloat(min(100, max(0, pct))) / 100.0 }

    /// Update the fill and amplitude outline. When `animated`, both slide to their new
    /// position instead of jumping (the outline glides as the limit/bounds change).
    func update(percentage: Int, lower: Int, upper: Int, showBand: Bool, animated: Bool) {
        let h = bounds.height
        let fillFrame = NSRect(x: 0, y: 0, width: px(percentage), height: h)
        let bandFrame = NSRect(x: px(lower), y: 0, width: max(3, px(upper) - px(lower)), height: h)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                fillView.animator().frame = fillFrame
                bandView.animator().frame = bandFrame
                bandView.animator().alphaValue = showBand ? 1 : 0
            }
        } else {
            fillView.frame = fillFrame
            bandView.frame = bandFrame
            bandView.alphaValue = showBand ? 1 : 0
        }
    }
}

// MARK: - Dock button (icon + label, active/enabled states)

final class DockButton: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    var isActiveState = false { didSet { updateAppearance() } }
    var isEnabledState = true {
        didSet { alphaValue = isEnabledState ? 1.0 : 0.35 }
    }

    init(symbol: String, title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = kCornerRadius

        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        img?.isTemplate = true
        iconView.image = img
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        label.stringValue = title
        label.font = .systemFont(ofSize: 9, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byClipping
        addSubview(label)

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let iconSize: CGFloat = 20
        iconView.frame = NSRect(x: (bounds.width - iconSize) / 2, y: 25, width: iconSize, height: iconSize)
        label.frame = NSRect(x: 0, y: 7, width: bounds.width, height: 13)
    }

    private func updateAppearance() {
        // Text/icon keep a constant, legible color in both states — only the
        // background + border communicate the active/inactive state (HTML look).
        iconView.contentTintColor = .labelColor
        label.textColor = .labelColor
        if isActiveState {
            layer?.backgroundColor = NSColor.bbGreen.withAlphaComponent(0.16).cgColor
            layer?.borderColor = NSColor.bbGreen.withAlphaComponent(0.55).cgColor
            layer?.borderWidth = 2
        } else {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
            layer?.borderWidth = 2
        }
    }

    override func updateLayer() {
        super.updateLayer()
        updateAppearance()
    }

    @objc private func clicked() {
        guard isEnabledState else { return }
        onClick?()
    }
}

// MARK: - Organic bridge between the source badge and the status pill

/// Fills the gap between the (left) source badge and the (right) status pill with an
/// "organic" connective tissue: the matter necks in at the middle, its top and bottom
/// edges scooping inward as U-shaped valleys that leave each badge tangentially along its
/// vertical edge. A horizontal gradient (left badge colour → right pill colour) makes the
/// join seamless on both sides, even when the pill turns green while charging.
final class BadgeBridgeView: NSView {
    var leftColor: NSColor = .clear { didSet { needsDisplay = true } }
    var rightColor: NSColor = .clear { didSet { needsDisplay = true } }
    /// Matches the badges' corner radius: the scoops start where each badge's rounding ends.
    var cornerRadius: CGFloat = kCornerRadius
    /// How deep the top and bottom U-valleys bite into the connective band.
    var scoopDepth: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        // The connective band spans the straight (vertical-edge) part of each badge — from
        // where the top rounding ends (topY) to where the bottom rounding begins (botY).
        let r = min(cornerRadius, h / 2)
        let topY = r, botY = h - r
        // Clamp the scoop so the two valleys never cross in the middle.
        let d = min(scoopDepth, max(0, (botY - topY) / 2 - 0.5))

        let path = NSBezierPath()
        // top-left shoulder (end of the source badge's top-right rounding)
        path.move(to: NSPoint(x: 0, y: topY))
        // top U-valley → top-right shoulder. Controls sit straight below the shoulders so the
        // curve leaves each badge vertically (tangent to its edge) before dipping across.
        path.curve(to: NSPoint(x: w, y: topY),
                   controlPoint1: NSPoint(x: 0, y: topY + d),
                   controlPoint2: NSPoint(x: w, y: topY + d))
        // down the pill's left edge
        path.line(to: NSPoint(x: w, y: botY))
        // mirrored bottom U-valley → bottom-left
        path.curve(to: NSPoint(x: 0, y: botY),
                   controlPoint1: NSPoint(x: w, y: botY - d),
                   controlPoint2: NSPoint(x: 0, y: botY - d))
        path.close()

        NSGradient(starting: leftColor, ending: rightColor)?.draw(in: path, angle: 0)
    }
}

// MARK: - The popover content

final class WidgetViewController: NSViewController {
    weak var delegate: WidgetActionDelegate?
    var model = WidgetModel()
    /// Called to resize the hosting popover (preferredContentSize alone doesn't resize a shown popover).
    var onResize: ((NSSize) -> Void)?

    private static let width: CGFloat = 300
    private static let detailsBaseY: CGFloat = 232        // 8px below the fixed cards (end 224)
    /// Duration of the details expand/collapse animation. Shared so the window resize can
    /// wait for a collapse to finish before shrinking (otherwise it crops the cards).
    static let detailAnimationDuration: TimeInterval = 0.32
    private var settingsOpen = false
    private var detailsShown = false
    private var settingsH: CGFloat = 0
    private let detailsH: CGFloat = 50      // height of one card row
    // Fixed cards (usage · charger) are shown on the adapter and collapse on battery.
    private var fixedCardsShown = true

    // Header
    private let percentLabel = NSTextField(labelWithString: "")
    private let pill = NSView()
    private let pillLabel = NSTextField(labelWithString: "")
    private let etaLabel = NSTextField(labelWithString: "")
    // Bar
    private let bar = BatteryBarView()
    // Status source badge (circular icon left of the pill)
    private let sourceBadge = NSView()
    private let sourceIcon = NSImageView()
    // Organic connective tissue drawn in the gap between the source badge and the pill
    private let badgeBridge = BadgeBridgeView(frame: .zero)
    // Fixed info cards
    private let drawValue = NSTextField(labelWithString: "")
    private let chargerValue = NSTextField(labelWithString: "")
    private let uptimeValue = NSTextField(labelWithString: "")
    // Collapsible detail cards
    private let healthValue = NSTextField(labelWithString: "")
    private let cyclesValue = NSTextField(labelWithString: "")
    private let tempValue = NSTextField(labelWithString: "")
    private let chevron = ChevronView(frame: .zero)
    private let fixedContainer = FlippedView()
    private let detailsContainer = FlippedView()
    private let settingsContainer = FlippedView()
    private var dockButtons: [DockButton] = []
    // Dock
    private let limitBtn = DockButton(symbol: "bolt.fill", title: "Limit")
    private let topUpBtn = DockButton(symbol: "arrow.up.to.line", title: "Top-Up")
    private let dischargeBtn = DockButton(symbol: "arrow.down.to.line", title: "Drain")
    private let caffeineBtn = DockButton(symbol: "cup.and.saucer.fill", title: "Awake")
    private let lpmBtn = DockButton(symbol: "leaf.fill", title: "LPM")
    private let settingsGear = NSButton()
    // Settings controls
    private let limitSeg = SegmentedPicker(labels: ["60", "70", "80", "90", "100"])
    private let ampSeg = SegmentedPicker(labels: ["±2", "±5", "±8", "±10"])
    private let displaySeg = SegmentedPicker(labels: ["%", "Time", "Icon"])
    private let themeSeg = SegmentedPicker(labels: ["System", "Light", "Dark"])
    private let lpmSeg = SegmentedPicker(labels: ["Off", "10", "20", "30", "40", "50"])
    private let launchSwitch = ToggleSwitch(frame: .zero)
    private let sleepSwitch = ToggleSwitch(frame: .zero)

    private var statTiles: [NSView] = []
    private var lastAppliedModel: WidgetModel?

    private let limitValues = [60, 70, 80, 90, 100]
    private let ampValues = [2, 5, 8, 10]
    private let displayValues: [MenuBarDisplayMode] = [.percentage, .timeRemaining, .iconOnly]
    private let lpmValues = [0, 10, 20, 30, 40, 50]

    override func loadView() {
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 300))
        v.autoresizesSubviews = false
        v.onAppearanceChange = { [weak self] in self?.restyleForAppearance() }
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildMain()
        buildSettings()
        relayout()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        applyModel(force: true)
    }

    // Layer-backed fills capture their color at set-time, so re-resolve them when the
    // effective appearance (theme) changes — otherwise stale colors linger after a switch.
    private func restyleForAppearance() {
        for tile in statTiles {
            tile.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            tile.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        }
        applyModel(force: true)
    }

    // MARK: Build — main widget

    private let P: CGFloat = 16
    private var innerW: CGFloat { Self.width - 2 * P }
    /// Single grid gap shared by the dock buttons and the info cards so the horizontal
    /// spacing between buttons, between cards, and the vertical gap between the two rows
    /// all stay identical.
    private let gridGap: CGFloat = 8

    /// Build one info card (caption + centered value) into `parent` at the given frame.
    private func makeCard(_ caption: String, _ valueLabel: NSTextField, into parent: NSView, frame: NSRect) {
        let cell = NSView(frame: frame)
        cell.wantsLayer = true
        cell.layer?.cornerRadius = kCornerRadius
        cell.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        cell.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        cell.layer?.borderWidth = 0.5
        statTiles.append(cell)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        valueLabel.alignment = .center
        valueLabel.lineBreakMode = .byClipping
        valueLabel.frame = NSRect(x: 1, y: 24, width: frame.width - 2, height: 20)
        cell.addSubview(valueLabel)

        let keyLabel = NSTextField(labelWithString: caption)
        keyLabel.font = .systemFont(ofSize: 9, weight: .medium)
        keyLabel.textColor = .tertiaryLabelColor
        keyLabel.alignment = .center
        keyLabel.frame = NSRect(x: 0, y: 7, width: frame.width, height: 12)
        cell.addSubview(keyLabel)

        parent.addSubview(cell)
    }

    /// `count` equal cards across the content width, separated by the shared grid gap.
    private func cardFrames(_ count: Int, atY y: CGFloat) -> [NSRect] {
        let gap = gridGap
        let w = (innerW - CGFloat(count - 1) * gap) / CGFloat(count)
        return (0..<count).map { NSRect(x: P + CGFloat($0) * (w + gap), y: y, width: w, height: detailsH) }
    }

    private func buildMain() {
        percentLabel.frame = NSRect(x: P, y: 12, width: 170, height: 50)
        view.addSubview(percentLabel)

        // connective bridge sits behind the badges, in the gap between them
        // (frame + colours set in applyModel; drawn behind both badges added below)
        view.addSubview(badgeBridge)

        // circular power-source badge (icon), sits to the left of the status pill
        // (sized/positioned in applyModel so it matches the pill height)
        sourceBadge.wantsLayer = true
        sourceBadge.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
        sourceIcon.imageScaling = .scaleProportionallyDown
        sourceIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        sourceBadge.addSubview(sourceIcon)
        view.addSubview(sourceBadge)

        pill.wantsLayer = true
        pillLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        pillLabel.alignment = .center
        pill.addSubview(pillLabel)
        view.addSubview(pill)

        bar.frame = NSRect(x: P, y: 60, width: innerW, height: 14)
        view.addSubview(bar)

        // remaining time in the reserved space under the bar (replaces the scale).
        // The dock stays at y=112, so text appears/disappears without moving the buttons.
        etaLabel.font = .systemFont(ofSize: 11)
        etaLabel.textColor = .secondaryLabelColor
        etaLabel.alignment = .left
        etaLabel.lineBreakMode = .byTruncatingTail
        etaLabel.frame = NSRect(x: P, y: 84, width: innerW - 26, height: 14)
        view.addSubview(etaLabel)

        // Small gear on the eta line, flush right — toggles the settings panel.
        settingsGear.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "Settings")
        settingsGear.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        settingsGear.isBordered = false
        settingsGear.focusRingType = .none
        settingsGear.refusesFirstResponder = true
        settingsGear.contentTintColor = .secondaryLabelColor
        settingsGear.target = self
        settingsGear.action = #selector(settingsGearTapped)
        settingsGear.toolTip = "Open settings"
        settingsGear.frame = NSRect(x: Self.width - P - 18, y: 82, width: 18, height: 18)
        view.addSubview(settingsGear)

        // Dock (static, directly under the bar — buttons sit above the info cards).
        // Span the full content width so the row's left/right edges line up with the
        // info cards below (equal buttons separated by equal gaps).
        dockButtons = [limitBtn, topUpBtn, dischargeBtn, caffeineBtn, lpmBtn]
        let btnW = (innerW - CGFloat(dockButtons.count - 1) * gridGap) / CGFloat(dockButtons.count)
        let step = btnW + gridGap
        for (i, btn) in dockButtons.enumerated() {
            btn.frame = NSRect(x: P + CGFloat(i) * step, y: 112, width: btnW, height: 54)
            view.addSubview(btn)
        }
        limitBtn.onClick = { [weak self] in self?.delegate?.widgetToggleLimit() }
        topUpBtn.onClick = { [weak self] in self?.delegate?.widgetToggleTopUp() }
        dischargeBtn.onClick = { [weak self] in self?.delegate?.widgetToggleDischarge() }
        caffeineBtn.onClick = { [weak self] in self?.delegate?.widgetToggleCaffeine() }
        lpmBtn.onClick = { [weak self] in self?.delegate?.widgetToggleLowPowerMode() }
        limitBtn.toolTip = "Hold the charge at the configured limit to preserve battery health"
        topUpBtn.toolTip = "Temporarily charge to 100%, then return to the limit"
        dischargeBtn.toolTip = "Actively discharge the battery down to the charge limit while plugged in"
        caffeineBtn.toolTip = "Keep the Mac awake (prevent sleep)"
        lpmBtn.toolTip = "Toggle macOS Low Power Mode"

        // Charging info cards (usage · charger) in a clipping container: shown on the
        // adapter, collapsed (with animation) on battery. Positioned by relayout().
        fixedContainer.wantsLayer = true
        fixedContainer.layer?.masksToBounds = true
        fixedContainer.frame = NSRect(x: 0, y: 174, width: Self.width, height: detailsH)
        let fx = cardFrames(2, atY: 0)
        makeCard("USAGE", drawValue, into: fixedContainer, frame: fx[0])
        makeCard("CHARGER", chargerValue, into: fixedContainer, frame: fx[1])
        view.addSubview(fixedContainer)

        // Collapsible detail cards (health · cycles · temp · uptime) — "already there" inside
        // a clipping container whose height grows from 0 to reveal them (no fade).
        detailsContainer.wantsLayer = true
        detailsContainer.layer?.masksToBounds = true
        detailsContainer.frame = NSRect(x: 0, y: Self.detailsBaseY, width: Self.width, height: 0)
        let dx = cardFrames(3, atY: 0)
        makeCard("HEALTH", healthValue, into: detailsContainer, frame: dx[0])
        makeCard("CYCLES", cyclesValue, into: detailsContainer, frame: dx[1])
        makeCard("UPTIME", uptimeValue, into: detailsContainer, frame: dx[2])
        uptimeValue.font = .systemFont(ofSize: 14, weight: .semibold)
        view.addSubview(detailsContainer)

        // Chevron handle — sits just below the clipping container and slides down (rotating
        // 180° around its own centre) as the container grows to reveal the cards.
        chevron.frame = NSRect(x: 0, y: 230, width: Self.width, height: 22)
        chevron.onClick = { [weak self] in self?.toggleDetails() }
        view.addSubview(chevron)

        view.addSubview(settingsContainer)
    }

    @objc private func toggleDetails() {
        detailsShown.toggle()
        relayout(animated: true)
    }

    /// Lay out immediately (no animation) and report the current size via onResize.
    func layoutNow() {
        guard isViewLoaded else { return }
        relayout(animated: false)
    }

    // MARK: Layout — positions the collapsible blocks and resizes the popover

    private func relayout(animated: Bool = false) {
        // Two independent clipping containers stack below the dock, each growing 0 → detailsH:
        //   • fixedContainer (usage · charger) — collapses on battery, expands on the adapter;
        //   • detailsContainer (health · cycles · temp · uptime) — toggled by the chevron.
        // The chevron sits just below whatever is currently the lowest visible card row and
        // slides vertically (rotating 180°) as the detail cards are revealed. Everything below
        // a collapsed container shifts up, so the two collapses compose cleanly.
        let dockBottom: CGFloat = 166

        // Fixed cards.
        let fixedTop = dockBottom + gridGap
        let fixedH = fixedCardsShown ? detailsH : 0
        let fixedFrame = NSRect(x: 0, y: fixedTop, width: Self.width, height: fixedH)
        let afterFixed = fixedTop + fixedH

        // Detail cards (revealed by the chevron), anchored below the fixed-cards row.
        let detailsBaseY = afterFixed + gridGap
        let containerH = detailsShown ? detailsH : 0
        let containerFrame = NSRect(x: 0, y: detailsBaseY, width: Self.width, height: containerH)

        // Chevron: 6px below the lowest visible row (the detail cards when expanded,
        // otherwise the fixed-cards row — or the dock when both are collapsed).
        let chevronY = detailsShown ? (detailsBaseY + detailsH + 6) : (afterFixed + 6)
        let chevronFrame = NSRect(x: 0, y: chevronY, width: Self.width, height: 22)
        let afterChevron = chevronY + 22 + 6
        let settingsFrame = NSRect(x: 0, y: afterChevron, width: Self.width, height: settingsH)
        // Keep the chevron close to the window's bottom edge when settings are closed.
        let totalH = settingsOpen ? (afterChevron + settingsH) : (chevronY + 22 + 4)

        settingsContainer.frame = settingsFrame

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.detailAnimationDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                fixedContainer.animator().frame = fixedFrame
                detailsContainer.animator().frame = containerFrame
                chevron.animator().frame = chevronFrame   // vertical translation only
                settingsContainer.animator().alphaValue = settingsOpen ? 1 : 0
            }
            chevron.setRotated(detailsShown, animated: true)   // in-place rotation (sublayer)
        } else {
            fixedContainer.frame = fixedFrame
            detailsContainer.frame = containerFrame
            chevron.frame = chevronFrame
            chevron.setRotated(detailsShown, animated: false)
            settingsContainer.alphaValue = settingsOpen ? 1 : 0
        }

        let size = NSSize(width: Self.width, height: totalH)
        if let onResize = onResize {
            onResize(size)
        } else {
            preferredContentSize = size
        }
    }

    // MARK: Build — settings panel (revealed below the dock)

    private func buildSettings() {
        let c = settingsContainer
        var cy: CGFloat = 12

        let divider = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 0.5))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        c.addSubview(divider)

        // Two-line row: uppercase caption on top, full-width control below (no overlap).
        func addSegRow(_ title: String, _ seg: SegmentedPicker, _ onSelect: @escaping (Int) -> Void) {
            let caption = NSTextField(labelWithString: title.uppercased())
            caption.font = .systemFont(ofSize: 10, weight: .semibold)
            caption.textColor = .tertiaryLabelColor
            caption.frame = NSRect(x: P, y: cy, width: innerW, height: 13)
            c.addSubview(caption)
            cy += 18

            seg.onSelect = onSelect
            seg.frame = NSRect(x: P, y: cy, width: innerW, height: 30)
            c.addSubview(seg)
            cy += 30 + 16
        }

        addSegRow("Charge limit", limitSeg) { [weak self] i in
            guard let s = self else { return }; s.delegate?.widgetSetLimit(s.limitValues[i])
        }
        addSegRow("Amplitude (hysteresis)", ampSeg) { [weak self] i in
            guard let s = self else { return }; s.delegate?.widgetSetAmplitude(s.ampValues[i])
        }
        addSegRow("Menu bar display", displaySeg) { [weak self] i in
            guard let s = self else { return }; s.delegate?.widgetSetDisplayMode(s.displayValues[i])
        }
        addSegRow("Theme", themeSeg) { [weak self] i in
            self?.delegate?.widgetSetTheme(i)
        }
        addSegRow("Auto Low Power Mode", lpmSeg) { [weak self] i in
            guard let s = self else { return }; s.delegate?.widgetSetAutoLPM(s.lpmValues[i])
        }

        // Switch rows (narrow control → stays inline)
        func addSwitchRow(_ title: String, _ sw: ToggleSwitch, _ onToggle: @escaping (Bool) -> Void) {
            let l = NSTextField(labelWithString: title)
            l.font = .systemFont(ofSize: 13)
            l.textColor = .labelColor
            l.frame = NSRect(x: P, y: cy + 2, width: 200, height: 18)
            c.addSubview(l)
            sw.onToggle = onToggle
            sw.frame = NSRect(x: Self.width - P - 40, y: cy, width: 40, height: 22)
            c.addSubview(sw)
            cy += 22 + 14
        }

        addSwitchRow("Stop charging on sleep", sleepSwitch) { [weak self] _ in
            self?.delegate?.widgetToggleStopChargingBeforeSleep()
        }
        addSwitchRow("Launch at login", launchSwitch) { [weak self] _ in
            self?.delegate?.widgetToggleLaunchAtLogin()
        }
        cy += 6

        // footer buttons — flat rounded, sharing the full width equally
        let footer: [(String, Selector)] = [
            ("History", #selector(historyTapped)),
            ("About", #selector(aboutTapped)),
            ("Uninstall", #selector(uninstallTapped)),
            ("Quit", #selector(quitTapped))
        ]
        let gap: CGFloat = 8
        let bw = (innerW - CGFloat(footer.count - 1) * gap) / CGFloat(footer.count)
        let bh: CGFloat = 34
        for (i, (title, sel)) in footer.enumerated() {
            let b = NSButton(title: "", target: self, action: sel)
            b.isBordered = false
            b.focusRingType = .none
            b.refusesFirstResponder = true
            b.wantsLayer = true
            b.layer?.cornerRadius = kCornerRadius
            b.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            b.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
            b.layer?.borderWidth = 2
            let para = NSMutableParagraphStyle(); para.alignment = .center
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 12.5),
                .paragraphStyle: para
            ])
            b.frame = NSRect(x: P + CGFloat(i) * (bw + gap), y: cy, width: bw, height: bh)
            statTiles.append(b)   // so its layer colors re-resolve on theme change
            c.addSubview(b)
        }
        cy += bh + 16
        settingsH = cy
    }

    // MARK: Settings toggle (grow / shrink popover)

    @objc private func settingsGearTapped() { toggleSettings() }

    private func toggleSettings() {
        settingsOpen.toggle()
        settingsGear.contentTintColor = settingsOpen ? .labelColor : .secondaryLabelColor
        relayout(animated: true)
    }

    /// Called by StatusBarController when the popover closes.
    func resetSettings() {
        settingsOpen = false
        settingsGear.contentTintColor = .secondaryLabelColor
        relayout()
    }

    // MARK: Apply model → UI

    func applyModel(force: Bool = false) {
        guard isViewLoaded else { return }
        let m = model
        if !force, let last = lastAppliedModel, last == m { return }
        lastAppliedModel = m

        let number = NSMutableAttributedString(
            string: "\(m.percentage)",
            attributes: [.font: NSFont.systemFont(ofSize: 42, weight: .bold), .foregroundColor: NSColor.labelColor]
        )
        number.append(NSAttributedString(
            string: "%",
            attributes: [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        ))
        percentLabel.attributedStringValue = number

        // status pill (no emoji) — matched to the percentage's height, fully rounded
        let pillH: CGFloat = 40
        let pillTop: CGFloat = 14
        let badgeSide = pillH
        pillLabel.stringValue = m.statusText
        pillLabel.sizeToFit()
        let pillW = pillLabel.frame.width + 34
        let pillRight = Self.width - 16
        let pillX = pillRight - pillW
        pill.frame = NSRect(x: pillX, y: pillTop, width: pillW, height: pillH)
        pill.layer?.cornerRadius = kCornerRadius
        pillLabel.frame = NSRect(x: 0, y: (pillH - 17) / 2, width: pillW, height: 17)
        if m.isCharging || m.topUpActive {
            pill.layer?.backgroundColor = NSColor.bbGreen.cgColor
            pillLabel.textColor = .bbGreenInk
        } else {
            pill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
            pillLabel.textColor = .labelColor
        }

        // circular power-source badge (same height as the pill)
        sourceBadge.layer?.cornerRadius = kCornerRadius
        let iconSide: CGFloat = 18
        sourceIcon.frame = NSRect(x: (badgeSide - iconSide) / 2, y: (badgeSide - iconSide) / 2,
                                  width: iconSide, height: iconSide)
        let symbol = m.isPluggedIn ? "powerplug.fill" : "battery.100"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: m.powerSource)
        img?.isTemplate = true
        sourceIcon.image = img
        sourceIcon.contentTintColor = .secondaryLabelColor

        // When the pill only restates the source (Battery / Power Adapter) it collapses to
        // just the icon: fade the pill out and slide the badge into the top-right corner.
        // Reverses (fade in + slide back left of the pill) when a real status returns.
        let showPill = m.showStatusPill
        let badgeX = showPill ? (pillX - badgeSide - 8) : (pillRight - badgeSide)
        let badgeFrame = NSRect(x: badgeX, y: pillTop, width: badgeSide, height: badgeSide)
        let pillAlpha: CGFloat = showPill ? 1 : 0

        // Organic bridge: fill the gap between the source badge (left) and the pill (right).
        // Its gradient ends match each side's real background so the join is seamless — even
        // when the pill is green while charging. Hidden when the pill collapses to the corner.
        let bridgeX = badgeX + badgeSide
        let bridgeW = max(0, pillX - bridgeX)
        badgeBridge.leftColor = NSColor.labelColor.withAlphaComponent(0.09)
        badgeBridge.rightColor = (m.isCharging || m.topUpActive)
            ? .bbGreen : NSColor.labelColor.withAlphaComponent(0.10)
        let bridgeFrame = NSRect(x: bridgeX, y: pillTop, width: bridgeW, height: badgeSide)
        let bridgeAlpha: CGFloat = showPill ? 1 : 0

        if force {
            sourceBadge.frame = badgeFrame
            pill.alphaValue = pillAlpha
            badgeBridge.frame = bridgeFrame
            badgeBridge.alphaValue = bridgeAlpha
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                sourceBadge.animator().frame = badgeFrame
                pill.animator().alphaValue = pillAlpha
                badgeBridge.animator().frame = bridgeFrame
                badgeBridge.animator().alphaValue = bridgeAlpha
            }
        }

        etaLabel.stringValue = m.etaText ?? ""

        bar.update(percentage: m.percentage, lower: m.lowerBound, upper: m.upperBound,
                   showBand: m.limitActive, animated: !force)

        // charging cards: power drawn by the computer · charger power (uptime moved to details)
        drawValue.stringValue = m.drawWatts > 0 ? "\(m.drawWatts) W" : "—"
        chargerValue.stringValue = m.adapterWatts > 0 ? "\(m.adapterWatts) W" : "—"
        uptimeValue.stringValue = m.uptime

        // The two charging cards collapse on battery, expand on the adapter. Animate the
        // change (and let the window follow) on live updates; snap on the initial open.
        let showFixed = m.isPluggedIn
        if showFixed != fixedCardsShown {
            fixedCardsShown = showFixed
            if !force { relayout(animated: true) }
        }

        // collapsible detail cards (same font size as the fixed cards)
        healthValue.stringValue = "\(m.health)%"
        cyclesValue.stringValue = "\(m.cycleCount)"
        tempValue.stringValue = "\(Int(m.temperature.rounded()))°"

        // dock states
        limitBtn.isActiveState = m.limitActive
        topUpBtn.isActiveState = m.topUpActive
        topUpBtn.isEnabledState = m.limitActive
        dischargeBtn.isActiveState = m.dischargeActive
        // Draining works with or without the limiter — it just needs the adapter and
        // a percentage above the configured limit (the drain target).
        dischargeBtn.isEnabledState = m.dischargeActive
            || (m.isPluggedIn && m.percentage > m.limitPercentage)
        // Tooltip explains why the button is greyed out when it is.
        if m.dischargeActive {
            dischargeBtn.toolTip = "Stop draining and reconnect the adapter"
        } else if !m.isPluggedIn {
            dischargeBtn.toolTip = "Plug in the charger to drain — on battery it already discharges naturally"
        } else if m.percentage <= m.limitPercentage {
            dischargeBtn.toolTip = "Battery already at or below the \(m.limitPercentage)% limit — nothing to drain"
        } else {
            dischargeBtn.toolTip = "Actively discharge the battery down to \(m.limitPercentage)% while plugged in"
        }
        caffeineBtn.isActiveState = m.caffeineActive
        lpmBtn.isActiveState = m.lowPowerModeOn

        // settings controls
        limitSeg.selectedIndex = limitValues.firstIndex(of: m.limitPercentage) ?? -1
        ampSeg.selectedIndex = ampValues.firstIndex(of: max(2, min(10, m.upperBound - m.limitPercentage))) ?? -1
        displaySeg.selectedIndex = displayValues.firstIndex(of: m.displayMode) ?? 0
        themeSeg.selectedIndex = max(0, min(2, m.appTheme))
        lpmSeg.selectedIndex = lpmValues.firstIndex(of: m.autoLPMThreshold) ?? 0
        launchSwitch.isOn = m.launchAtLogin
        sleepSwitch.isOn = m.stopChargingBeforeSleep
    }

    // MARK: Control actions

    @objc private func historyTapped() { delegate?.widgetShowHistory() }
    @objc private func aboutTapped() { delegate?.widgetShowAbout() }
    @objc private func uninstallTapped() { delegate?.widgetUninstall() }
    @objc private func quitTapped() { delegate?.widgetQuit() }
}
