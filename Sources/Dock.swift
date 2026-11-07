import AppKit
import os

private let log = Logger(subsystem: "local.windowbar", category: "dock")

/// The Dock's own list of pinned apps. WindowBar shows exactly these and changes them the way dockutil does:
/// edit the Dock's preferences, then restart the Dock so it picks them up. The Dock and WindowBar never disagree.
enum Dock {
    private static let domain = "com.apple.dock" as CFString
    private static let key = "persistent-apps" as CFString
    private static let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    /// Finder, which the Dock always shows first, followed by the pinned apps that still exist.
    static func pinnedApps() -> [URL] {
        var seen = Set<String>()
        return ([finder] + tiles().compactMap(url)).filter {
            $0.pathExtension == "app" && FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.standardizedFileURL.path).inserted
        }
    }

    static func isPinned(_ url: URL) -> Bool {
        pinnedApps().contains { $0.standardizedFileURL.path == url.standardizedFileURL.path }
    }

    /// Pins the app at the end, like the Dock's "Keep in Dock".
    static func pin(_ url: URL) {
        whenSettled {
            guard !isPinned(url) else { return }
            var data: [String: Any] = [
                "file-data": ["_CFURLString": url.absoluteString, "_CFURLStringType": 15],
                "file-label": FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                "file-type": 1,
            ]
            if let id = Bundle(url: url)?.bundleIdentifier { data["bundle-identifier"] = id }
            write(tiles() + [["tile-type": "file-tile", "tile-data": data]])
        }
    }

    static func unpin(_ url: URL) {
        whenSettled {
            let path = url.standardizedFileURL.path
            write(tiles().filter { tile in self.url(tile)?.standardizedFileURL.path != path })
        }
    }

    private static var lastWrite = Date.distantPast

    /// After a restart the Dock rewrites its preferences for a few seconds; a change made then gets overwritten.
    /// A queued change checks again, since another one may have restarted the Dock in the meantime. Main thread only.
    private static func whenSettled(_ change: @escaping () -> Void) {
        let wait = lastWrite.addingTimeInterval(5).timeIntervalSinceNow
        guard wait > 0 else { return change() }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { whenSettled(change) }
    }

    private static func tiles() -> [[String: Any]] {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] ?? []
    }

    private static func url(_ tile: [String: Any]) -> URL? {
        guard let string = ((tile["tile-data"] as? [String: Any])?["file-data"] as? [String: Any])?["_CFURLString"] as? String else { return nil }
        return string.hasPrefix("/") ? URL(fileURLWithPath: string) : URL(string: string)
    }

    private static func write(_ tiles: [[String: Any]]) {
        backup()
        CFPreferencesSetAppValue(key, tiles as CFArray, domain)
        guard CFPreferencesAppSynchronize(domain) else { return log.error("could not save the Dock's pins") }
        lastWrite = Date()
        // The Dock only reads its preferences at launch; launchd starts it again right away
        do {
            try Process.run(URL(fileURLWithPath: "/usr/bin/killall"), arguments: ["Dock"])
            log.info("Dock pins changed: \(tiles.count) apps")
        } catch {
            log.error("Dock pins saved, but restarting the Dock failed: \(error.localizedDescription)")
        }
    }

    /// Keeps the Dock's pin list from before the last change, in case it ever needs restoring.
    private static func backup() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WindowBar")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let backup = folder.appendingPathComponent("dock-persistent-apps-backup.plist")
        if let data = try? PropertyListSerialization.data(fromPropertyList: tiles(), format: .xml, options: 0) {
            try? data.write(to: backup, options: .atomic)
        }
    }
}
