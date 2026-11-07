import ApplicationServices
import CoreGraphics
import Foundation

/// Undocumented macOS functions, the ones AltTab and yabai use. Each is looked up at runtime, so a macOS update that
/// removes one makes WindowBar fall back to public APIs instead of crashing. Signatures follow yabai's extern.h.
enum Private {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventRecordTo = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func resolve<T>(_ name: String, as type: T.Type) -> T? {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let pointer = skyLight.flatMap({ dlsym($0, name) }) ?? dlsym(defaultHandle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let mainConnectionID = resolve("SLSMainConnectionID", as: MainConnectionID.self)
    private static let copyManagedDisplaySpaces = resolve("SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
    private static let copySpacesForWindows = resolve("SLSCopySpacesForWindows", as: CopySpacesForWindows.self)
    private static let getWindow = resolve("_AXUIElementGetWindow", as: GetWindow.self)
    private static let getProcessForPID = resolve("GetProcessForPID", as: GetProcessForPID.self)
    private static let setFrontProcess = resolve("_SLPSSetFrontProcessWithOptions", as: SetFrontProcess.self)
    private static let postEventRecordTo = resolve("SLPSPostEventRecordTo", as: PostEventRecordTo.self)
    private static let connection = mainConnectionID?()

    static var status: String {
        let symbols: [(String, Bool)] = [("connection", connection != nil), ("displaySpaces", copyManagedDisplaySpaces != nil),
                                         ("windowSpaces", copySpacesForWindows != nil), ("windowID", getWindow != nil),
                                         ("front", getProcessForPID != nil && setFrontProcess != nil), ("makeKey", postEventRecordTo != nil)]
        return symbols.map { "\($0.0)=\($0.1 ? "ok" : "missing")" }.joined(separator: " ")
    }

    /// The window server's id for an Accessibility window element.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let getWindow, getWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// Which display owns each Space and which Spaces are shown. nil if unavailable or in an unexpected shape.
    static func spaceMap() -> SpaceMap? {
        guard let connection, let copyManagedDisplaySpaces,
              let displays = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        var map = SpaceMap()
        for display in displays {
            guard let uuid = display["Display Identifier"] as? String else { continue }
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                if let id = spaceID(space) { map.owners[id] = uuid }
            }
            if let current = display["Current Space"] as? [String: Any], let id = spaceID(current) { map.current.insert(id) }
        }
        return map.available ? map : nil
    }

    /// The Spaces each window is on. Windows the window server doesn't know are left out. nil if unavailable.
    static func spaces(for windows: [CGWindowID]) -> [CGWindowID: [UInt64]]? {
        guard let connection, let copySpacesForWindows else { return nil }
        var result: [CGWindowID: [UInt64]] = [:]
        for window in windows {
            // Selector 7: all Spaces (current, other and fullscreen)
            guard let spaces = copySpacesForWindows(connection, 7, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { continue }
            result[window] = spaces.map(\.uint64Value)
        }
        return result
    }

    /// Brings exactly this window to the front, not all of its app's windows. Returns false if unavailable or refused.
    static func front(pid: pid_t, window: CGWindowID) -> Bool {
        guard let getProcessForPID, let setFrontProcess else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        return setFrontProcess(&psn, window, 0x200) == .success  // kCPSUserGenerated
    }

    /// Makes the window the key window of its app, which fronting and raising don't always do. Same synthetic event
    /// record yabai and AltTab send.
    static func makeKey(pid: pid_t, window: CGWindowID) -> Bool {
        guard let getProcessForPID, let postEventRecordTo else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: window.littleEndian) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        for index in 0x20..<0x30 { bytes[index] = 0xff }
        bytes[0x08] = 0x01
        guard postEventRecordTo(&psn, &bytes) == .success else { return false }
        bytes[0x08] = 0x02
        return postEventRecordTo(&psn, &bytes) == .success
    }

    private static func spaceID(_ space: [String: Any]) -> UInt64? {
        (space["id64"] as? NSNumber ?? space["ManagedSpaceID"] as? NSNumber)?.uint64Value
    }
}
