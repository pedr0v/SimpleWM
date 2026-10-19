import Foundation
import CoreGraphics
import ApplicationServices

/// Private SkyLight (SLS*/CGS*) functions, loaded with `dlopen`/`dlsym`.
///
/// Every symbol is optional. A missing symbol disables only the feature that
/// needs it. No private header and no C target exist in this package.
public final class SkyLight {
    public typealias MainConnectionIDFn = @convention(c) () -> Int32
    public typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    public typealias GetActiveSpaceFn = @convention(c) (Int32) -> UInt64
    public typealias SpaceGetTypeFn = @convention(c) (Int32, UInt64) -> Int32
    public typealias ManagedDisplayGetCurrentSpaceFn = @convention(c) (Int32, CFString) -> UInt64
    public typealias CopyManagedDisplayForWindowFn = @convention(c) (Int32, UInt32) -> Unmanaged<CFString>?
    public typealias CopyActiveMenuBarDisplayIdentifierFn = @convention(c) (Int32) -> Unmanaged<CFString>?
    public typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    public typealias MoveWindowsToManagedSpaceFn = @convention(c) (Int32, CFArray, UInt64) -> Void
    public typealias SpaceSetCompatIDFn = @convention(c) (Int32, UInt64, Int32) -> CGError
    public typealias SetWindowListWorkspaceFn = @convention(c) (Int32, UnsafePointer<UInt32>, Int32, Int32) -> CGError
    public typealias ManagedDisplayIsAnimatingFn = @convention(c) (Int32, CFString) -> Bool
    /// File-local symbol. `dlsym` returns NULL. The loader walks `LC_SYMTAB`.
    public typealias PerformBridgedOperationFn = @convention(c) (AnyObject) -> Int64

    /// Shared loader. `nil` members mean the symbol is absent.
    public static let shared = SkyLight()

    public let handle: UnsafeMutableRawPointer?
    public let mainConnectionID: MainConnectionIDFn?
    public let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn?
    public let getActiveSpace: GetActiveSpaceFn?
    public let spaceGetType: SpaceGetTypeFn?
    public let managedDisplayGetCurrentSpace: ManagedDisplayGetCurrentSpaceFn?
    public let copyManagedDisplayForWindow: CopyManagedDisplayForWindowFn?
    public let copyActiveMenuBarDisplayIdentifier: CopyActiveMenuBarDisplayIdentifierFn?
    public let copySpacesForWindows: CopySpacesForWindowsFn?
    public let moveWindowsToManagedSpace: MoveWindowsToManagedSpaceFn?
    public let spaceSetCompatID: SpaceSetCompatIDFn?
    public let setWindowListWorkspace: SetWindowListWorkspaceFn?
    public let managedDisplayIsAnimating: ManagedDisplayIsAnimatingFn?
    public let performBridgedOperation: PerformBridgedOperationFn?

    /// Connection ID cached at load time. Zero when SkyLight is absent.
    public let cid: Int32

    public static let frameworkPath =
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    private init() {
        let h = dlopen(SkyLight.frameworkPath, RTLD_LAZY)
        handle = h
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let h, let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        mainConnectionID = sym("SLSMainConnectionID", MainConnectionIDFn.self)
        copyManagedDisplaySpaces = sym("SLSCopyManagedDisplaySpaces", CopyManagedDisplaySpacesFn.self)
        getActiveSpace = sym("SLSGetActiveSpace", GetActiveSpaceFn.self)
        spaceGetType = sym("SLSSpaceGetType", SpaceGetTypeFn.self)
        managedDisplayGetCurrentSpace = sym("SLSManagedDisplayGetCurrentSpace", ManagedDisplayGetCurrentSpaceFn.self)
        copyManagedDisplayForWindow = sym("SLSCopyManagedDisplayForWindow", CopyManagedDisplayForWindowFn.self)
        copyActiveMenuBarDisplayIdentifier = sym("SLSCopyActiveMenuBarDisplayIdentifier", CopyActiveMenuBarDisplayIdentifierFn.self)
        copySpacesForWindows = sym("SLSCopySpacesForWindows", CopySpacesForWindowsFn.self)
        moveWindowsToManagedSpace = sym("SLSMoveWindowsToManagedSpace", MoveWindowsToManagedSpaceFn.self)
        spaceSetCompatID = sym("SLSSpaceSetCompatID", SpaceSetCompatIDFn.self)
        setWindowListWorkspace = sym("SLSSetWindowListWorkspace", SetWindowListWorkspaceFn.self)
        managedDisplayIsAnimating = sym("SLSManagedDisplayIsAnimating", ManagedDisplayIsAnimatingFn.self)
        performBridgedOperation = SkyLight.findLocalSymbol(
            "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP8NSObject",
            in: h
        ).map { unsafeBitCast($0, to: PerformBridgedOperationFn.self) }
        cid = mainConnectionID?() ?? 0
    }

    /// Finds a file-local symbol by walking `LC_SYMTAB` of the loaded image
    /// (yabai `macho_find_symbol`). Returns nil when the image or symbol is absent.
    /// The symbol name may be a prefix: the first match wins.
    static func findLocalSymbol(_ name: String, in handle: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        // TODO: walk mach headers of the SkyLight image and read the symbol table.
        return nil
    }
}

/// Private Accessibility function that maps an element to its `CGWindowID`.
/// Present on macOS 26.1 (dlsym-verified).
@_silgen_name("_AXUIElementGetWindow")
public func _AXUIElementGetWindow(_ element: AXUIElement, _ out: UnsafeMutablePointer<UInt32>) -> AXError
