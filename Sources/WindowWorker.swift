import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "local.windowbar", category: "windows")

/// Running apps as the main thread sees them. The launch date tells a relaunched app from a reused pid.
struct AppInfo {
    let pid: pid_t
    let launch: Date?
    let hidden: Bool
}

/// What the bars show about a window: plain values only. AX elements never leave the worker thread.
struct WindowSnapshot: Equatable {
    let id: WindowID
    /// The launch of the app session the window belongs to; part of what identifies it across WindowBar restarts.
    let launch: Date?
    let title: String
    let minimized: Bool
    let hidden: Bool
    let display: String?
    /// On the shown desktop of its display, and not an inactive native tab.
    let visible: Bool
}

struct WorldSnapshot: Equatable {
    var generation = 0
    var windows: [WindowSnapshot] = []
    var focused: WindowID?
}

private final class AppSession {
    let pid: pid_t
    let serial: Int
    let launch: Date?
    let element: AXUIElement
    var hidden: Bool
    var observer: AXObserver?
    var observed: [CGWindowID: AXUIElement] = [:]
    var retryAt = Date.distantPast
    var backoff: TimeInterval = 0
    /// The window a scan cut short by the deadline continues at, so a slow app's later windows aren't starved. The
    /// element finds it again when it has no window server id yet.
    var resume: (id: WindowID, element: AXUIElement)?
    /// A window couldn't be read since the last complete scan.
    var missed = false
    var lastScan = Date.distantPast
    /// Complete scans in a row that found nothing new. Quiet apps are reconciled less often.
    var quiet = 0
    /// Something changed since the last complete scan.
    var changed = false

    /// How long a missed notification can go unnoticed: 3 s, doubling per quiet scan up to 24 s. Apps that refused
    /// notifications are always checked every 3 s.
    var reconcileInterval: TimeInterval { observer == nil ? 3 : 3 * Double(1 << min(quiet, 3)) }

    init(_ info: AppInfo, serial: Int) {
        pid = info.pid
        self.serial = serial
        launch = info.launch
        hidden = info.hidden
        element = AXUIElementCreateApplication(info.pid)
    }

    func noteChange() {
        changed = true
        quiet = 0
    }

    func slowDown() {
        backoff = min(max(backoff * 2, 0.5), 10)
        retryAt = Date() + backoff
    }
}

private struct WindowRecord {
    let id: WindowID
    var element: AXUIElement
    let sequence: Int
    var title = ""
    var minimized = false
    var fullScreen = false
    var frame: CGRect?
    var frameChangedAt = Date()
    var spaces: [UInt64] = []
    var display: String?
    /// Listed by Accessibility in the latest scan of its app. Accessibility only lists windows on shown desktops.
    var listed = true
    var onscreen = true
}

private struct WindowValues {
    var subrole: String?
    var title: String?
    var minimized: Bool?
    var frame: CGRect?
    var fullScreen: Bool?
}

/// A size change WindowBar made, so it can follow bar changes, undo it on quit, and never fight the user or the app.
private struct Adjustment {
    let original: CGRect
    /// The window's tiling margin to the screen edge, kept when it's shortened.
    let margin: CGFloat
    var applied: CGRect?
    var refused: CGRect?
}

private let syntheticIDs: CGWindowID = 0xF000_0000
private let windowAttributes = [kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute, kAXPositionAttribute, kAXSizeAttribute, "AXFullScreen"] as CFArray
/// Notifications that only change the window they're about, so only that window is read again.
private let singleWindowNotifications: Set<String> = [kAXTitleChangedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                                                      kAXWindowMovedNotification, kAXWindowResizedNotification]
private let windowNotifications = [kAXUIElementDestroyedNotification, kAXTitleChangedNotification, kAXWindowMiniaturizedNotification,
                                   kAXWindowDeminiaturizedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification]

private let observerCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    Unmanaged<WindowWorker>.fromOpaque(refcon).takeUnretainedValue().notified(notification as String, element: element, pid: pid)
}

/// Owns all Accessibility work on one thread with its own run loop: app observers, window records, focus, resizing.
/// The main thread talks to it through the public methods and gets immutable snapshots back.
final class WindowWorker {
    var onSnapshot: (WorldSnapshot) -> Void = { _ in }

    private var runLoop: CFRunLoop?
    private var apps: [pid_t: AppSession] = [:]
    private var records: [WindowID: WindowRecord] = [:]
    private var displays: [Display] = []
    private var barHeight: CGFloat = 44
    private var generation = 0
    private var trusted = false
    private var spaceMap = SpaceMap()
    private var frontmost: pid_t?
    private var focused: WindowID?
    private var focusIntent: WindowID?
    private var focusIntentAt = Date.distantPast
    /// The last click on a window button and whether it minimized, so quick repeated clicks alternate even while the
    /// animation runs and the app still reports its old state.
    private var lastClick: (id: WindowID, minimized: Bool, at: Date)?
    /// The window that was active before the current one. A minimize is reported after macOS already moved focus.
    private var lostFocus: (id: WindowID, at: Date)?
    private var journal: [WindowID: Adjustment] = [:]
    /// Windows maximized with the green button: the frame to restore, and the frame the window ended up with.
    private var maximized: [WindowID: (restore: CGRect, applied: CGRect)] = [:]
    private var settleUntil = Date.distantPast
    private var nextSerial = 0
    private var nextSequence = 0
    private var nextSyntheticID = syntheticIDs
    private var pendingApps = Set<pid_t>()
    private var pendingWindows: [WindowID: AXUIElement] = [:]
    private var pendingAll = false
    /// Re-read every window's Spaces, not just those of the windows read in this pass.
    private var pendingSpaces = false
    private var lastPublished: WorldSnapshot?
    private var flushArmed = false
    private var lastReadError = AXError.success
    private var errorCounts: [Int32: Int] = [:]

    func start() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [unowned self] in
            runLoop = CFRunLoopGetCurrent()
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.4)  // a hung app must not stall the others for long
            let reconcile = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3, 3, 0, 0) { [unowned self] _ in self.reconcile() }
            CFRunLoopTimerSetTolerance(reconcile, 0.5)
            CFRunLoopAddTimer(runLoop, reconcile, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "WindowBar windows"
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
    }

    // MARK: Main thread interface

    func setTrusted(_ value: Bool) {
        perform { [self] in
            guard value != trusted else { return }
            trusted = value
            if value {
                apps.values.forEach(observe)
                schedule(all: true)
            } else {
                // Permission revoked: stop changing windows and drop what depends on it. The journal stays, so
                // windows WindowBar shortened can still get their height back once the permission returns.
                apps.values.forEach(stopObserving)
                log.info("\(self.records.count, privacy: .public) windows removed: permission revoked")
                records = [:]
                focused = nil
                focusIntent = nil
                publish()
            }
        }
    }

    func setApps(_ infos: [AppInfo]) {
        perform { [self] in
            let present = Dictionary(infos.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
            for (pid, app) in apps where present[pid] == nil || present[pid]?.launch != app.launch {
                removeApp(pid, reason: present[pid] == nil ? "quit" : "launch date changed from \(String(describing: app.launch)) to \(String(describing: present[pid]?.launch))")
            }
            for info in infos {
                if let app = apps[info.pid] {
                    if app.hidden != info.hidden {
                        app.hidden = info.hidden
                        schedule(app: info.pid)
                    }
                } else {
                    let app = AppSession(info, serial: nextSerial)
                    nextSerial += 1
                    apps[info.pid] = app
                    if trusted { observe(app) }
                    schedule(app: info.pid)
                }
            }
        }
    }

    /// The frontmost app as NSWorkspace reports it. Accessibility's system-wide focus query is unreliable from an agent.
    func setFrontmost(_ pid: pid_t?) {
        perform { [self] in
            guard pid != frontmost else { return }
            // Another app came to the front: a pending focus correction would now override the user
            if let intent = focusIntent, pid != intent.pid { focusIntent = nil }
            frontmost = pid
            schedule()
        }
    }

    func setTopology(_ displays: [Display], barHeight: CGFloat, generation: Int) {
        perform { [self] in
            self.displays = displays
            self.barHeight = barHeight
            self.generation = generation
            settleUntil = Date() + 1.5  // windows are still moving between displays
            pendingSpaces = true
            schedule(all: true)
        }
    }

    func spacesChanged() {
        perform { [self] in
            focusIntent = nil
            settleUntil = max(settleUntil, Date() + 0.6)
            pendingSpaces = true
            schedule(all: true)
        }
    }

    /// Focuses the window, or minimizes it if it already has focus. Decided against the live focus, not the bars' copy.
    func click(_ id: WindowID) {
        perform { [self] in
            guard var (record, app) = resolve(id) else { return }
            if let live = readMinimized(record.element) { record.minimized = live }
            let minimize: Bool
            if let last = lastClick, last.id == id, Date().timeIntervalSince(last.at) < 1.5 {
                minimize = !last.minimized
            } else {
                minimize = !record.minimized && !app.hidden && isFocused(record, app)
            }
            if minimize {
                focusIntent = nil
                setMinimized(record, true)
            } else {
                // Minimized a moment ago: the cached and even the live state can still say otherwise
                if lastClick?.id == id && lastClick?.minimized == true { record.minimized = true }
                focus(record, app)
            }
            records[id]?.minimized = minimize
            lastClick = (id, minimize, Date())
            schedule(app: id.pid, delay: 0.1)
        }
    }

    func focus(_ id: WindowID) {
        perform { [self] in
            guard var (record, app) = resolve(id) else { return }
            if let live = readMinimized(record.element) { record.minimized = live }
            lastClick = nil
            focus(record, app)
            schedule(app: id.pid, delay: 0.1)
        }
    }

    func minimize(_ id: WindowID) {
        perform { [self] in
            guard let (record, _) = resolve(id) else { return }
            focusIntent = nil
            lastClick = nil
            setMinimized(record, true)
            schedule(app: id.pid, delay: 0.1)
        }
    }

    func close(_ id: WindowID) {
        perform { [self] in
            guard let (record, _) = resolve(id) else { return }
            focusIntent = nil
            var button: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(record.element, kAXCloseButtonAttribute as CFString, &button)
            guard error == .success, let button, CFGetTypeID(button) == AXUIElementGetTypeID() else { return count(error, "close") }
            count(AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString), "close")
            schedule(app: id.pid, delay: 0.1)
        }
    }

    /// A click on a window's green button: maximizes the window on its display, leaving the menu bar and the bar free,
    /// or restores it if it's already maximized. With `fullScreen`, native full screen instead.
    func greenButton(_ element: AXUIElement, pid: pid_t, fullScreen: Bool) {
        perform { [self] in
            guard trusted else { return }
            if fullScreen {
                count(AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, kCFBooleanTrue), "full screen")
            } else {
                toggleMaximized(element, pid: pid)
            }
            schedule(app: pid, delay: 0.1)
        }
    }

    /// Gives windows WindowBar shortened their original height back, if nobody changed them since. Blocks up to 1.5 s.
    func restoreAdjustments() {
        let done = DispatchSemaphore(value: 0)
        perform { [self] in
            if trusted {
                for (id, adjustment) in journal {
                    guard let applied = adjustment.applied, let record = records[id],
                          let current = readFrame(record.element), approximatelyEqual(current, applied) else { continue }
                    setSize(record.element, CGSize(width: current.width, height: adjustment.original.height))
                }
                journal = [:]
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)
    }

    func diagnostics(_ completion: @escaping (String) -> Void) {
        perform { [self] in
            var lines = ["trusted: \(trusted)", "private APIs: \(Private.status)", "topology generation: \(generation)",
                         "bar height: \(barHeight)", "settling: \(Date() < settleUntil)", "frontmost pid: \(frontmost.map { "\($0)" } ?? "-")",
                         "spaces: \(spaceMap.owners.count) known, shown \(spaceMap.current.sorted())", "focused: \(focused.map { "\($0)" } ?? "-")"]
            lines += displays.map { "display \($0.id) \($0.uuid) frame \($0.frame) usableBottom \($0.usableBottom)" }
            lines += apps.values.sorted { $0.pid < $1.pid }.map {
                "app \($0.pid).\($0.serial) hidden=\($0.hidden) observer=\($0.observer != nil) observedWindows=\($0.observed.count) backoff=\($0.backoff) quiet=\($0.quiet)"
            }
            lines += records.values.sorted { $0.sequence < $1.sequence }.map {
                "window \($0.id) display=\($0.display ?? "-") spaces=\($0.spaces) listed=\($0.listed) onscreen=\($0.onscreen) minimized=\($0.minimized) fullScreen=\($0.fullScreen) frame=\($0.frame.map { "\($0)" } ?? "-")"
            }
            lines += journal.map {
                "adjustment \($0.key) original=\($0.value.original) margin=\($0.value.margin) applied=\(String(describing: $0.value.applied)) refused=\(String(describing: $0.value.refused))"
            }
            lines += maximized.map { "maximized \($0.key) restore=\($0.value.restore) applied=\($0.value.applied)" }
            lines.append("AX errors by code: \(errorCounts.sorted { $0.key < $1.key })")
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async { completion(text) }
        }
    }

    // MARK: Scheduling

    private func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    private func after(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0) { _ in block() }
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
    }

    /// Coalesces bursts of notifications into one pass.
    private func schedule(app pid: pid_t? = nil, all: Bool = false, delay: TimeInterval = 0.05) {
        if let pid { pendingApps.insert(pid) }
        if all { pendingAll = true }
        guard !flushArmed else { return }
        flushArmed = true
        after(delay) { [unowned self] in flush() }
    }

    fileprivate func notified(_ notification: String, element: AXUIElement, pid: pid_t) {
        // The user picked another window of the same app while a focus check is pending: that check must not undo it.
        // Focus changes in the first 0.1 s are WindowBar's own transition and don't count.
        if notification == kAXFocusedWindowChangedNotification, let intent = focusIntent, intent.pid == pid,
           Date().timeIntervalSince(focusIntentAt) > 0.1, let app = apps[pid], let window = focusedWindow(of: app),
           let number = Private.windowID(of: window), number != intent.window {
            focusIntent = nil
        }
        if notification == kAXWindowMiniaturizedNotification { activateNext(afterMinimizing: element, pid: pid) }
        if singleWindowNotifications.contains(notification), let app = apps[pid], let number = Private.windowID(of: element) {
            let id = WindowID(pid: pid, session: app.serial, window: number)
            if records[id] != nil {
                pendingWindows[id] = element
                return schedule()
            }
        }
        schedule(app: pid)
    }

    /// The safety net for missed notifications: re-reads the apps that are due and every window's Spaces, which can
    /// change in Mission Control without any notification.
    private func reconcile() {
        guard trusted else { return }
        let now = Date()
        // Half a second early, so timer tolerance doesn't push a due app to the next tick
        for app in apps.values where now.timeIntervalSince(app.lastScan) >= app.reconcileInterval - 0.5 { pendingApps.insert(app.pid) }
        pendingSpaces = true
        schedule()
    }

    /// One pass over the apps and windows that need it, limited to 0.3 s so queued clicks never wait long. Apps it
    /// didn't get to keep their last known state and go first in the next pass.
    private func flush() {
        flushArmed = false
        let pids = pendingAll ? Set(apps.keys) : pendingApps
        let windows = pendingWindows
        let allSpaces = pendingSpaces
        pendingAll = false
        pendingApps = []
        pendingWindows = [:]
        pendingSpaces = false
        guard trusted else { return publish() }

        let deadline = Date() + 0.3
        let onscreen = windowNumbers([.optionOnScreenOnly])
        var everyWindow: Set<CGWindowID>??
        // Every window the window server has, including other desktops: only needed when a scan misses a window
        let alive = {
            if everyWindow == nil { everyWindow = .some(self.windowNumbers([.optionAll])) }
            return everyWindow!
        }
        spaceMap = Private.spaceMap() ?? SpaceMap()
        var unfinished = Set<pid_t>()
        var read = Set<WindowID>()
        // Least recently scanned first, so no app waits behind the same slow ones every time
        for pid in pids.sorted(by: { (apps[$0]?.lastScan ?? .distantPast) < (apps[$1]?.lastScan ?? .distantPast) }) {
            guard let app = apps[pid] else { continue }
            if Date() >= deadline || !scan(app, alive: alive, deadline: deadline, read: &read) { unfinished.insert(pid) }
        }
        for (id, element) in windows where !pids.contains(id.pid) {
            guard let app = apps[id.pid], app.serial == id.session, let listed = records[id]?.listed else { continue }
            guard Date() < deadline, let values = readWindow(element) else {
                unfinished.insert(id.pid)  // read it with the whole app next pass
                continue
            }
            guard eligible(values, known: true) else {
                removeWindow(id, in: app, reason: "subrole \(values.subrole ?? "-"), minimized \(String(describing: values.minimized))")
                continue
            }
            update(id, element: element, with: values, in: app)
            records[id]?.listed = listed
            observe(window: element, id: id.window, in: app)
            read.insert(id)
        }
        refreshPlacement(onscreen: onscreen, spacesFor: allSpaces ? Set(records.keys) : read)
        readFocus()
        reserveSpace()
        publish()
        if !unfinished.isEmpty {
            pendingApps.formUnion(unfinished)
            schedule()
        }
    }

    // MARK: Apps and windows

    private func observe(_ app: AppSession) {
        guard app.observer == nil, let runLoop else { return }
        var observer: AXObserver?
        guard AXObserverCreate(app.pid, observerCallback, &observer) == .success, let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let registered = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXApplicationHiddenNotification,
                          kAXApplicationShownNotification, kAXApplicationActivatedNotification]
            .map { AXObserverAddNotification(observer, app.element, $0 as CFString, refcon) }
        // An app that is still launching refuses registration; the next scan tries again
        guard registered.contains(.success) else { return }
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        app.observer = observer
    }

    private func observe(window element: AXUIElement, id: CGWindowID, in app: AppSession) {
        guard let observer = app.observer, app.observed[id] == nil else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in windowNotifications {
            // A busy app: try again on its next scan instead of spending the timeout six times
            if AXObserverAddNotification(observer, element, name as CFString, refcon) == .cannotComplete { return app.slowDown() }
        }
        app.observed[id] = element
    }

    private func unobserve(window id: CGWindowID, in app: AppSession) {
        guard let element = app.observed.removeValue(forKey: id), let observer = app.observer else { return }
        for name in windowNotifications { AXObserverRemoveNotification(observer, element, name as CFString) }
    }

    private func stopObserving(_ app: AppSession) {
        guard let observer = app.observer else { return }
        CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        app.observer = nil
        app.observed = [:]
    }

    private func removeApp(_ pid: pid_t, reason: String) {
        guard let app = apps.removeValue(forKey: pid) else { return }
        log.info("app \(pid, privacy: .public) removed: \(reason, privacy: .public)")
        stopObserving(app)
        records = records.filter { $0.key.pid != pid }
        // Also adjustments of windows WindowBar lost track of while it had no permission
        journal = journal.filter { $0.key.pid != pid }
        maximized = maximized.filter { $0.key.pid != pid }
        if focused?.pid == pid { focused = nil }
        if focusIntent?.pid == pid { focusIntent = nil }
        schedule()
    }

    private func removeWindow(_ id: WindowID, in app: AppSession, reason: String) {
        log.info("window \(id.description, privacy: .public) removed: \(reason, privacy: .public)")
        app.noteChange()
        records[id] = nil
        journal[id] = nil
        maximized[id] = nil
        unobserve(window: id.window, in: app)
    }

    /// Re-reads one app's windows until the deadline. A failed or skipped read keeps what is known instead of treating
    /// it as "no windows". Returns false if the deadline cut it short.
    private func scan(_ app: AppSession, alive: () -> Set<CGWindowID>?, deadline: Date, read: inout Set<WindowID>) -> Bool {
        guard Date() >= app.retryAt else { return true }
        if app.observer == nil { observe(app) }

        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app.element, kAXWindowsAttribute as CFString, &value)
        switch error {
        case .success, .noValue, .attributeUnsupported:
            break
        default:
            count(error, "windows")
            app.slowDown()
            log.debug("app \(app.pid) busy (\(error.rawValue)), retrying in \(app.backoff) s")
            return true
        }

        app.lastScan = Date()
        var complete = true
        var slow = false
        var listed = Set<WindowID>()
        /// Read, but not a window that gets a button, with what it said it is
        var excluded: [WindowID: String] = [:]
        let elements = value as? [AXUIElement] ?? []
        let ids = elements.map { identify($0, in: app) }
        // A scan cut short continues at the window where it stopped; the ones before were read in the previous pass
        let start = app.resume.flatMap { resume in ids.firstIndex(of: resume.id) ?? elements.firstIndex { CFEqual($0, resume.element) } } ?? 0
        app.resume = nil
        for (index, element) in elements.enumerated() {
            let id = ids[index]
            // At least one window per pass, so a slow app always gets through its windows
            if complete && index > start && Date() >= deadline {
                complete = false
                app.resume = (id, element)
            }
            guard complete, index >= start, let values = readWindow(element) else {
                if complete && index >= start {
                    app.missed = true
                    if lastReadError == .cannotComplete { slow = true }
                }
                if records[id] != nil { listed.insert(id) }  // not read this time: keep the last known state
                continue
            }
            guard eligible(values, known: records[id] != nil) else {
                excluded[id] = "subrole \(values.subrole ?? "-"), minimized \(String(describing: values.minimized))"
                continue
            }
            listed.insert(id)
            update(id, element: element, with: values, in: app)
            observe(window: element, id: id.window, in: app)
            read.insert(id)
        }
        if slow { app.slowDown() } else if complete { app.backoff = 0 }

        for (id, record) in records where id.pid == app.pid && !listed.contains(id) {
            // Not listed: on another desktop if the window server still has it, otherwise closed
            if let what = excluded[id] {
                removeWindow(id, in: app, reason: "no longer a standard window: \(what)")
            } else if id.window >= syntheticIDs {
                removeWindow(id, in: app, reason: "not listed, no window server id")
            } else if let alive = alive() {
                if !alive.contains(id.window) {
                    removeWindow(id, in: app, reason: "closed")
                } else if record.listed {
                    records[id]?.listed = false
                    app.noteChange()
                }
            }
            // The window server didn't answer: keep the window as it is
        }
        // Adjustments for windows that closed while WindowBar had no permission
        let orphans = Set(journal.keys).union(maximized.keys).filter { $0.pid == app.pid && records[$0] == nil }
        if complete, !orphans.isEmpty, let alive = alive() {
            for id in orphans where !alive.contains(id.window) {
                journal[id] = nil
                maximized[id] = nil
            }
        }
        if complete {
            if !app.changed && !app.missed { app.quiet += 1 }
            app.changed = false
            app.missed = false
        }
        return complete
    }

    /// Standard windows get a button. A minimized window reports itself as a dialog on recent macOS: it keeps its
    /// button, in its place.
    private func eligible(_ values: WindowValues, known: Bool) -> Bool {
        let subrole = values.subrole ?? (known ? kAXStandardWindowSubrole : nil)
        return subrole == kAXStandardWindowSubrole || (subrole == kAXDialogSubrole && values.minimized == true)
    }

    private func identify(_ element: AXUIElement, in app: AppSession) -> WindowID {
        if let window = Private.windowID(of: element) { return WindowID(pid: app.pid, session: app.serial, window: window) }
        // Without the private call, fall back to Accessibility's own element equality
        if let known = records.values.first(where: { $0.id.pid == app.pid && CFEqual($0.element, element) }) { return known.id }
        defer { nextSyntheticID += 1 }
        return WindowID(pid: app.pid, session: app.serial, window: nextSyntheticID)
    }

    private func update(_ id: WindowID, element: AXUIElement, with values: WindowValues, in app: AppSession) {
        let old = records[id]
        var record = old ?? {
            nextSequence += 1
            return WindowRecord(id: id, element: element, sequence: nextSequence)
        }()
        // The app rebuilt the window's accessibility element: act on the new one and move the observers to it
        if !CFEqual(record.element, element) {
            unobserve(window: id.window, in: app)
            record.element = element
        }
        record.listed = true
        if let title = values.title { record.title = title }
        if let minimized = values.minimized { record.minimized = minimized }
        if let fullScreen = values.fullScreen { record.fullScreen = fullScreen }
        if let frame = values.frame, frame != record.frame {
            record.frame = frame
            record.frameChangedAt = Date()
            // Someone else changed the window: forget WindowBar's adjustment or refusal for it
            if let adjustment = journal[id], !(adjustment.applied.map { approximatelyEqual($0, frame) } ?? false),
               !(adjustment.refused.map { approximatelyEqual($0, frame) } ?? false) {
                journal[id] = nil
            }
        }
        if old.map({ !$0.listed || $0.title != record.title || $0.minimized != record.minimized || $0.fullScreen != record.fullScreen || $0.frame != record.frame }) ?? true {
            app.noteChange()
        }
        records[id] = record
    }

    /// Reads all needed attributes in one round trip. nil if the app didn't answer (see lastReadError); single missing
    /// attributes stay nil.
    /// The frame alone, for WindowBar's own resizing: another attribute failing doesn't matter there.
    private func readFrame(_ element: AXUIElement) -> CGRect? { readWindow(element, strict: false)?.frame }

    private func readWindow(_ element: AXUIElement, strict: Bool = true) -> WindowValues? {
        var result: CFArray?
        lastReadError = AXUIElementCopyMultipleAttributeValues(element, windowAttributes, AXCopyMultipleAttributeOptions(rawValue: 0), &result)
        guard lastReadError == .success, let values = result as? [AnyObject], values.count == 6 else {
            count(lastReadError, "attributes")
            return nil
        }
        // A missing attribute stays nil; any other error, such as a busy app, fails the whole read
        for value in values where strict && CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType(value as! AXValue) == .axError {
            var error = AXError.success
            AXValueGetValue(value as! AXValue, .axError, &error)
            guard error == .noValue || error == .attributeUnsupported else {
                lastReadError = error
                count(error, "attributes")
                return nil
            }
        }
        func value(_ index: Int) -> AnyObject? {
            let value = values[index]
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return value
        }
        var origin = CGPoint.zero, size = CGSize.zero
        var frame: CGRect?
        if let position = value(3), let extent = value(4), CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(extent) == AXValueGetTypeID(),
           AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(extent as! AXValue, .cgSize, &size) {
            frame = CGRect(origin: origin, size: size)
        }
        return WindowValues(subrole: value(0) as? String, title: value(1) as? String, minimized: (value(2) as? NSNumber)?.boolValue,
                            frame: frame, fullScreen: (value(5) as? NSNumber)?.boolValue)
    }

    /// nil if the window server didn't answer, which must not be mistaken for "no windows".
    private func windowNumbers(_ options: CGWindowListOption) -> Set<CGWindowID>? {
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    private func refreshPlacement(onscreen: Set<CGWindowID>?, spacesFor ids: Set<WindowID>) {
        let spaces = Private.spaces(for: ids.map(\.window).filter { $0 < syntheticIDs }) ?? [:]
        for (id, record) in records {
            var updated = record
            if let windowSpaces = spaces[id.window] { updated.spaces = windowSpaces }
            if id.window >= syntheticIDs {
                updated.onscreen = true
            } else if let onscreen {
                updated.onscreen = onscreen.contains(id.window)
            }
            updated.display = Placement.display(for: record.frame, spaces: updated.spaces, previous: record.display, displays: displays, spaceMap: spaceMap)
            records[id] = updated
        }
    }

    private func readFocus() {
        let previous = focused
        defer {
            if let previous, previous != focused { lostFocus = (previous, Date()) }
        }
        focused = nil
        guard let pid = frontmost, let app = apps[pid], let element = focusedWindow(of: app) else { return }
        focused = record(for: element, in: app)?.id
    }

    private func record(for element: AXUIElement, in app: AppSession) -> WindowRecord? {
        if let number = Private.windowID(of: element) { return records[WindowID(pid: app.pid, session: app.serial, window: number)] }
        return records.values.first { $0.id.pid == app.pid && CFEqual($0.element, element) }
    }

    private func focusedWindow(of app: AppSession) -> AXUIElement? {
        var window: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app.element, kAXFocusedWindowAttribute as CFString, &window)
        guard error == .success, let window, CFGetTypeID(window) == AXUIElementGetTypeID() else {
            if error != .noValue { count(error, "focus") }
            return nil
        }
        return (window as! AXUIElement)
    }

    /// Asks the app itself, so it's right even before NSWorkspace has reported an activation.
    private func isFocused(_ record: WindowRecord, _ app: AppSession) -> Bool {
        var front: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app.element, kAXFrontmostAttribute as CFString, &front) == .success,
              (front as? NSNumber)?.boolValue == true, let window = focusedWindow(of: app) else { return false }
        if record.id.window < syntheticIDs, let number = Private.windowID(of: window) { return number == record.id.window }
        return CFEqual(window, record.element)
    }

    private func publish() {
        let windows = records.values.sorted { $0.sequence < $1.sequence }.map { record -> WindowSnapshot in
            let hidden = apps[record.id.pid]?.hidden ?? false
            let current = Placement.onCurrentSpace(spaces: record.spaces, spaceMap: spaceMap)
            // Accessibility listing it, or SkyLight placing it on a current desktop while it's shown, minimized or
            // hidden, both count: the second keeps windows of a busy app visible when their desktop comes back
            let present = record.listed || (current == true && (record.onscreen || record.minimized || hidden))
            // A native tab that isn't selected is a non-minimized window the window server has ordered out
            let inactiveTab = !record.minimized && !hidden && !record.onscreen
            return WindowSnapshot(id: record.id, launch: apps[record.id.pid]?.launch, title: record.title, minimized: record.minimized, hidden: hidden, display: record.display,
                                  visible: present && current != false && !inactiveTab)
        }
        let snapshot = WorldSnapshot(generation: generation, windows: windows, focused: focused)
        guard snapshot != lastPublished else { return }
        lastPublished = snapshot
        let deliver = onSnapshot
        DispatchQueue.main.async { deliver(snapshot) }
    }

    // MARK: Actions

    private func resolve(_ id: WindowID) -> (WindowRecord, AppSession)? {
        guard trusted, let record = records[id], let app = apps[id.pid], app.serial == id.session else { return nil }
        return (record, app)
    }

    private func focus(_ record: WindowRecord, _ app: AppSession) {
        let id = record.id
        focusIntent = id
        focusIntentAt = Date()
        if app.hidden { count(AXUIElementSetAttributeValue(app.element, kAXHiddenAttribute as CFString, kCFBooleanFalse), "unhide") }
        if record.minimized { setMinimized(record, false) }
        bringForward(record, app)

        // Check that keyboard focus really landed on this window, and correct it once, unless the user has moved on
        after(0.25) { [unowned self] in
            guard focusIntent == id, let current = records[id], let app = apps[id.pid], app.serial == id.session else { return }
            focusIntent = nil
            guard !isFocused(current, app) else { return }
            log.notice("focus correction for \(id)")
            bringForward(current, app)
            schedule(app: id.pid, delay: 0.1)
        }
    }

    /// Fronts the app with only this window, makes it the app's key window, then raises it, as AltTab and yabai do.
    /// Without the key-window step, apps like Edge keep their previous window active. Making the whole app frontmost
    /// through Accessibility raises all its windows on every display, so that is only the fallback without SkyLight.
    private func bringForward(_ record: WindowRecord, _ app: AppSession) {
        let window = record.id.window
        if window < syntheticIDs, Private.front(pid: app.pid, window: window) {
            _ = Private.makeKey(pid: app.pid, window: window)
        } else {
            count(AXUIElementSetAttributeValue(app.element, kAXFrontmostAttribute as CFString, kCFBooleanTrue), "frontmost")
            AXUIElementSetAttributeValue(app.element, kAXFocusedWindowAttribute as CFString, record.element)
        }
        count(AXUIElementPerformAction(record.element, kAXRaiseAction as CFString), "raise")
        AXUIElementSetAttributeValue(record.element, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    private func readMinimized(_ element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// As on Windows: when the active window is minimized, by its own button or from the bar, the window right under it
    /// becomes active. macOS would leave its app in front with no active window, or pick another window of the same app.
    private func activateNext(afterMinimizing element: AXUIElement, pid: pid_t) {
        guard pid == frontmost, let app = apps[pid], let number = Private.windowID(of: element) else { return }
        let active = WindowID(pid: pid, session: app.serial, window: number)
        guard records[active] != nil else { return }
        let wasActive = focused == active || (lostFocus?.id == active && Date().timeIntervalSince(lostFocus!.at) < 1)
        guard wasActive else { return }
        records[active]?.minimized = true
        if focused == active { focused = nil }
        let candidates = records.values.filter { record in
            record.id != active && record.listed && !record.minimized && apps[record.id.pid]?.hidden == false
                && Placement.onCurrentSpace(spaces: record.spaces, spaceMap: spaceMap) != false
        }
        let byNumber = Dictionary(candidates.map { ($0.id.window, $0) }, uniquingKeysWith: { first, _ in first })
        // Front to back; the minimized window may still be on screen while it animates, so it's excluded by id
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let next = list.lazy.compactMap { info -> WindowRecord? in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let window = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            return byNumber[window]
        }.first
        guard let next, let nextApp = apps[next.id.pid], nextApp.serial == next.id.session else { return }
        focus(next, nextApp)
    }

    private func setMinimized(_ record: WindowRecord, _ minimized: Bool) {
        count(AXUIElementSetAttributeValue(record.element, kAXMinimizedAttribute as CFString, minimized ? kCFBooleanTrue : kCFBooleanFalse), "minimize")
    }

    private func toggleMaximized(_ element: AXUIElement, pid: pid_t) {
        guard let frame = readFrame(element) else { return }
        let record = apps[pid].flatMap { record(for: element, in: $0) }
        guard let uuid = Placement.display(for: frame, spaces: record?.spaces ?? [], previous: record?.display, displays: displays, spaceMap: spaceMap),
              let display = displays.first(where: { $0.uuid == uuid }) else { return }
        let target = Maximize.frame(on: display, barHeight: barHeight)
        let state = record.flatMap { maximized[$0.id] }

        if Maximize.fills(frame, target) || state.map({ approximatelyEqual(frame, $0.applied) }) == true {
            // Restore: to where it was before WindowBar maximized it, or centered if it got maximized some other way
            let restore = state.map { $0.restore }.flatMap { $0.intersects(display.frame) ? $0 : nil } ?? Maximize.fallbackRestore(for: target)
            setFrame(element, restore)
            if let record { maximized[record.id] = nil }
        } else if let result = setFrame(element, target), let record {
            maximized[record.id] = (frame, result)
        }
        if let record { journal[record.id] = nil }
    }

    /// Size, position, size again: the first size keeps a big window from being clamped at its old position.
    @discardableResult
    private func setFrame(_ element: AXUIElement, _ frame: CGRect) -> CGRect? {
        var origin = frame.origin
        setSize(element, frame.size)
        if let position = AXValueCreate(.cgPoint, &origin) {
            count(AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position), "position")
        }
        setSize(element, frame.size)
        return readFrame(element)
    }

    private func setSize(_ element: AXUIElement, _ size: CGSize) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        count(AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value), "size")
    }

    /// Keeps windows on displays without the Dock from ending under the bar: shortens windows macOS sized down to the
    /// bottom edge, and moves the bottom of windows it adjusted earlier when the bar height or Dock display changes.
    /// Waits while windows are moving or a mouse button is held, and never retries a window that refused.
    private func reserveSpace() {
        guard Date() >= settleUntil, !CGEventSource.buttonState(.combinedSessionState, button: .left) else { return }
        let now = Date()
        for (id, record) in records {
            guard record.listed, !record.minimized, !record.fullScreen, let frame = record.frame,
                  now.timeIntervalSince(record.frameChangedAt) > 0.4,
                  Placement.onCurrentSpace(spaces: record.spaces, spaceMap: spaceMap) != false,
                  let display = displays.first(where: { $0.uuid == record.display }) else { continue }

            if journal[id]?.refused.map({ approximatelyEqual($0, frame) }) == true { continue }
            if let adjustment = journal[id], let applied = adjustment.applied, approximatelyEqual(frame, applied) {
                let bottom = Reservation.bottom(on: display, barHeight: barHeight, margin: adjustment.margin)
                guard abs(frame.maxY - bottom) > 2, bottom - frame.minY >= 200 else { continue }
                resize(id, record.element, from: frame, toBottom: bottom, original: adjustment.original, margin: adjustment.margin)
            } else if let height = Reservation.height(for: frame, on: display, barHeight: barHeight) {
                resize(id, record.element, from: frame, toBottom: frame.minY + height, original: frame, margin: max(display.usableBottom - frame.maxY, 0))
            }
        }
    }

    private func resize(_ id: WindowID, _ element: AXUIElement, from frame: CGRect, toBottom bottom: CGFloat, original: CGRect, margin: CGFloat) {
        // A refused follow-up keeps the earlier successful adjustment, so quitting still restores the original height
        let applied = journal[id]?.applied
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success, settable.boolValue else {
            journal[id] = Adjustment(original: original, margin: margin, applied: applied, refused: frame)
            return
        }
        setSize(element, CGSize(width: frame.width, height: bottom - frame.minY))
        let result = readFrame(element)
        if let result, abs(result.maxY - bottom) <= 2 {
            journal[id] = Adjustment(original: original, margin: margin, applied: result)
            records[id]?.frame = result
            records[id]?.frameChangedAt = Date()
        } else {
            // A minimum size, or the app put it back: leave it, the bar covers its bottom edge
            journal[id] = Adjustment(original: original, margin: margin, applied: applied, refused: result ?? frame)
            log.info("window \(id) refused resizing")
        }
    }

    private func count(_ error: AXError, _ operation: StaticString) {
        guard error != .success else { return }
        errorCounts[error.rawValue, default: 0] += 1
        log.debug("AX \(operation) failed: \(error.rawValue)")
    }

    private func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
}
