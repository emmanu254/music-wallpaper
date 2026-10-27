import AppKit
import Darwin

/// Best-effort access to WindowServer space membership for this app's own windows.
/// These symbols are private and can change between macOS releases.
enum DesktopSpaces {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias CopyDisplaysFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias ChangeMembershipFn = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias CopyMembershipFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let library, let address = dlsym(library, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }
    private static let connect = symbol("SLSMainConnectionID", as: ConnectionFn.self)
    private static let copyDisplays = symbol("SLSCopyManagedDisplaySpaces", as: CopyDisplaysFn.self)
    private static let add = symbol("SLSAddWindowsToSpaces", as: ChangeMembershipFn.self)
    private static let remove = symbol("SLSRemoveWindowsFromSpaces", as: ChangeMembershipFn.self)
    private static let copyMembership = symbol("SLSCopySpacesForWindows", as: CopyMembershipFn.self)

    struct DisplaySpaces {
        let displayID: String
        let ids: [UInt64]
    }

    static func topology() -> [DisplaySpaces]? {
        guard let connect, let copyDisplays, add != nil, remove != nil, copyMembership != nil,
              let displays = copyDisplays(connect())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let result = displays.compactMap { display -> DisplaySpaces? in
            guard let identifier = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [[String: Any]] else { return nil }
            let ids = spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
            return ids.isEmpty ? nil : DisplaySpaces(displayID: identifier, ids: ids)
        }
        return result.isEmpty ? nil : result
    }

    static func identifier(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Assign a single owned window to a single space and verify the result.
    static func assign(window: NSWindow, to target: UInt64, allSpaces: [UInt64]) -> Bool {
        guard let connect, let add, let remove else { return false }
        let connection = connect()
        let windows = [NSNumber(value: window.windowNumber)] as CFArray
        let ids = allSpaces.map { NSNumber(value: $0) } as CFArray
        remove(connection, windows, ids)
        add(connection, windows, [NSNumber(value: target)] as CFArray)
        return isExclusivelyAssigned(window: window, to: target)
    }

    static func isExclusivelyAssigned(window: NSWindow, to target: UInt64) -> Bool {
        guard let connect, let copyMembership else { return false }
        let connection = connect()
        let windows = [NSNumber(value: window.windowNumber)] as CFArray
        guard let result = copyMembership(connection, 7, windows)?.takeRetainedValue() as? [NSNumber] else { return false }
        // A window temporarily attached to multiple Spaces can slide away with
        // the wrong one even though the requested Space is present.
        return Set(result.map(\.uint64Value)) == Set([target])
    }
}
