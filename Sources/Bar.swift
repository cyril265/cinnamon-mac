import AppKit

/// An app icon right of the window buttons: a Dock pin, or a running app the bar has no window button for.
struct PinnedApp {
    let url: URL
    /// Bundle id if it has one, else the path: what matches a pinned app to a running one.
    let key: String
    let name: String
    let icon: NSImage
    /// Shows the Dock's running dot.
    var running = false
    /// The app's Dock badge.
    var badge: String?
}

struct BarItem {
    let id: WindowID
    let title: String
    let icon: NSImage
    let focused: Bool
    let dimmed: Bool
    let badge: String?
}

protocol BarDelegate: AnyObject {
    func bar(_ bar: Bar, clicked id: WindowID)
    func bar(_ bar: Bar, open pin: PinnedApp)
    func bar(_ bar: Bar, moved id: WindowID, to index: Int, among ids: [WindowID])
    func barDragDidEnd(_ bar: Bar)
    func bar(_ bar: Bar, menuFor id: WindowID) -> NSMenu
    func bar(_ bar: Bar, menuFor pin: PinnedApp) -> NSMenu
    func bar(_ bar: Bar, overflowMenuFor items: [BarItem]) -> NSMenu
    func barMenu(_ bar: Bar) -> NSMenu
}

final class BarButton: NSView {
    enum Kind { case pin, window, overflow }

    let kind: Kind
    weak var bar: Bar?
    var windowID: WindowID?
    var pin: PinnedApp?
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let runningDot = NSView()
    private lazy var badgeView = BadgeView(compact: kind == .pin)
    /// The visible background. The button itself spans the bar's full height, so it is clickable down to the screen edge.
    private let plate = NSView()
    private var highlighted = false
    private var hovering = false {
        didSet { if hovering != oldValue { updateBackground() } }
    }

    init(kind: Kind, bar: Bar) {
        self.kind = kind
        self.bar = bar
        super.init(frame: .zero)
        plate.wantsLayer = true
        plate.layer?.cornerRadius = 6
        addSubview(plate)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.alignment = kind == .overflow ? .center : .left
        if kind != .overflow { addSubview(iconView) }
        if kind != .pin { addSubview(label) }
        if kind != .overflow { addSubview(badgeView) }
        if kind == .pin {
            runningDot.wantsLayer = true
            runningDot.layer?.cornerRadius = 1.5
            runningDot.isHidden = true
            addSubview(runningDot)
        }
        updateBackground()
    }

    var running = false {
        didSet {
            guard running != oldValue else { return }
            runningDot.isHidden = !running
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(icon: NSImage?, title: String?, toolTip: String?, highlighted: Bool = false, dimmed: Bool = false, badge: String? = nil) {
        if badgeView.text != badge {
            badgeView.text = badge
            needsLayout = true
        }
        if iconView.image !== icon { iconView.image = icon }
        let alpha: CGFloat = dimmed ? 0.45 : 1
        if iconView.alphaValue != alpha { iconView.alphaValue = alpha }
        if label.stringValue != title ?? "" { label.stringValue = title ?? "" }
        let color: NSColor = dimmed ? .secondaryLabelColor : .labelColor
        if label.textColor != color { label.textColor = color }
        if self.toolTip != toolTip { self.toolTip = toolTip }
        if self.highlighted != highlighted {
            self.highlighted = highlighted
            updateBackground()
        }
    }

    override func layout() {
        super.layout()
        plate.frame = bounds.insetBy(dx: 0, dy: Bar.inset)
        let height = plate.frame.height, mid = bounds.midY
        switch kind {
        case .pin:
            let size = bounds.height
            iconView.frame = NSRect(x: (bounds.width - size) / 2, y: mid - size / 2, width: size, height: size)
            runningDot.frame = NSRect(x: (bounds.width - 3) / 2, y: 1, width: 3, height: 3)
        case .window:
            let size = min(height - 2, 40)
            iconView.frame = NSRect(x: 2, y: mid - size / 2, width: size, height: size)
            label.frame = NSRect(x: iconView.frame.maxX + 6, y: mid - 8, width: max(bounds.width - iconView.frame.maxX - 12, 0), height: 16)
        case .overflow:
            label.frame = NSRect(x: 0, y: mid - 8, width: bounds.width, height: 16)
        }
        if kind == .pin, !badgeView.isHidden {
            // Inside the visible icon's top-right corner, so it never covers a neighbour
            let size = badgeView.fittingSize
            let visible = iconView.frame.insetBy(dx: iconView.frame.width * 0.1, dy: iconView.frame.height * 0.1)
            badgeView.frame = NSRect(x: bounds.width - size.width, y: min(visible.maxY - size.height + 3, bounds.height - size.height),
                                     width: size.width, height: size.height).integral
        } else if kind == .window, !badgeView.isHidden {
            let size = badgeView.fittingSize
            let icon = iconView.frame
            badgeView.frame = NSRect(x: min(icon.maxX - size.width * 0.6, bounds.width - size.width), y: min(icon.maxY - size.height * 0.8, plate.frame.maxY - size.height),
                                     width: size.width, height: size.height).integral
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { bar?.mouseDown(self, event) }
    override func mouseDragged(with event: NSEvent) { bar?.mouseDragged(self, event) }
    override func mouseUp(with event: NSEvent) { bar?.mouseUp(self, event) }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = bar?.contextMenu(for: self) else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
        super.updateTrackingAreas()
    }

    override func viewDidChangeEffectiveAppearance() { updateBackground() }
    override func viewDidMoveToWindow() { updateBackground() }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let focused = dark ? NSColor.controlAccentColor.withAlphaComponent(0.35)
                : NSColor.controlAccentColor.blended(withFraction: 0.8, of: .white)?.withAlphaComponent(0.85) ?? .controlAccentColor.withAlphaComponent(0.15)
            let color: NSColor = highlighted ? focused
                : hovering ? .labelColor.withAlphaComponent(0.12) : .clear
            plate.layer?.backgroundColor = color.cgColor
            runningDot.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.7).cgColor
        }
    }
}

/// The red Dock badge on an app icon: a count, or a dot when the app sets one.
/// Compact badges, on pinned apps, are smaller and cap counts at 9+ to stay within their icon.
final class BadgeView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let compact: Bool

    var text: String? {
        didSet {
            // Like Windows, big counts show as 99+; other long text is cut to fit the icon
            let cap = compact ? 9 : 99
            label.stringValue = text.flatMap { Int($0) }.map { $0 > cap ? "\(cap)+" : "\($0)" } ?? text ?? ""
            isHidden = text == nil
        }
    }

    init(compact: Bool) {
        self.compact = compact
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemRed.cgColor
        label.font = .systemFont(ofSize: compact ? 8.5 : 10, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let height: CGFloat = compact ? 13 : 16
        return NSSize(width: min(max(height, ceil(label.intrinsicContentSize.width) + (compact ? 6 : 8)), compact ? 20 : 30), height: height)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class BarBackground: NSVisualEffectView {
    var contextMenu: (() -> NSMenu?)?

    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}

final class BarPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // One level above the Dock, so the bar hides it while macOS keeps reserving its space.
        // Don't set isFloatingPanel: it resets the level to .floating.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        hidesOnDeactivate = false
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The taskbar on one display. Buttons are kept per window and updated in place, so hover and drag survive updates.
final class Bar {
    /// Space between the bar's edges and the buttons' visible background.
    static let inset: CGFloat = 4

    /// Pin icons are as tall as the bar. macOS app icons leave a transparent margin of about a tenth on each side,
    /// so pins are 80% as wide as their icons plus a small gap, and the running dot sits in the bottom margin.
    static func pinWidth(barHeight: CGFloat) -> CGFloat { (barHeight * 0.8).rounded() + 4 }
    weak var delegate: BarDelegate?
    private let panel = BarPanel()
    private let background = BarBackground()
    private let separator = NSBox()
    private var pinButtons: [String: BarButton] = [:]
    private var windowButtons: [WindowID: BarButton] = [:]
    private lazy var overflowButton = BarButton(kind: .overflow, bar: self)
    private lazy var warningButton = BarButton(kind: .window, bar: self)
    private var shownIDs: [WindowID] = []
    private var overflowItems: [BarItem] = []
    private var slots: [CGFloat] = []
    private var buttonWidth: CGFloat = 0
    private var content: (pins: [PinnedApp], items: [BarItem], trusted: Bool) = ([], [], true)

    private struct Drag {
        let id: WindowID
        let mouseX: CGFloat
        let originX: CGFloat
        var active = false
        var target: Int
    }
    private var drag: Drag?
    /// A drag whose mouse-up never arrived must not freeze the bar. Runs only while dragging.
    private var dragWatchdog: Timer?
    private var ignoreNextMouseUp = false

    var isDragging: Bool { drag?.active == true }

    init() {
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.contextMenu = { [weak self] in self.flatMap { $0.delegate?.barMenu($0) } }
        separator.boxType = .separator
        background.addSubview(separator)
        panel.contentView = background
        panel.orderFrontRegardless()
    }

    func setFrame(_ frame: NSRect) {
        guard frame != panel.frame else { return }
        cancelDrag()
        panel.setFrame(frame, display: true)
        update(pins: content.pins, items: content.items, trusted: content.trusted)
    }

    func close() {
        cancelDrag()
        panel.orderOut(nil)
        panel.close()
    }

    func update(pins: [PinnedApp], items: [BarItem], trusted: Bool) {
        content = (pins, items, trusted)
        guard !isDragging else { return }  // applied when the drag ends
        let height = background.bounds.height, width = background.bounds.width
        let gap: CGFloat = 3, pinWidth = Bar.pinWidth(barHeight: height)
        let pinsX = width - 8 - CGFloat(pins.count) * pinWidth
        let windowsEnd = pins.isEmpty ? width - 8 : pinsX - 12
        let x: CGFloat = 8

        var pinKeys = Set<String>()
        var pinX = pinsX
        for pin in pins {
            pinKeys.insert(pin.url.path)
            let button = pinButtons[pin.url.path] ?? add(BarButton(kind: .pin, bar: self))
            pinButtons[pin.url.path] = button
            button.pin = pin
            button.configure(icon: pin.icon, title: nil, toolTip: pin.name, badge: pin.badge)
            button.running = pin.running
            let frame = NSRect(x: pinX, y: 0, width: pinWidth, height: height)
            if button.frame != frame { button.frame = frame }
            pinX += pinWidth
        }
        for (key, button) in pinButtons where !pinKeys.contains(key) {
            button.removeFromSuperview()
            pinButtons[key] = nil
        }
        separator.isHidden = pins.isEmpty
        if !pins.isEmpty {
            separator.frame = NSRect(x: pinsX - 6, y: Bar.inset + 6, width: 1, height: height - 2 * Bar.inset - 12)
        }

        warningButton.isHidden = trusted
        if !trusted {
            if warningButton.superview == nil { background.addSubview(warningButton) }
            warningButton.configure(icon: NSImage(named: NSImage.cautionName), title: "WindowBar needs Accessibility access. Click to open Settings.", toolTip: nil)
            warningButton.frame = NSRect(x: x, y: 0, width: max(min(440, windowsEnd - x), 0), height: height)
        }
        let visibleItems = trusted ? items : []

        let layout = BarLayout.windows(count: visibleItems.count, available: windowsEnd - x, gap: gap)
        let shown = Array(visibleItems.prefix(layout.shown))
        overflowItems = Array(visibleItems.dropFirst(layout.shown))
        buttonWidth = layout.width
        slots = shown.indices.map { x + CGFloat($0) * (layout.width + gap) }
        shownIDs = shown.map(\.id)

        let alive = Set(shownIDs)
        for (id, button) in windowButtons where !alive.contains(id) {
            button.removeFromSuperview()
            windowButtons[id] = nil
        }
        for (index, item) in shown.enumerated() {
            let frame = NSRect(x: slots[index], y: 0, width: layout.width, height: height)
            if let button = windowButtons[item.id] {
                button.configure(icon: item.icon, title: item.title, toolTip: item.title, highlighted: item.focused, dimmed: item.dimmed, badge: item.badge)
                if button.frame != frame { animate { button.animator().frame = frame } }
            } else {
                let button = add(BarButton(kind: .window, bar: self))
                button.windowID = item.id
                button.configure(icon: item.icon, title: item.title, toolTip: item.title, highlighted: item.focused, dimmed: item.dimmed, badge: item.badge)
                button.frame = frame
                windowButtons[item.id] = button
            }
        }

        overflowButton.isHidden = overflowItems.isEmpty
        if !overflowItems.isEmpty {
            if overflowButton.superview == nil { background.addSubview(overflowButton) }
            let overflowX = shown.isEmpty ? x : slots[shown.count - 1] + layout.width + gap
            overflowButton.configure(icon: nil, title: "+\(overflowItems.count)", toolTip: "\(overflowItems.count) more windows")
            overflowButton.frame = NSRect(x: overflowX, y: 0, width: 44, height: height)
        }
    }

    // MARK: Mouse

    func mouseDown(_ button: BarButton, _ event: NSEvent) {
        ignoreNextMouseUp = false
        guard button.kind == .window, let id = button.windowID, let index = shownIDs.firstIndex(of: id) else { return }
        drag = Drag(id: id, mouseX: event.locationInWindow.x, originX: button.frame.minX, target: index)
    }

    func mouseDragged(_ button: BarButton, _ event: NSEvent) {
        guard var current = drag, current.id == button.windowID, let first = slots.first, let last = slots.last else { return }
        let dx = event.locationInWindow.x - current.mouseX
        if !current.active {
            guard abs(dx) > 4 else { return }
            current.active = true
            button.layer?.zPosition = 1
            button.alphaValue = 0.8
            dragWatchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                if !CGEventSource.buttonState(.combinedSessionState, button: .left) { self?.cancelDrag() }
            }
        }
        button.frame.origin.x = min(max(current.originX + dx, first), last)
        let previous = current.target
        current.target = slot(at: button.frame.midX)
        drag = current
        let target = current.target
        guard target != previous else { return }
        animate {
            for (index, id) in shownIDs.filter({ $0 != current.id }).enumerated() {
                windowButtons[id]?.animator().frame.origin.x = slots[index < target ? index : index + 1]
            }
        }
    }

    func mouseUp(_ button: BarButton, _ event: NSEvent) {
        if ignoreNextMouseUp {
            ignoreNextMouseUp = false
            return
        }
        // Released over the bar: reorder. Anywhere else: cancel, as with Escape
        if isDragging { return finishDrag(commit: background.bounds.contains(background.convert(event.locationInWindow, from: nil))) }
        drag = nil
        guard button.bounds.contains(button.convert(event.locationInWindow, from: nil)) else { return }  // released elsewhere: no click
        switch button.kind {
        case .window:
            if let id = button.windowID {
                delegate?.bar(self, clicked: id)
            } else if button === warningButton {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        case .pin: if let pin = button.pin { delegate?.bar(self, open: pin) }
        case .overflow:
            if let menu = delegate?.bar(self, overflowMenuFor: overflowItems) {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
            }
        }
    }

    func contextMenu(for button: BarButton) -> NSMenu? {
        guard !isDragging else { return nil }
        if let id = button.windowID { return delegate?.bar(self, menuFor: id) }
        if let pin = button.pin { return delegate?.bar(self, menuFor: pin) }
        return nil
    }

    /// Ends a drag without reordering: Escape, mouse released outside WindowBar, sleep or display change.
    func cancelDrag() {
        guard isDragging else {
            drag = nil
            return
        }
        ignoreNextMouseUp = true
        finishDrag(commit: false)
    }

    private func finishDrag(commit: Bool) {
        guard let finished = drag else { return }
        drag = nil
        dragWatchdog?.invalidate()
        dragWatchdog = nil
        if let button = windowButtons[finished.id] {
            button.layer?.zPosition = 0
            button.alphaValue = 1
        }
        if commit { delegate?.bar(self, moved: finished.id, to: finished.target, among: shownIDs) }
        delegate?.barDragDidEnd(self)
    }

    private func slot(at midX: CGFloat) -> Int {
        slots.indices.min { abs(slots[$0] + buttonWidth / 2 - midX) < abs(slots[$1] + buttonWidth / 2 - midX) } ?? 0
    }

    private func add(_ button: BarButton) -> BarButton {
        background.addSubview(button)
        return button
    }

    private func animate(_ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            changes()
        }
    }
}
