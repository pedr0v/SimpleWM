import AppKit
import ApplicationServices
import LayoutEngine

/// One Accessibility window with its process.
public struct AXWindow {
    public let id: WindowID
    public let pid: pid_t
    public let element: AXUIElement
    public let bundleID: String?

    public init(id: WindowID, pid: pid_t, element: AXUIElement, bundleID: String?) {
        self.id = id
        self.pid = pid
        self.element = element
        self.bundleID = bundleID
    }

    /// Current frame in AX coordinates, from `kAXPositionAttribute` and `kAXSizeAttribute`.
    public var frame: Rect? {
        fatalError("TODO")
    }

    /// Writes size, then position, then size again. Returns the AX status of the
    /// last write. Apps with minimum sizes or grid snapping can refuse.
    @discardableResult
    public func setFrame(_ r: Rect) -> AXError {
        fatalError("TODO")
    }

    /// Sets `kAXMainAttribute`, performs `kAXRaiseAction`, then activates the app
    /// with `NSRunningApplication.activate`. Falls back to `_SLPSSetFrontProcessWithOptions`.
    public func focus() {
        fatalError("TODO")
    }

    /// True when all hold: subrole `AXStandardWindow`, not minimized,
    /// `AXFullScreen` false, position and size settable, on-screen at layer 0.
    public var isTileable: Bool {
        fatalError("TODO")
    }

    public var isMinimized: Bool { fatalError("TODO") }
    public var isFullscreen: Bool { fatalError("TODO") }
    public var subrole: String? { fatalError("TODO") }
}

/// Enumerates windows of regular apps and reads the focused window.
///
/// Each pid uses `AXUIElementSetMessagingTimeout(appElement, 1.0)`. AX lists
/// only windows on visible Spaces, so hidden-Space windows are absent.
@MainActor
public final class WindowEnumerator {
    /// Bundle IDs whose windows float (never tiled).
    public var floatingBundleIDs: Set<String>

    public init(floatingBundleIDs: Set<String> = []) {
        self.floatingBundleIDs = floatingBundleIDs
    }

    /// Tileable windows across all visible Spaces. Skips our own pid and
    /// apps outside `activationPolicy == .regular`.
    public func tileableWindows() -> [AXWindow] {
        fatalError("TODO")
    }

    /// Focused window of the frontmost app, or nil.
    public func focusedWindow() -> AXWindow? {
        fatalError("TODO")
    }

    /// Window IDs that `CGWindowListCopyWindowInfo` reports on screen at layer 0.
    public func onScreenLayerZeroIDs() -> Set<WindowID> {
        fatalError("TODO")
    }
}
