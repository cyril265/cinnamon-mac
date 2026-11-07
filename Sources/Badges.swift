import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "local.windowbar", category: "badges")

/// The notification badges the Dock shows on app icons ("3", "•"), read from the Dock through Accessibility.
/// The Dock posts no notification when a badge changes, so this asks once a second, on its own thread.
final class Badges {
    /// Badge text by app key (bundle id, else path), delivered on the main thread whenever it changes.
    var onChange: ([String: String]) -> Void = { _ in }

    /// The Dock's list of icons, found once per Dock process.
    private var list: AXUIElement?
    private var keys: [URL: String] = [:]
    private var last: [String: String] = [:]

    func start() {
        let thread = Thread { [unowned self] in
            let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent(), 1, 0, 0) { [unowned self] _ in autoreleasepool { poll() } }
            CFRunLoopTimerSetTolerance(timer, 0.2)
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
            CFRunLoopRun()
        }
        thread.name = "WindowBar badges"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// A failed read keeps the badges shown so far; the next poll finds the Dock again, e.g. after it restarted.
    private func poll() {
        guard AXIsProcessTrusted() else { return publish([:]) }
        guard let list = list ?? findList() else { return }
        guard let items = children(list) else {
            self.list = nil
            return
        }

        var badges: [String: String] = [:]
        let names = [kAXSubroleAttribute, "AXStatusLabel", kAXURLAttribute] as CFArray
        for item in items {
            var result: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(item, names, AXCopyMultipleAttributeOptions(rawValue: 0), &result) == .success,
                  let values = result as? [AnyObject], values.count == 3 else { return }
            var subrole: AnyObject?, label: AnyObject?, url: AnyObject?
            guard read(values[0], into: &subrole), read(values[1], into: &label), read(values[2], into: &url) else { return }
            guard subrole as? String == "AXApplicationDockItem", let label = label as? String, !label.isEmpty,
                  let url = (url as? URL) ?? (url as? String).flatMap(URL.init(string:)) else { continue }
            badges[key(url)] = label
        }
        publish(badges)
    }

    /// One value of a batched read. Items without a badge or URL simply lack the attribute; any other error is a
    /// failed read and returns false.
    private func read(_ value: AnyObject, into result: inout AnyObject?) -> Bool {
        guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError else {
            result = value
            return true
        }
        var error = AXError.success
        AXValueGetValue(value as! AXValue, .axError, &error)
        return error == .noValue || error == .attributeUnsupported
    }

    private func findList() -> AXUIElement? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else { return nil }
        let dock = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(dock, 0.5)
        list = children(dock)?.first { element in
            var role: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success && role as? String == kAXListRole
        }
        return list
    }

    private func publish(_ badges: [String: String]) {
        guard badges != last else { return }
        last = badges
        log.debug("badges: \(badges.count)")
        DispatchQueue.main.async { [onChange] in onChange(badges) }
    }

    private func key(_ url: URL) -> String {
        if let key = keys[url] { return key }
        let key = Bundle(url: url)?.bundleIdentifier ?? url.standardizedFileURL.path
        keys[url] = key
        return key
    }

    private func children(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement] ?? []
    }
}
