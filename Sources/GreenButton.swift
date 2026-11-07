import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "local.windowbar", category: "green")

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<GreenButton>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}

/// The green button maximizes, as on Windows, instead of entering full screen: a mouse event tap catches clicks on it
/// and hands the window to the worker. Option-click enters full screen. Windows already in full screen, and windows
/// whose green button only zooms, keep macOS's behavior. Runs on its own thread, so a busy main thread never delays clicks.
final class GreenButton {
    /// The window whose green button was clicked, its app, and whether to enter full screen instead.
    var onClick: (AXUIElement, pid_t, Bool) -> Void = { _, _, _ in }

    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var retry: CFRunLoopTimer?
    private let installed = OSAllocatedUnfairLock(initialState: false)
    /// The mouse-down went to WindowBar, so its drags and mouse-up must not reach the app either.
    private var swallowing = false

    var active: Bool { installed.withLock { $0 } }

    func start() {
        let thread = Thread { [unowned self] in
            runLoop = CFRunLoopGetCurrent()
            // The tap needs the Accessibility permission: try until it's granted
            let retry = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent(), 2, 0, 0) { [unowned self] _ in install() }
            CFRunLoopTimerSetTolerance(retry, 0.5)
            CFRunLoopAddTimer(runLoop, retry, .defaultMode)
            self.retry = retry
            CFRunLoopRun()
        }
        thread.name = "WindowBar green button"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func install() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = [CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                           callback: tapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log.error("could not create the mouse event tap")
            return
        }
        CFRunLoopAddSource(runLoop, CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        tap = port
        installed.withLock { $0 = true }
        retry.map(CFRunLoopTimerInvalidate)
        log.info("green button tap installed")
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            swallowing = false
            return pass
        case .leftMouseDown:
            swallowing = false
            let modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskShift, .maskAlternate])
            guard modifiers.isEmpty || modifiers == .maskAlternate,
                  let (window, pid) = greenButtonWindow(at: event.location) else { return pass }
            swallowing = true
            onClick(window, pid, modifiers == .maskAlternate)
            return nil
        case .leftMouseDragged:
            return swallowing ? nil : pass
        case .leftMouseUp:
            defer { swallowing = false }
            return swallowing ? nil : pass
        default:
            return pass
        }
    }

    /// The window whose full-screen green button is at `point`, if it can be resized. Accessibility is only asked when
    /// the click is near the top-left corner of some app window, so other clicks cost nothing.
    private func greenButtonWindow(at point: CGPoint) -> (AXUIElement, pid_t)? {
        // macOS keeps transparent click-through windows above all apps (Dock, Notification Center, screenshots), so the
        // window list can't tell which window gets the click. It only rules clicks out; Accessibility's hit test decides.
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let nearCorner = list.contains { info in
            guard let bounds = frame(info), bounds.contains(point), point.x - bounds.minX < 120, point.y - bounds.minY < 60,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer >= 0, layer < dockLevel else { return false }
            return (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != getpid()
        }
        guard nearCorner else { return nil }

        // Uses the global Accessibility timeout (0.4 s, set by the worker); the system-wide element can't have its own
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
        var pid: pid_t = 0
        if let hit { AXUIElementGetPid(hit, &pid) }
        let subrole = hit.flatMap { string($0, kAXSubroleAttribute) }
        log.debug("click near a window corner: hit \(error.rawValue), pid \(pid), subrole \(subrole ?? "-")")
        guard error == .success, let hit, subrole == "AXFullScreenButton", pid != getpid(),
              let window = element(hit, kAXWindowAttribute) ?? element(hit, kAXParentAttribute) else { return nil }

        var fullScreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
           (fullScreen as? NSNumber)?.boolValue == true { return nil }  // the green button leaves full screen
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success, settable.boolValue else {
            log.debug("window of \(pid) can't be resized, leaving its green button alone")
            return nil
        }
        log.info("green button clicked on a window of \(pid)")
        return (window, pid)
    }

    private func frame(_ info: [String: Any]) -> CGRect? {
        (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
