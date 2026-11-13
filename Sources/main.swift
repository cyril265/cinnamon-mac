import AppKit
import os

private let log = Logger(subsystem: "local.windowbar", category: "app")

extension NSScreen {
    var displayID: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0 }

    /// Stable across reconnects, and the identifier SkyLight uses for this display's Spaces.
    var uuid: String {
        CGDisplayCreateUUIDFromDisplayID(displayID).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "display-\(displayID)"
    }
}

final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, image: NSImage? = nil, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.image = image
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

/// Main-thread side: displays, bars, running apps, pinned apps and the user's window order.
/// An app's icon as the Dock shows it, drawn from its large sizes only. Some apps ship corrupt small sizes
/// (Docker Desktop), which would show on standard-resolution displays.
func appIcon(_ url: URL) -> NSImage {
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    let large = icon.representations.filter { $0.pixelsWide >= 64 }
    guard !large.isEmpty else { return icon }
    let image = NSImage(size: icon.size)
    image.addRepresentations(large)
    return image
}

final class AppController: NSObject, NSApplicationDelegate, BarDelegate {
    private struct AppMeta {
        let launch: Date?
        let key: String?
        let url: URL?
        let name: String
        let icon: NSImage
    }

    private let worker = WindowWorker()
    private let greenButton = GreenButton()
    private let badges = Badges()
    private var badge: [String: String] = [:]
    private var bars: [String: Bar] = [:]
    private var displays: [Display] = []
    private var barHeight: CGFloat = 44
    private var generation = 0
    private var world = WorldSnapshot()
    private static let orderDefaultsKey = "windowOrder"
    private var savedOrder = UserDefaults.standard.stringArray(forKey: orderDefaultsKey) ?? []
    private lazy var order = TaskOrder(saved: savedOrder)
    private static let launcherOrderDefaultsKey = "launcherOrder"
    private var launcherOrder = LauncherOrder(saved: UserDefaults.standard.stringArray(forKey: launcherOrderDefaultsKey) ?? [])
    /// Apps that only get a launcher, never window buttons, by app key.
    private static let keptLaunchersDefaultsKey = "keptLaunchers"
    private var keptLaunchers = Set(UserDefaults.standard.stringArray(forKey: keptLaunchersDefaultsKey) ?? [])
    /// Apps whose launcher sits at the bar's left end, by app key. All others are on the right.
    private static let leftLaunchersDefaultsKey = "leftLaunchers"
    private var leftLaunchers = Set(UserDefaults.standard.stringArray(forKey: leftLaunchersDefaultsKey) ?? [])
    /// The launchers as the bars show them, by app key.
    private var launcherSides: (left: [String], right: [String]) = ([], [])
    private var pins: [Launcher] = []
    private var meta: [pid_t: AppMeta] = [:]
    private var trusted = false
    private var topologyWork: DispatchWorkItem?
    private var tokens: [NSObjectProtocol] = []
    private var timers: [Timer] = []
    private var escapeMonitor: Any?
    private var terminationSource: DispatchSourceSignal?
    private var diagnosticsSource: DispatchSourceSignal?
    /// The open list of a combined button or the +N button: closed windows leave it while it stays open.
    private weak var windowList: WindowListMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        log.info("starting, trusted=\(self.trusted), private APIs: \(Private.status)")
        worker.onSnapshot = { [weak self] in self?.apply($0) }
        worker.start()
        greenButton.onClick = { [worker] window, pid, fullScreen in worker.greenButton(window, pid: pid, fullScreen: fullScreen) }
        greenButton.onClose = { [worker] window, pid in worker.closeButton(window, pid: pid) }
        greenButton.start()
        badges.onChange = { [weak self] in
            self?.badge = $0
            self?.render()
        }
        badges.start()
        pins = loadPins()
        updateTopology()
        pushApps()
        worker.setTrusted(trusted)

        let workspace = NSWorkspace.shared.notificationCenter
        let appEvents = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                         NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification]
        for name in appEvents {
            tokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.pushApps() })
        }
        tokens.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.pushApps()
        })
        tokens.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.worker.spacesChanged()
        })
        tokens.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cancelDrags()
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            tokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleTopology()
                self?.worker.spacesChanged()
            })
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleTopology()
        })

        // Housekeeping: permission changes, Dock changes, and a safety net for missed display or app notifications
        let housekeeping = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.housekeeping() }
        housekeeping.tolerance = 0.5
        timers.append(housekeeping)
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancelDrags() }
        }

        // launchctl stops agents with SIGTERM, which AppKit would not turn into a normal quit
        signal(SIGTERM, SIG_IGN)
        terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSource?.setEventHandler { NSApp.terminate(nil) }
        terminationSource?.resume()

        // `pkill -USR1 -x WindowBar` writes the diagnostics to ~/Library/Logs/WindowBar/diagnostics.txt
        signal(SIGUSR1, SIG_IGN)
        diagnosticsSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        diagnosticsSource?.setEventHandler { [weak self] in
            self?.diagnostics { text in
                let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WindowBar")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? text.write(to: folder.appendingPathComponent("diagnostics.txt"), atomically: true, encoding: .utf8)
            }
        }
        diagnosticsSource?.resume()
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.info("quitting, restoring resized windows")
        worker.restoreAdjustments()
    }

    // MARK: State

    private func housekeeping() {
        let nowTrusted = AXIsProcessTrusted()
        if nowTrusted != trusted {
            trusted = nowTrusted
            log.info("accessibility permission \(nowTrusted ? "granted" : "revoked")")
            worker.setTrusted(nowTrusted)
            render()
        }
        let newPins = loadPins()
        if newPins.map(\.url) != pins.map(\.url) {
            pins = newPins
            render()
        }
        pushApps()
        updateTopology()
    }

    private func pushApps() {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
        let pids = Set(running.map(\.processIdentifier))
        let before = meta.mapValues(\.launch)
        meta = meta.filter { pids.contains($0.key) }
        for app in running where meta[app.processIdentifier] == nil || meta[app.processIdentifier]?.launch != app.launchDate {
            meta[app.processIdentifier] = AppMeta(launch: app.launchDate, key: app.bundleIdentifier ?? app.bundleURL?.standardizedFileURL.path,
                                                  url: app.bundleURL, name: app.localizedName ?? "", icon: app.bundleURL.map(appIcon) ?? app.icon ?? NSImage())
        }
        // Launchers and running dots depend on the running apps, also those without windows
        if meta.mapValues(\.launch) != before { render() }
        worker.setApps(running.map { AppInfo(pid: $0.processIdentifier, launch: $0.launchDate, hidden: $0.isHidden) })
        worker.setFrontmost(NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    /// Display changes come in bursts while a dock connects or disconnects: wait until they settle.
    private func scheduleTopology() {
        cancelDrags()
        topologyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateTopology() }
        topologyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func updateTopology() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let primaryMaxY = (screens.first { $0.frame.origin == .zero } ?? screens[0]).frame.maxY
        // Every bar is as tall as the Dock, so the bar on the Dock's display covers it exactly
        let dockInset = screens.map { $0.visibleFrame.minY - $0.frame.minY }.max() ?? 0
        let height = dockInset > 20 ? dockInset : 44
        let current = screens.map { screen in
            Display(id: screen.displayID, uuid: screen.uuid,
                    frame: CGRect(x: screen.frame.minX, y: primaryMaxY - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height),
                    usableBottom: primaryMaxY - screen.visibleFrame.minY, usableTop: primaryMaxY - screen.visibleFrame.maxY)
        }
        guard current != displays || height != barHeight else { return }
        displays = current
        barHeight = height

        let uuids = Set(current.map(\.uuid))
        for (uuid, bar) in bars where !uuids.contains(uuid) {
            bar.close()
            bars[uuid] = nil
        }
        for screen in screens {
            let bar = bars[screen.uuid] ?? Bar()
            bar.delegate = self
            bars[screen.uuid] = bar
            bar.setFrame(NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: height))
        }
        generation += 1
        log.info("topology \(self.generation): \(current.count) displays, bar height \(height)")
        worker.setTopology(current, barHeight: height, generation: generation)
        render()
    }

    private func apply(_ snapshot: WorldSnapshot) {
        // Computed against an older display layout: a fresh one is on its way
        guard snapshot.generation == generation else { return }
        world = snapshot
        // Survives WindowBar restarts; the launch tells a relaunched app from a reused pid
        let launches = Dictionary(snapshot.windows.map { ($0.id, $0.launch) }, uniquingKeysWith: { first, _ in first })
        order.sync(snapshot.windows.map(\.id)) { id in "\(id.pid):\(Int(launches[id].flatMap { $0 }?.timeIntervalSince1970 ?? 0)):\(id.window)" }
        saveOrder()
        render()
        let alive = Set(snapshot.windows.map(\.id))
        windowList?.removeRows { !alive.contains($0) }
    }

    /// The windows that get a button. Apps set to Keep in Launchers get none, only their launcher.
    private func buttonWindows() -> [WindowSnapshot] {
        world.windows.filter { $0.visible && !(meta[$0.id.pid]?.key.map(keptLaunchers.contains) ?? false) }
    }

    private func render() {
        let windows = Dictionary(uniqueKeysWithValues: world.windows.map { ($0.id, $0) })
        // Like the Dock: pinned apps get a dot while running, and running apps that aren't pinned and have no window
        // button anywhere (no window, or only on other desktops) get an icon after the pins. Clicking one opens a window.
        let running = Set(meta.values.compactMap(\.key))
        let pinned = Set(pins.map(\.key))
        let shown = buttonWindows()
        let withButtons = Set(shown.compactMap { meta[$0.id.pid]?.key })
        var listed = pinned.union(withButtons)
        // One icon per app, also when several instances of it run
        let unpinned = meta.values.sorted { ($0.launch ?? .distantPast) < ($1.launch ?? .distantPast) }.compactMap { app -> Launcher? in
            guard let key = app.key, let url = app.url, listed.insert(key).inserted else { return nil }
            return Launcher(url: url, key: key, name: app.name, icon: app.icon, running: true, badge: badge[key])
        }
        // A pinned app gives way to its window buttons on every bar while it has a window on any of them
        let icons = pins.filter { !withButtons.contains($0.key) }.map { pin -> Launcher in
            var pin = pin
            pin.running = running.contains(pin.key)
            pin.badge = badge[pin.key]
            return pin
        } + unpinned
        let byKey = Dictionary(icons.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let launchers = launcherOrder.sorted(icons.map(\.key)).compactMap { byKey[$0] }
        let left = launchers.filter { leftLaunchers.contains($0.key) }, right = launchers.filter { !leftLaunchers.contains($0.key) }
        launcherSides = (left.map(\.key), right.map(\.key))

        for display in displays {
            guard let bar = bars[display.uuid], !bar.isDragging else { continue }
            let ids = order.sorted(shown.filter { $0.display == display.uuid }.map(\.id))
            let items = ids.compactMap { id -> BarItem? in
                guard let window = windows[id] else { return nil }
                let app = meta[id.pid]
                return BarItem(id: id, title: window.title.isEmpty ? app?.name ?? "" : window.title, icon: app?.icon ?? NSImage(),
                               focused: world.focused == id, dimmed: window.minimized || window.hidden, badge: app?.key.flatMap { badge[$0] },
                               app: app?.key ?? "pid:\(id.pid)", appName: app?.name ?? "")
            }
            bar.update(left: left, right: right, items: items, trusted: trusted)
        }
    }

    private func cancelDrags() {
        bars.values.filter(\.isDragging).forEach { $0.cancelDrag() }
    }

    /// Exactly the Dock's pinned apps, Finder first, as the Dock shows them.
    private func loadPins() -> [Launcher] {
        let known = Dictionary(pins.map { ($0.url.standardizedFileURL.path, $0) }, uniquingKeysWith: { first, _ in first })
        return Dock.pinnedApps().map { url in
            let path = url.standardizedFileURL.path
            if let pin = known[path] { return pin }
            return Launcher(url: url, key: Bundle(url: url)?.bundleIdentifier ?? path,
                             name: FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""),
                             icon: appIcon(url))
        }
    }

    private func reloadPins() {
        pins = loadPins()
        render()
    }

    /// The per-app options: Keep in Dock (pin/unpin through the Dock itself), Keep in Launchers and Show in Finder.
    private func appOptions(url: URL?, key: String?) -> [NSMenuItem] {
        guard let url else { return [] }
        var items: [NSMenuItem] = []
        if key != "com.apple.finder" {
            let keep = MenuAction("Keep in Dock") { [weak self] in
                if Dock.isPinned(url) { Dock.unpin(url) } else { Dock.pin(url) }
                // The Dock restarts to apply it; pick up its list once it has
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.reloadPins() }
            }
            keep.state = Dock.isPinned(url) ? .on : .off
            items.append(keep)
        }
        if let key {
            let kept = MenuAction("Keep in Launchers") { [weak self] in
                guard let self else { return }
                if keptLaunchers.remove(key) == nil { keptLaunchers.insert(key) }
                UserDefaults.standard.set(keptLaunchers.sorted(), forKey: Self.keptLaunchersDefaultsKey)
                render()
            }
            kept.state = keptLaunchers.contains(key) ? .on : .off
            items.append(kept)
        }
        items.append(MenuAction("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        return items
    }

    // MARK: BarDelegate

    func bar(_ bar: Bar, clicked id: WindowID) { worker.click(id) }

    func bar(_ bar: Bar, open launcher: Launcher) {
        NSWorkspace.shared.openApplication(at: launcher.url, configuration: .init())
    }

    func bar(_ bar: Bar, arranged ids: [WindowID]) {
        order.arrange(ids)
        saveOrder()
    }

    func bar(_ bar: Bar, movedApp key: String, to index: Int, among keys: [String], left: Bool) {
        moveLauncher(key, to: index, among: keys, left: left)
    }

    /// Puts an app's launcher at `index` among `keys`, the launchers shown on the side it goes to.
    private func moveLauncher(_ key: String, to index: Int, among keys: [String], left: Bool) {
        if left { leftLaunchers.insert(key) } else { leftLaunchers.remove(key) }
        UserDefaults.standard.set(leftLaunchers.sorted(), forKey: Self.leftLaunchersDefaultsKey)
        launcherOrder.move(key, to: index, among: keys, known: pins.map(\.key))
        UserDefaults.standard.set(launcherOrder.keys, forKey: Self.launcherOrderDefaultsKey)
    }

    private func saveOrder() {
        guard order.keys != savedOrder else { return }
        savedOrder = order.keys
        UserDefaults.standard.set(savedOrder, forKey: Self.orderDefaultsKey)
    }

    func barDragDidEnd(_ bar: Bar) { render() }

    func bar(_ bar: Bar, menuFor id: WindowID) -> NSMenu {
        let menu = NSMenu()
        let window = world.windows.first { $0.id == id }
        if window?.minimized == true || window?.hidden == true {
            menu.addItem(MenuAction("Restore") { [weak self] in self?.worker.focus(id) })
        } else {
            menu.addItem(MenuAction("Minimize") { [weak self] in self?.worker.minimize(id) })
        }
        menu.addItem(MenuAction("Close Window") { [weak self] in self?.worker.close(id) })
        menu.addItem(.separator())
        let app = meta[id.pid]
        appOptions(url: app?.url, key: app?.key).forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(MenuAction("Quit \(app?.name ?? "App")") {
            guard let running = NSRunningApplication(processIdentifier: id.pid), running.launchDate == app?.launch else { return }
            running.terminate()
        })
        return menu
    }

    func bar(_ bar: Bar, menuFor launcher: Launcher) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(MenuAction(launcher.running ? "Open New Window" : "Open") { NSWorkspace.shared.openApplication(at: launcher.url, configuration: .init()) })
        menu.addItem(.separator())
        appOptions(url: launcher.url, key: launcher.key).forEach(menu.addItem)
        // To the other side, next to the window buttons
        let onLeft = leftLaunchers.contains(launcher.key)
        menu.addItem(MenuAction(onLeft ? "Move to Right Side" : "Move to Left Side") { [weak self] in
            guard let self else { return }
            if onLeft {
                moveLauncher(launcher.key, to: 0, among: launcherSides.right, left: false)
            } else {
                moveLauncher(launcher.key, to: launcherSides.left.count, among: launcherSides.left, left: true)
            }
            render()
        })
        let instances = NSWorkspace.shared.runningApplications.filter { ($0.bundleIdentifier ?? $0.bundleURL?.standardizedFileURL.path) == launcher.key }
        // Finder can't be quit; macOS relaunches it
        if !instances.isEmpty && launcher.key != "com.apple.finder" {
            menu.addItem(.separator())
            menu.addItem(MenuAction("Quit \(launcher.name)") { instances.forEach { $0.terminate() } })
        }
        return menu
    }

    /// The windows of a combined app button: Close All Windows, the app's options and Quit.
    func bar(_ bar: Bar, menuForGroup ids: [WindowID]) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(MenuAction("Close All Windows") { [weak self] in ids.forEach { self?.worker.close($0) } })
        menu.addItem(.separator())
        let app = ids.first.flatMap { meta[$0.pid] }
        appOptions(url: app?.url, key: app?.key).forEach(menu.addItem)
        menu.addItem(.separator())
        let pids = Set(ids.map(\.pid))
        let instances = NSWorkspace.shared.runningApplications.filter { running in
            if let key = app?.key { return (running.bundleIdentifier ?? running.bundleURL?.standardizedFileURL.path) == key }
            return pids.contains(running.processIdentifier) && running.launchDate == meta[running.processIdentifier]?.launch
        }
        menu.addItem(MenuAction("Quit \(app?.name ?? "App")") { instances.forEach { $0.terminate() } })
        return menu
    }

    func bar(_ bar: Bar, listing items: [BarItem]) -> NSMenu {
        let menu = WindowListMenu()
        windowList = menu
        for item in items {
            let focus: () -> Void = { [weak self] in self?.worker.focus(item.id) }
            let entry = MenuAction(item.title, focus)
            entry.view = WindowMenuRow(item: item, onSelect: focus, onClose: { [weak self] in self?.worker.close(item.id) })
            menu.addItem(entry)
        }
        return menu
    }

    func barMenu(_ bar: Bar) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(MenuAction("Copy Diagnostics") { [weak self] in self?.copyDiagnostics() })
        menu.addItem(.separator())
        menu.addItem(MenuAction("Quit WindowBar") { NSApp.terminate(nil) })
        return menu
    }

    /// Window titles and app names are left out, so the dump is safe to paste anywhere.
    private func copyDiagnostics() {
        diagnostics { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func diagnostics(_ completion: @escaping (String) -> Void) {
        let header = ["WindowBar diagnostics \(Date())", "green button tap: \(greenButton.active)", "bars: \(bars.count), pins: \(pins.count), ordered windows: \(order.ids.count)",
                      "shown per display: " + displays.map { d in "\(d.uuid.prefix(8))=\(buttonWindows().filter { $0.display == d.uuid }.count)" }.joined(separator: " "),
                      "kept launchers: \(keptLaunchers.count), left launchers: \(leftLaunchers.count)",
                      "snapshot focused: \(world.focused.map { "\($0)" } ?? "-")"]
        worker.diagnostics { text in completion((header + [text]).joined(separator: "\n")) }
    }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
