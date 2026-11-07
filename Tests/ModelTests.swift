import CoreGraphics
import Foundation

@main
struct ModelTests {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        if !condition {
            failures += 1
            print("FAIL line \(line): \(message)")
        }
    }

    // Three displays like the owner's desk: main 1080p, MacBook below it with the Dock, 1080p to the right.
    static let primary = Display(id: 1, uuid: "A", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), usableBottom: 1080)
    static let macBook = Display(id: 2, uuid: "B", frame: CGRect(x: 1186, y: 1080, width: 1512, height: 982), usableBottom: 2017)
    static let right = Display(id: 3, uuid: "C", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080), usableBottom: 1080)
    static let displays = [primary, macBook, right]
    static let spaces = SpaceMap(owners: [1: "A", 2: "B", 3: "C", 4: "B"], current: [1, 2, 3])

    static func main() {
        placement()
        reservation()
        maximize()
        order()
        layout()
        print(failures == 0 ? "All model tests passed" : "\(failures) model test(s) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func placement() {
        let onMain = CGRect(x: 100, y: 100, width: 800, height: 600)
        check(Placement.display(for: onMain, spaces: [2], previous: nil, displays: displays, spaceMap: spaces) == "B",
              "Space ownership beats geometry, e.g. right after macOS moved a disconnected display's Spaces")
        check(Placement.display(for: onMain, spaces: [], previous: nil, displays: displays, spaceMap: spaces) == "A",
              "without Spaces, geometry decides")
        check(Placement.display(for: CGRect(x: 1500, y: 100, width: 1000, height: 500), spaces: [1, 3], previous: nil, displays: displays, spaceMap: spaces) == "C",
              "a window on several Spaces goes to its largest overlap among their displays")

        let spanning55 = CGRect(x: 1470, y: 100, width: 1000, height: 500)  // 45% on A, 55% on C
        check(Placement.display(for: spanning55, spaces: [], previous: "A", displays: displays, spaceMap: spaces) == "A",
              "a spanning window stays on its previous display while the difference is small")
        check(Placement.display(for: spanning55, spaces: [], previous: nil, displays: displays, spaceMap: spaces) == "C",
              "without history, the larger overlap wins")
        let spanning70 = CGRect(x: 1620, y: 100, width: 1000, height: 500)  // 30% on A, 70% on C
        check(Placement.display(for: spanning70, spaces: [], previous: "A", displays: displays, spaceMap: spaces) == "C",
              "a spanning window that has clearly moved changes display")

        let offscreen = CGRect(x: -5000, y: -5000, width: 300, height: 300)
        check(Placement.display(for: offscreen, spaces: [], previous: "B", displays: displays, spaceMap: spaces) == "B",
              "an offscreen window keeps its previous display")
        check(Placement.display(for: offscreen, spaces: [], previous: "gone", displays: displays, spaceMap: spaces) == "A",
              "an offscreen window without a valid previous display goes to the nearest one")
        check(Placement.display(for: nil, spaces: [], previous: nil, displays: displays, spaceMap: spaces) == "A",
              "unknown geometry and no history falls back to the first display")
        check(Placement.display(for: CGRect(x: 2000, y: 100, width: 500, height: 500), spaces: [9], previous: nil, displays: displays,
                                spaceMap: SpaceMap(owners: [9: "Main"], current: [9])) == "C",
              "a shared Space (separate Spaces off) falls back to geometry")
        check(Placement.display(for: CGRect(x: 2000, y: 100, width: 500, height: 500), spaces: [], previous: nil, displays: [], spaceMap: spaces) == nil,
              "no displays gives no display")

        check(Placement.onCurrentSpace(spaces: [4], spaceMap: spaces) == false, "another desktop of the MacBook is not current")
        check(Placement.onCurrentSpace(spaces: [3], spaceMap: spaces) == true, "the right display's shown desktop is current")
        check(Placement.onCurrentSpace(spaces: [], spaceMap: spaces) == nil, "unknown Spaces are unknown, not false")
        check(Placement.onCurrentSpace(spaces: [3], spaceMap: SpaceMap()) == nil, "without SkyLight nothing is known")
    }

    static func reservation() {
        let filled = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        check(Reservation.height(for: filled, on: primary, barHeight: 45) == 1005, "a filled window on a display without the Dock ends above the bar")
        check(Reservation.height(for: CGRect(x: 960, y: 30, width: 960, height: 1050), on: primary, barHeight: 45) == 1005, "a tiled half is shortened too")
        check(Reservation.height(for: CGRect(x: 1186, y: 1113, width: 1512, height: 904), on: macBook, barHeight: 45) == nil,
              "on the Dock's display macOS already keeps the bar's area free")
        check(Reservation.height(for: CGRect(x: 100, y: 100, width: 800, height: 800), on: primary, barHeight: 45) == nil, "a window placed by hand is left alone")
        check(Reservation.height(for: CGRect(x: 100, y: 960, width: 800, height: 120), on: primary, barHeight: 45) == nil, "a window too small to shorten is left alone")
        check(Reservation.height(for: CGRect(x: 1800, y: 30, width: 800, height: 1050), on: primary, barHeight: 45) == nil, "a window reaching past the display is left alone")
        check(Reservation.height(for: CGRect(x: 0, y: 30, width: 1920, height: 1005), on: primary, barHeight: 45) == nil, "an already shortened window is not touched again")
        check(Reservation.height(for: CGRect(x: 8, y: 38, width: 944, height: 1034), on: primary, barHeight: 45) == 989,
              "a tile with an 8 pt margin is shortened and keeps its margin")
        check(Reservation.height(for: CGRect(x: 8, y: 38, width: 944, height: 1010), on: primary, barHeight: 45) == nil,
              "a window ending 32 pt above the edge was placed by hand")

        check(Reservation.bottom(on: primary, barHeight: 70, margin: 0) == 1010, "an adjusted window follows a taller bar")
        check(Reservation.bottom(on: primary, barHeight: 30, margin: 8) == 1042, "and a shorter one, keeping its margin")
        let primaryWithDock = Display(id: 1, uuid: "A", frame: primary.frame, usableBottom: 1020)
        check(Reservation.bottom(on: primaryWithDock, barHeight: 45, margin: 0) == 1020, "when the Dock arrives, it ends above the Dock")
    }

    static func maximize() {
        let withMenuBar = Display(id: 1, uuid: "A", frame: primary.frame, usableBottom: 1080, usableTop: 25)
        check(Maximize.frame(on: withMenuBar, barHeight: 45) == CGRect(x: 0, y: 25, width: 1920, height: 1010),
              "maximized: full width, below the menu bar, above the bar")
        let dockBelow = Display(id: 2, uuid: "B", frame: macBook.frame, usableBottom: 1997, usableTop: 1117)
        check(Maximize.frame(on: dockBelow, barHeight: 65) == CGRect(x: 1186, y: 1117, width: 1512, height: 880),
              "on the Dock's display it ends above the Dock")
        check(Maximize.frame(on: primary, barHeight: 45).minY == 0, "a display without a menu bar starts at its top edge")

        let target = Maximize.frame(on: withMenuBar, barHeight: 45)
        check(Maximize.fills(target, target), "the maximized frame fills itself")
        check(Maximize.fills(CGRect(x: 8, y: 33, width: 1904, height: 994), target), "a filled window with tiling margins counts")
        check(Maximize.fills(CGRect(x: 0, y: 25, width: 1913, height: 1001), target), "a terminal sized in character steps counts")
        check(!Maximize.fills(CGRect(x: 0, y: 25, width: 960, height: 1010), target), "a left half doesn't")
        check(!Maximize.fills(CGRect(x: 100, y: 100, width: 1200, height: 800), target), "a placed window doesn't")
        check(!Maximize.fills(CGRect(x: 0, y: 25, width: 1920, height: 1055), target), "a window under the bar doesn't")
        let restored = Maximize.fallbackRestore(for: target)
        check(restored.midX == target.midX && restored.width == 1280, "the fallback restore is centered, two thirds wide")
    }

    static func order() {
        let ids = (1...5).map { WindowID(pid: 10, session: 0, window: CGWindowID($0)) }
        let (a, b, c, d, e) = (ids[0], ids[1], ids[2], ids[3], ids[4])
        let key = { (id: WindowID) in "\(id.pid):\(id.window)" }
        let t0 = Date(timeIntervalSince1970: 1000)
        var order = TaskOrder()
        order.sync([a, b, c], key: key, now: t0)
        order.sync([a, b, c, d, e], key: key, now: t0)
        check(order.ids == [a, b, c, d, e], "new windows are appended")
        order.sync([a, c, d, e], key: key, now: t0 + 1)
        check(order.ids == [a, c, d, e], "closed windows are dropped")
        order.sync([a, b, c, d, e], key: key, now: t0 + 1 + TaskOrder.grace)
        check(order.ids == [a, b, c, d, e], "a window back within the grace period gets its place back")
        order.sync([a, c, d, e], key: key, now: t0 + 100)
        order.sync([a, b, c, d, e], key: key, now: t0 + 100 + TaskOrder.grace + 1)
        check(order.ids == [a, c, d, e, b], "a window back after the grace period counts as new")

        order = TaskOrder()
        order.sync([e, c, a], key: key, now: t0)
        check(order.ids == [a, c, e], "windows found together are ordered by when they were opened")

        order = TaskOrder()
        order.sync([a, b, c], key: key, now: t0)
        order.move(c, to: 0, among: [a, b, c])
        let relaunched = [a, b, c].map { WindowID(pid: $0.pid, session: 1, window: $0.window) }
        var restored = TaskOrder(saved: order.keys, now: t0 + 500)
        restored.sync(relaunched.reversed(), key: key, now: t0 + 501)
        check(restored.ids == [relaunched[2], relaunched[0], relaunched[1]], "the order survives a WindowBar restart")

        order = TaskOrder()
        order.sync([a, b, c, d, e], key: key, now: t0)
        order.move(e, to: 0, among: [a, c, e])
        check(order.ids == [e, a, b, c, d], "moving to the front of one bar")
        check(order.sorted([a, c, e]) == [e, a, c], "that bar shows the new order")
        order.move(e, to: 2, among: [e, a, c])
        check(order.sorted([a, c, e]) == [a, c, e], "moving to the end of one bar")
        check(order.sorted([b, d]) == [b, d], "other bars keep their order")
        order.move(WindowID(pid: 99, session: 0, window: 1), to: 0, among: [a])
        check(order.ids.count == 5, "moving an unknown window does nothing")
        order.move(b, to: 0, among: [b])
        check(order.ids.contains(b), "moving the only window of a bar keeps it")
    }

    static func layout() {
        let five = BarLayout.windows(count: 5, available: 1000, gap: 3)
        check(five.shown == 5 && abs(five.width - 197.6) < 0.001, "five windows fit")
        check(BarLayout.windows(count: 2, available: 1000, gap: 3).width == 220, "button width is capped")
        let many = BarLayout.windows(count: 20, available: 1000, gap: 3)
        check(many.shown == 7 && many.width >= 120, "too many windows: as many as fit, the rest in overflow")
        check(BarLayout.windows(count: 0, available: 1000, gap: 3) == (0, 0), "no windows")
        check(BarLayout.windows(count: 3, available: 50, gap: 3).shown == 0, "no room: everything goes to overflow")
    }
}
