import CoreGraphics
import Foundation

// Pure model: no AppKit, no Accessibility. Everything here is covered by Tests/ModelTests.swift.
// Geometry is in global top-left coordinates, in points, the space Accessibility uses.

/// Identity of a window for the lifetime of its app process. CGWindowIDs get reused, so the app session is part of it.
struct WindowID: Hashable, CustomStringConvertible {
    let pid: pid_t
    let session: Int
    let window: CGWindowID

    var description: String { "\(pid).\(session).\(window)" }

    /// The button of a running app with no window button: window server ids start at 1.
    static func app(_ pid: pid_t) -> WindowID { WindowID(pid: pid, session: 0, window: 0) }
    var isApp: Bool { window == 0 }
}

struct Display: Equatable {
    let id: CGDirectDisplayID
    /// Stable across reconnects, and the identifier SkyLight uses for a display's Spaces.
    let uuid: String
    let frame: CGRect
    /// The bottom edge macOS gives filled, zoomed and tiled windows: above the Dock if it's on this display.
    let usableBottom: CGFloat
    /// The top edge windows can use: below the menu bar if it's shown on this display.
    var usableTop: CGFloat = 0
}

/// Which display owns each Space, and which Spaces are currently shown. Empty when SkyLight is unavailable.
struct SpaceMap: Equatable {
    var owners: [UInt64: String] = [:]
    var current: Set<UInt64> = []

    var available: Bool { !owners.isEmpty }
}

enum Placement {
    /// The display a window belongs to. With separate Spaces per display, the display owning the window's Space wins,
    /// which keeps windows correct while macOS moves Spaces after a display disconnects. Otherwise the largest overlap
    /// decides, with some stickiness for windows spanning two displays.
    static func display(for frame: CGRect?, spaces: [UInt64], previous: String?, displays: [Display], spaceMap: SpaceMap) -> String? {
        let owners = Set(spaces.compactMap { spaceMap.owners[$0] })
        let owning = displays.filter { owners.contains($0.uuid) }
        if owning.count == 1 { return owning[0].uuid }
        let pool = owning.isEmpty ? displays : owning

        if let frame {
            let overlaps = pool.map { ($0.uuid, area(frame.intersection($0.frame))) }
            if let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 {
                if let previous, let kept = overlaps.first(where: { $0.0 == previous }), kept.1 >= best.1 * 0.8 { return previous }
                return best.0
            }
        }
        if let previous, pool.contains(where: { $0.uuid == previous }) { return previous }
        guard let frame else { return pool.first?.uuid }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return pool.min { distance(center, $0.frame) < distance(center, $1.frame) }?.uuid
    }

    /// Whether a window is on a currently shown Space. nil when SkyLight can't tell.
    static func onCurrentSpace(spaces: [UInt64], spaceMap: SpaceMap) -> Bool? {
        guard spaceMap.available, !spaces.isEmpty else { return nil }
        return spaces.contains { spaceMap.current.contains($0) }
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
    }
}

enum Reservation {
    /// Gap macOS tiling may leave between a window and the screen edge ("Tiled windows have margins").
    static let maxMargin: CGFloat = 16

    /// The height that makes a window end above the bar, keeping its tiling margin, or nil if it should be left alone.
    /// Only applies to windows macOS sized down to the bottom edge (Fill, zoom, tiling) that overlap the bar, on a display
    /// where the Dock doesn't already keep the bar's area free. Windows placed by hand higher up, small windows and
    /// windows reaching past the display are left alone.
    static func height(for frame: CGRect, on display: Display, barHeight: CGFloat) -> CGFloat? {
        let barTop = display.frame.maxY - barHeight
        let margin = display.usableBottom - frame.maxY
        guard display.usableBottom > barTop + 1,
              margin >= -2, margin <= maxMargin, frame.maxY > barTop + 1,
              frame.minY >= display.frame.minY - 1,
              frame.minX >= display.frame.minX - 1, frame.maxX <= display.frame.maxX + 1 else { return nil }
        let bottom = bottom(on: display, barHeight: barHeight, margin: max(margin, 0))
        return bottom - frame.minY >= 200 ? bottom - frame.minY : nil
    }

    /// Where a window WindowBar adjusted should end now. Follows bar height changes and the Dock moving displays.
    static func bottom(on display: Display, barHeight: CGFloat, margin: CGFloat) -> CGFloat {
        min(display.usableBottom, display.frame.maxY - barHeight) - margin
    }
}

enum Maximize {
    /// A maximized window, as on Windows: the display's full width, from below the menu bar to above the bar or the Dock.
    static func frame(on display: Display, barHeight: CGFloat) -> CGRect {
        let top = max(display.usableTop, display.frame.minY)
        let bottom = Reservation.bottom(on: display, barHeight: barHeight, margin: 0)
        return CGRect(x: display.frame.minX, y: top, width: display.frame.width, height: max(bottom - top, 0))
    }

    /// Whether a window already fills `target`, e.g. through Fill or tiling with margins, or an app that sizes in steps
    /// (terminals) or has a maximum size ended a little short of it.
    static func fills(_ frame: CGRect, _ target: CGRect) -> Bool {
        let slack = Reservation.maxMargin
        return abs(frame.minX - target.minX) <= slack && abs(frame.minY - target.minY) <= slack
            && frame.maxX <= target.maxX + 2 && frame.maxY <= target.maxY + 2
            && frame.width >= target.width - 2 * slack - 24 && frame.height >= target.height - 2 * slack - 24
    }

    /// Where a maximized window goes on restore when there is no earlier frame to return to: centered, two thirds of the maximized size.
    static func fallbackRestore(for target: CGRect) -> CGRect {
        target.insetBy(dx: target.width / 6, dy: target.height / 6).integral
    }
}

/// The user's order of window buttons. Each window is remembered by a stable key (app launch and window server id),
/// so the order survives WindowBar restarts, and a window that briefly drops out (an app rebuilding its accessibility,
/// a permission blip) gets its place back within `grace`. New windows go to the end in the order they were created;
/// dragging reorders within one bar.
struct TaskOrder {
    static let grace: TimeInterval = 60

    private(set) var ids: [WindowID] = []
    /// Every remembered window in order: the present ones and those gone for less than `grace`. What gets saved.
    private(set) var keys: [String] = []
    private var goneSince: [String: Date] = [:]
    private var keyByID: [WindowID: String] = [:]

    /// `saved` is an earlier `keys`: windows found again within `grace` of `now` take their old places.
    init(saved: [String] = [], now: Date = Date()) {
        var seen = Set<String>()
        keys = saved.filter { seen.insert($0).inserted }
        goneSince = Dictionary(uniqueKeysWithValues: keys.map { ($0, now) })
    }

    mutating func sync(_ present: [WindowID], key: (WindowID) -> String, now: Date = Date()) {
        keyByID = Dictionary(present.map { ($0, key($0)) }, uniquingKeysWith: { first, _ in first })
        let idByKey = Dictionary(keyByID.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        // Expire first: a window back after the grace period counts as new, even if nothing synced in between
        keys.removeAll { key in goneSince[key].map { now.timeIntervalSince($0) > Self.grace } ?? false }
        goneSince = goneSince.filter { now.timeIntervalSince($0.value) <= Self.grace }
        for key in keys where idByKey[key] == nil && goneSince[key] == nil { goneSince[key] = now }
        for key in idByKey.keys { goneSince[key] = nil }
        let known = Set(keys)
        // Window server ids grow over time, so this is the order the windows were opened in; app buttons go after them
        for key in idByKey.filter({ !known.contains($0.key) }).sorted(by: { ($0.value.isApp ? .max : $0.value.window) < ($1.value.isApp ? .max : $1.value.window) }).map(\.key) {
            // An app's button and its windows take over each other's place: the first window opened, the last one closed
            let gone = keys.indices.filter { Self.group(keys[$0]) == Self.group(key) && Self.isApp(keys[$0]) != Self.isApp(key) && goneSince[keys[$0]] != nil }
            if let index = gone.max(by: { goneSince[keys[$0]]! < goneSince[keys[$1]]! }) {
                goneSince[keys[index]] = nil
                keys[index] = key
            } else {
                keys.append(key)
            }
        }
        ids = keys.compactMap { idByKey[$0] }
    }

    /// Keys end in the window server id, 0 for an app's button; the part before it names the app.
    private static func group(_ key: String) -> Substring { key[..<(key.lastIndex(of: ":") ?? key.endIndex)] }
    private static func isApp(_ key: String) -> Bool { key.hasSuffix(":0") }

    func sorted(_ subset: [WindowID]) -> [WindowID] {
        let wanted = Set(subset)
        return ids.filter { wanted.contains($0) }
    }

    /// Moves `id` to position `index` among `visible`, the ids one bar shows in their current order.
    /// Windows that bar doesn't show keep their place relative to each other.
    mutating func move(_ id: WindowID, to index: Int, among visible: [WindowID]) {
        guard let key = keyByID[id], let from = keys.firstIndex(of: key) else { return }
        let others = visible.filter { $0 != id }.compactMap { keyByID[$0] }.filter { keys.contains($0) }
        keys.remove(at: from)
        if index < others.count, let anchor = keys.firstIndex(of: others[index]) {
            keys.insert(key, at: anchor)
        } else if let last = others.last, let anchor = keys.firstIndex(of: last) {
            keys.insert(key, at: anchor + 1)
        } else {
            keys.append(key)
        }
        let idByKey = Dictionary(keyByID.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        ids = keys.compactMap { idByKey[$0] }
    }
}

enum BarLayout {
    /// How many window buttons fit and how wide each is. If not all fit, room is kept for the overflow button.
    static func windows(count: Int, available: CGFloat, gap: CGFloat, minWidth: CGFloat = 120, maxWidth: CGFloat = 220, overflowWidth: CGFloat = 44) -> (shown: Int, width: CGFloat) {
        guard count > 0, available > 0 else { return (0, 0) }
        let fitAll = (available + gap) / CGFloat(count) - gap
        if fitAll >= minWidth { return (count, min(maxWidth, fitAll)) }
        let room = available - overflowWidth - gap
        let shown = max(0, Int((room + gap) / (minWidth + gap)))
        return shown == 0 ? (0, 0) : (shown, min(maxWidth, (room + gap) / CGFloat(shown) - gap))
    }
}
