import AppKit

/// Puts a window into a WindowServer space of its own that sits above every normal space.
/// Mission Control and App Exposé animate the windows of regular spaces; an ordinary window, whatever
/// its level, is moved out of the way during those animations and the display underneath shows through.
/// Uses private SkyLight calls, looked up at run time so a missing symbol only disables the feature.
final class OverlaySpace {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceSetLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias SpacesCall = @convention(c) (Int32, CFArray) -> Void
    private typealias WindowsToSpaces = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias SpaceDestroy = @convention(c) (Int32, UInt64) -> Void

    private static let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let lib, let p = dlsym(lib, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private let cid: Int32
    private let space: UInt64

    /// nil if the private interface is not available.
    init?(window: NSWindow) {
        guard let main = Self.sym("CGSMainConnectionID", MainConnection.self),
              let create = Self.sym("CGSSpaceCreate", SpaceCreate.self),
              let setLevel = Self.sym("CGSSpaceSetAbsoluteLevel", SpaceSetLevel.self),
              let add = Self.sym("CGSAddWindowsToSpaces", WindowsToSpaces.self),
              let show = Self.sym("CGSShowSpaces", SpacesCall.self) else { return nil }
        cid = main()
        space = create(cid, 1, nil)
        guard space != 0 else { return nil }
        setLevel(cid, space, Int32.max)
        add(cid, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: space)] as CFArray)
        show(cid, [NSNumber(value: space)] as CFArray)
    }

    deinit {
        Self.sym("CGSHideSpaces", SpacesCall.self)?(cid, [NSNumber(value: space)] as CFArray)
        Self.sym("CGSSpaceDestroy", SpaceDestroy.self)?(cid, space)
    }
}
