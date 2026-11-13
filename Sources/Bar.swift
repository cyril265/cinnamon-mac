import AppKit

/// An app icon in the launchers, left or right of the window buttons: a Dock pin, or a running app the bar has no window button for.
struct Launcher {
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
    /// Windows with the same app share a button when the bar is full.
    let app: String
    let appName: String
}

protocol BarDelegate: AnyObject {
    func bar(_ bar: Bar, clicked id: WindowID)
    func bar(_ bar: Bar, open launcher: Launcher)
    func bar(_ bar: Bar, arranged ids: [WindowID])
    /// `keys` are the launchers the bar shows on the side the app was dropped on, `left` that side.
    func bar(_ bar: Bar, movedApp key: String, to index: Int, among keys: [String], left: Bool)
    func barDragDidEnd(_ bar: Bar)
    func bar(_ bar: Bar, menuFor id: WindowID) -> NSMenu
    func bar(_ bar: Bar, menuFor launcher: Launcher) -> NSMenu
    func bar(_ bar: Bar, menuForGroup ids: [WindowID]) -> NSMenu
    func bar(_ bar: Bar, listing items: [BarItem]) -> NSMenu
    func barMenu(_ bar: Bar) -> NSMenu
}

final class BarButton: NSView {
    enum Kind { case launcher, window, overflow }

    let kind: Kind
    weak var bar: Bar?
    var windowID: WindowID?
    var launcher: Launcher?
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    /// How many windows a combined button stands for.
    private let countPill = CountPill()
    private let runningDot = NSView()
    private lazy var badgeView = BadgeView(compact: kind == .launcher)
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
        if kind != .launcher { addSubview(label) }
        if kind == .window { addSubview(countPill) }
        if kind != .overflow { addSubview(badgeView) }
        if kind == .launcher {
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

    func configure(icon: NSImage?, title: String?, toolTip: String?, highlighted: Bool = false, dimmed: Bool = false, badge: String? = nil, count: Int = 1) {
        if countPill.count != count {
            countPill.count = count
            needsLayout = true
        }
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
        case .launcher:
            let size = bounds.height
            iconView.frame = NSRect(x: (bounds.width - size) / 2, y: mid - size / 2, width: size, height: size)
            runningDot.frame = NSRect(x: (bounds.width - 3) / 2, y: 1, width: 3, height: 3)
        case .window:
            let size = min(height - 2, 40)
            iconView.frame = NSRect(x: 2, y: mid - size / 2, width: size, height: size)
            let pill = countPill.fittingSize
            countPill.frame = NSRect(x: bounds.width - 8 - pill.width, y: mid - pill.height / 2, width: pill.width, height: pill.height).integral
            let labelEnd = countPill.isHidden ? bounds.width - 6 : countPill.frame.minX - 6
            label.frame = NSRect(x: iconView.frame.maxX + 6, y: mid - 8, width: max(labelEnd - iconView.frame.maxX - 6, 0), height: 16)
        case .overflow:
            label.frame = NSRect(x: 0, y: mid - 8, width: bounds.width, height: 16)
        }
        if kind == .launcher, !badgeView.isHidden {
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
/// Compact badges, on launchers, are smaller and cap counts at 9+ to stay within their icon.
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

/// The number of windows a combined button stands for, in a small rounded pill.
final class CountPill: NSView {
    private let label = NSTextField(labelWithString: "")

    var count = 1 {
        didSet {
            label.stringValue = "\(count)"
            isHidden = count < 2
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        NSSize(width: max(20, ceil(label.intrinsicContentSize.width) + 12), height: 18)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        updateColor()
    }

    override func viewDidChangeEffectiveAppearance() { updateColor() }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The windows of a combined button or the +N button. One row is selected at a time, by the mouse or the arrow keys.
/// A closed window's row goes when the window is gone, so a close the app refuses or the user cancels keeps it.
final class WindowListMenu: NSMenu, NSMenuDelegate {
    private(set) var selected: NSMenuItem?

    init() {
        super.init(title: "")
        delegate = self
    }

    required init(coder: NSCoder) { fatalError() }

    func select(_ item: NSMenuItem?) {
        guard item !== selected else { return }
        selected?.view?.needsDisplay = true
        selected = item
        item?.view?.needsDisplay = true
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) { select(item) }

    /// Removes the rows of windows that are gone; closes the menu when none are left.
    func removeRows(where gone: (WindowID) -> Bool) {
        let rows = items.compactMap { $0.view as? WindowMenuRow }
        let removed = rows.filter { gone($0.item.id) }
        guard !removed.isEmpty else { return }
        removed.compactMap(\.enclosingMenuItem).forEach(removeItem)
        if items.isEmpty { return cancelTracking() }
        // The row that moved under the mouse gets no mouse-entered until the mouse moves
        DispatchQueue.main.async { [weak self] in
            self?.items.compactMap { $0.view as? WindowMenuRow }.forEach { $0.updateHover() }
        }
    }
}

/// A window in the list of a combined button or the +N button. Drawn by hand, as menus don't draw items with views:
/// the highlight, a check for the active window, the app icon, the title, and on hover an ✕ that closes the window
/// and keeps the menu open, as on Windows' window previews.
final class WindowMenuRow: NSView {
    let item: BarItem
    private let onSelect: () -> Void
    private let onClose: () -> Void
    private let font = NSFont.menuFont(ofSize: 0)
    private var overClose = false { didSet { if overClose != oldValue { needsDisplay = true } } }
    /// Close asked for; dimmed until the window is gone.
    private var closing = false { didSet { needsDisplay = true } }

    init(item: BarItem, onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.item = item
        self.onSelect = onSelect
        self.onClose = onClose
        let titleWidth = ceil((item.title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width)
        super.init(frame: NSRect(x: 0, y: 0, width: min(max(50 + titleWidth + 42, 220), 520), height: 24))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError() }

    private var closeRect: NSRect { NSRect(x: bounds.width - 30, y: (bounds.height - 18) / 2, width: 18, height: 18) }
    private var listMenu: WindowListMenu? { enclosingMenuItem?.menu as? WindowListMenu }
    private var highlighted: Bool { listMenu.map { $0.selected === enclosingMenuItem } ?? false }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = highlighted
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 6, yRadius: 6).fill()
        }
        let base: NSColor = highlighted ? .selectedMenuItemTextColor : item.dimmed ? .secondaryLabelColor : .labelColor
        let color = closing ? base.withAlphaComponent(0.5) : base
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let lineHeight = ceil(font.ascender - font.descender)
        let textY = (bounds.height - lineHeight) / 2
        if item.focused { ("✓" as NSString).draw(at: NSPoint(x: 13, y: textY), withAttributes: attributes) }
        item.icon.draw(in: NSRect(x: 28, y: (bounds.height - 16) / 2, width: 16, height: 16), from: .zero, operation: .sourceOver,
                       fraction: item.dimmed ? 0.5 : 1, respectFlipped: true, hints: nil)
        let titleEnd = highlighted ? closeRect.minX - 6 : bounds.width - 14
        (item.title as NSString).draw(in: NSRect(x: 50, y: textY, width: max(titleEnd - 50, 0), height: lineHeight), withAttributes: attributes)
        guard highlighted else { return }
        if overClose {
            NSColor.selectedMenuItemTextColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: closeRect, xRadius: 4, yRadius: 4).fill()
        }
        if let symbol = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Window")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [color]))) {
            let size = symbol.size
            symbol.draw(in: NSRect(x: closeRect.midX - size.width / 2, y: closeRect.midY - size.height / 2, width: size.width, height: size.height))
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { updateHover() }
    override func mouseMoved(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) { updateHover() }

    func updateHover() {
        guard let window else { return overClose = false }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let inside = bounds.contains(point)
        if inside { listMenu?.select(enclosingMenuItem) }
        overClose = inside && closeRect.contains(point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), let menu = enclosingMenuItem?.menu else { return }
        if closeRect.contains(point) {
            closing = true
            onClose()
        } else {
            menu.cancelTracking()
            onSelect()
        }
    }
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

    /// Launcher icons are as tall as the bar. macOS app icons leave a transparent margin of about a tenth on each side,
    /// so launchers are 80% as wide as their icons plus a small gap, and the running dot sits in the bottom margin.
    static func launcherWidth(barHeight: CGFloat) -> CGFloat { (barHeight * 0.8).rounded() + 4 }
    /// Space between the bar's ends and the launcher buttons: their visible icons sit 6pt from the ends.
    static let launcherMargin: CGFloat = 4
    weak var delegate: BarDelegate?
    private let panel = BarPanel()
    private let background = BarBackground()
    private let separator = NSBox()
    private let leftSeparator = NSBox()
    private var launcherButtons: [String: BarButton] = [:]
    private var windowButtons: [WindowID: BarButton] = [:]
    private lazy var overflowButton = BarButton(kind: .overflow, bar: self)
    private lazy var warningButton = BarButton(kind: .window, bar: self)
    /// One window, or the windows of an app sharing a button. Identified by its first window.
    private struct Entry {
        let items: [BarItem]
        var id: WindowID { items[0].id }
    }
    private var shownEntries: [Entry] = []
    private var overflowItems: [BarItem] = []
    private var slots: [CGFloat] = []
    private var buttonWidth: CGFloat = 0
    private var content: (left: [Launcher], right: [Launcher], items: [BarItem], trusted: Bool) = ([], [], [], true)
    /// The launchers at the bar's left end, before the window buttons, and at its right end, after them.
    private var shownLeft: [Launcher] = []
    private var shownRight: [Launcher] = []
    private var launcherWidth: CGFloat = 0

    /// What a drag moves: a window button, or an app icon by its key.
    private enum DragItem: Equatable {
        case window(WindowID)
        case app(String)
    }

    private struct Drag {
        let item: DragItem
        let button: BarButton
        let mouseX: CGFloat
        let originX: CGFloat
        var active = false
        var target: Int
        /// For launchers: whether `target` is on the left side.
        var left = false
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
        for box in [separator, leftSeparator] {
            box.boxType = .separator
            background.addSubview(box)
        }
        panel.contentView = background
        panel.orderFrontRegardless()
    }

    func setFrame(_ frame: NSRect) {
        guard frame != panel.frame else { return }
        cancelDrag()
        panel.setFrame(frame, display: true)
        update(left: content.left, right: content.right, items: content.items, trusted: content.trusted)
    }

    func close() {
        cancelDrag()
        panel.orderOut(nil)
        panel.close()
    }

    func update(left: [Launcher], right: [Launcher], items: [BarItem], trusted: Bool) {
        content = (left, right, items, trusted)
        guard !isDragging else { return }  // applied when the drag ends
        let height = background.bounds.height, width = background.bounds.width
        let gap: CGFloat = 3
        launcherWidth = Bar.launcherWidth(barHeight: height)
        shownLeft = left
        shownRight = right
        // Visible launcher icons sit 2pt inside their buttons: 6pt from the bar's ends, 6pt on both sides of the separators
        let leftEnd = launcherX(left.count, of: left.count, left: true)
        let rightStart = launcherX(0, of: right.count, left: false)
        let x: CGFloat = left.isEmpty ? 8 : leftEnd + 11
        let windowsEnd = right.isEmpty ? width - 8 : rightStart - 11

        var launcherKeys = Set<String>()
        for (onLeft, launchers) in [(true, left), (false, right)] {
            for (index, launcher) in launchers.enumerated() {
                launcherKeys.insert(launcher.url.path)
                let button = launcherButtons[launcher.url.path] ?? add(BarButton(kind: .launcher, bar: self))
                launcherButtons[launcher.url.path] = button
                button.launcher = launcher
                button.configure(icon: launcher.icon, title: nil, toolTip: launcher.name, badge: launcher.badge)
                button.running = launcher.running
                let frame = NSRect(x: launcherX(index, of: launchers.count, left: onLeft), y: 0, width: launcherWidth, height: height)
                if button.frame != frame { button.frame = frame }
            }
        }
        for (key, button) in launcherButtons where !launcherKeys.contains(key) {
            button.removeFromSuperview()
            launcherButtons[key] = nil
        }
        let separatorY = Bar.inset + 6, separatorHeight = height - 2 * Bar.inset - 12
        separator.isHidden = right.isEmpty
        if !right.isEmpty { separator.frame = NSRect(x: rightStart - 5, y: separatorY, width: 1, height: separatorHeight) }
        leftSeparator.isHidden = left.isEmpty
        if !left.isEmpty { leftSeparator.frame = NSRect(x: leftEnd + 4, y: separatorY, width: 1, height: separatorHeight) }

        warningButton.isHidden = trusted
        if !trusted {
            if warningButton.superview == nil { background.addSubview(warningButton) }
            warningButton.configure(icon: NSImage(named: NSImage.cautionName), title: "WindowBar needs Accessibility access. Click to open Settings.", toolTip: nil)
            warningButton.frame = NSRect(x: x, y: 0, width: max(min(440, windowsEnd - x), 0), height: height)
        }
        let visibleItems = trusted ? items : []

        let combined = BarLayout.combined(visibleItems.map(\.app), available: windowsEnd - x, gap: gap)
        var entries: [Entry] = []
        var groupIndex: [String: Int] = [:]
        for item in visibleItems {
            if combined.contains(item.app), let index = groupIndex[item.app] {
                entries[index] = Entry(items: entries[index].items + [item])
            } else {
                if combined.contains(item.app) { groupIndex[item.app] = entries.count }
                entries.append(Entry(items: [item]))
            }
        }

        let layout = BarLayout.windows(count: entries.count, available: windowsEnd - x, gap: gap)
        shownEntries = Array(entries.prefix(layout.shown))
        overflowItems = entries.dropFirst(layout.shown).flatMap(\.items)
        buttonWidth = layout.width
        slots = shownEntries.indices.map { x + CGFloat($0) * (layout.width + gap) }

        let alive = Set(shownEntries.map(\.id))
        for (id, button) in windowButtons where !alive.contains(id) {
            button.removeFromSuperview()
            windowButtons[id] = nil
        }
        for (index, entry) in shownEntries.enumerated() {
            let frame = NSRect(x: slots[index], y: 0, width: layout.width, height: height)
            let first = entry.items[0], group = entry.items.count > 1
            let button = windowButtons[entry.id] ?? add(BarButton(kind: .window, bar: self))
            let isNew = windowButtons[entry.id] == nil
            button.windowID = entry.id
            button.configure(icon: first.icon, title: group ? first.appName : first.title,
                             toolTip: entry.items.map(\.title).joined(separator: "\n"),
                             highlighted: entry.items.contains(where: \.focused), dimmed: entry.items.allSatisfy(\.dimmed),
                             badge: first.badge, count: entry.items.count)
            if isNew {
                button.frame = frame
                windowButtons[entry.id] = button
            } else if button.frame != frame {
                animate { button.animator().frame = frame }
            }
        }

        overflowButton.isHidden = overflowItems.isEmpty
        if !overflowItems.isEmpty {
            if overflowButton.superview == nil { background.addSubview(overflowButton) }
            let overflowX = shownEntries.isEmpty ? x : slots[shownEntries.count - 1] + layout.width + gap
            overflowButton.configure(icon: nil, title: "+\(overflowItems.count)", toolTip: "\(overflowItems.count) more windows")
            overflowButton.frame = NSRect(x: overflowX, y: 0, width: 44, height: height)
        }
    }

    // MARK: Mouse

    func mouseDown(_ button: BarButton, _ event: NSEvent) {
        ignoreNextMouseUp = false
        guard let item = dragItem(of: button), let place = place(of: item) else { return }
        drag = Drag(item: item, button: button, mouseX: event.locationInWindow.x, originX: button.frame.minX, target: place.index, left: place.left)
    }

    func mouseDragged(_ button: BarButton, _ event: NSEvent) {
        guard var current = drag, current.item == dragItem(of: button) else { return }
        let dx = event.locationInWindow.x - current.mouseX
        if !current.active {
            guard abs(dx) > 4 else { return }
            // The bar may have been laid out again since the mouse-down: start from where the button is now
            guard let place = place(of: current.item) else {
                drag = nil
                return
            }
            current = Drag(item: current.item, button: button, mouseX: current.mouseX, originX: button.frame.minX, active: true, target: place.index, left: place.left)
            button.layer?.zPosition = 1
            button.alphaValue = 0.8
            dragWatchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                if !CGEventSource.buttonState(.combinedSessionState, button: .left) { self?.cancelDrag() }
            }
        }
        let previous = (current.target, current.left)
        switch current.item {
        case .window(let id):
            guard let first = slots.first, let last = slots.last else { return }
            button.frame.origin.x = min(max(current.originX + dx, first), last)
            current.target = slot(at: button.frame.midX, in: slots, width: buttonWidth)
            drag = current
            let target = current.target
            guard target != previous.0 else { return }
            let others = shownEntries.filter { $0.id != id }.compactMap { windowButtons[$0.id] }
            animate {
                for (index, other) in others.enumerated() {
                    other.animator().frame.origin.x = slots[index < target ? index : index + 1]
                }
            }
        case .app(let key):
            // A launcher can be dropped on either side: it goes to the nearest place, and that side makes room for it
            let left = shownLeft.filter { $0.key != key }, right = shownRight.filter { $0.key != key }
            button.frame.origin.x = min(max(current.originX + dx, launcherX(0, of: 1, left: true)), launcherX(0, of: 1, left: false))
            let places = (0...left.count).map { (index: $0, left: true, x: launcherX($0, of: left.count + 1, left: true)) }
                + (0...right.count).map { (index: $0, left: false, x: launcherX($0, of: right.count + 1, left: false)) }
            guard let best = places.min(by: { abs($0.x - button.frame.minX) < abs($1.x - button.frame.minX) }) else { return }
            current.target = best.index
            current.left = best.left
            drag = current
            guard best.index != previous.0 || best.left != previous.1 else { return }
            animate {
                for (onLeft, launchers) in [(true, left), (false, right)] {
                    let gains = best.left == onLeft
                    for (index, launcher) in launchers.enumerated() {
                        let slot = gains && index >= best.index ? index + 1 : index
                        launcherButtons[launcher.url.path]?.animator().frame.origin.x = launcherX(slot, of: launchers.count + (gains ? 1 : 0), left: onLeft)
                    }
                }
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
                if let entry = entry(id), entry.items.count > 1 {
                    popUp(delegate?.bar(self, listing: entry.items), under: button)
                } else {
                    delegate?.bar(self, clicked: id)
                }
            } else if button === warningButton {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        case .launcher: if let launcher = button.launcher { delegate?.bar(self, open: launcher) }
        case .overflow: popUp(delegate?.bar(self, listing: overflowItems), under: button)
        }
    }

    private func entry(_ id: WindowID) -> Entry? { shownEntries.first { $0.id == id } }

    private func popUp(_ menu: NSMenu?, under button: BarButton) {
        menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    func contextMenu(for button: BarButton) -> NSMenu? {
        guard !isDragging else { return nil }
        if let id = button.windowID {
            if let entry = entry(id), entry.items.count > 1 { return delegate?.bar(self, menuForGroup: entry.items.map(\.id)) }
            return delegate?.bar(self, menuFor: id)
        }
        if let launcher = button.launcher { return delegate?.bar(self, menuFor: launcher) }
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
        finished.button.layer?.zPosition = 0
        finished.button.alphaValue = 1
        if commit {
            switch finished.item {
            case .window(let id):
                var entries = shownEntries
                if let from = entries.firstIndex(where: { $0.id == id }) {
                    entries.insert(entries.remove(at: from), at: finished.target)
                    delegate?.bar(self, arranged: entries.flatMap { $0.items.map(\.id) })
                }
            case .app(let key):
                delegate?.bar(self, movedApp: key, to: finished.target, among: (finished.left ? shownLeft : shownRight).map(\.key), left: finished.left)
            }
        }
        delegate?.barDragDidEnd(self)
    }

    private func dragItem(of button: BarButton) -> DragItem? {
        switch button.kind {
        case .window: return button.windowID.map { .window($0) }
        case .launcher: return button.launcher.map { .app($0.key) }
        case .overflow: return nil
        }
    }

    /// Where a dragged item sits now: its index among the window buttons, or among the launchers of its side.
    private func place(of item: DragItem) -> (index: Int, left: Bool)? {
        switch item {
        case .window(let id):
            guard windowButtons[id] != nil else { return nil }
            return shownEntries.firstIndex { $0.id == id }.map { ($0, false) }
        case .app(let key):
            if let index = shownLeft.firstIndex(where: { $0.key == key }) { return (index, true) }
            return shownRight.firstIndex { $0.key == key }.map { ($0, false) }
        }
    }

    /// Where launcher `index` sits on its side while that side shows `count` launchers. Each side is anchored at its end of the bar.
    private func launcherX(_ index: Int, of count: Int, left: Bool) -> CGFloat {
        left ? Bar.launcherMargin + CGFloat(index) * launcherWidth
            : background.bounds.width - Bar.launcherMargin - CGFloat(count - index) * launcherWidth
    }

    private func slot(at midX: CGFloat, in slots: [CGFloat], width: CGFloat) -> Int {
        slots.indices.min { abs(slots[$0] + width / 2 - midX) < abs(slots[$1] + width / 2 - midX) } ?? 0
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
