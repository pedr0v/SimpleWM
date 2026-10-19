import AppKit
import ApplicationServices
import LayoutEngine
import os

/// AX attribute names that the SDK does not export as Swift constants.
enum AXNames {
    static let fullScreen = "AXFullScreen"
    static let enhancedUserInterface = "AXEnhancedUserInterface"
}

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
        guard let pos = AXHelper.point(element, kAXPositionAttribute),
              let size = AXHelper.size(element, kAXSizeAttribute)
        else { return nil }
        return Rect(x: Double(pos.x), y: Double(pos.y), w: Double(size.width), h: Double(size.height))
    }

    /// Writes size, then position, then size again. Returns the AX status of the
    /// last write. Apps with minimum sizes or grid snapping can refuse.
    ///
    /// When the app has `AXEnhancedUserInterface` on, the function turns it off
    /// for the writes and then restores it. This stops animated resizes.
    @discardableResult
    public func setFrame(_ r: Rect) -> AXError {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AXHelper.appTimeout)
        let enhanced = AXHelper.bool(app, AXNames.enhancedUserInterface) == true
        if enhanced {
            AXUIElementSetAttributeValue(app, AXNames.enhancedUserInterface as CFString, kCFBooleanFalse)
        }
        defer {
            if enhanced {
                AXUIElementSetAttributeValue(app, AXNames.enhancedUserInterface as CFString, kCFBooleanTrue)
            }
        }
        var size = CGSize(width: r.w, height: r.h)
        var origin = CGPoint(x: r.x, y: r.y)
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let originValue = AXValueCreate(.cgPoint, &origin)
        else { return .failure }
        _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, originValue)
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
    }

    /// Sets `kAXMainAttribute`, performs `kAXRaiseAction`, then activates the app
    /// with `NSRunningApplication.activate`. Then it calls
    /// `_SLPSSetFrontProcessWithOptions` when the symbol exists, because
    /// cooperative activation (macOS 14+) can refuse a background caller.
    public func focus() {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        let app = NSRunningApplication(processIdentifier: pid)
        _ = app?.activate()
        let sl = SkyLight.shared
        if let setFront = sl.setFrontProcessWithOptions, let getPSN = sl.getProcessForPID {
            var psn = ProcessSerialNumber()
            if getPSN(pid, &psn) == noErr {
                // 0x200 = kCPSUserGenerated.
                _ = setFront(&psn, id.raw, 0x200)
            }
        }
    }

    /// True when all hold: subrole `AXStandardWindow`, not minimized,
    /// `AXFullScreen` false, position and size settable, on-screen at layer 0.
    /// Windows of this process never qualify.
    public var isTileable: Bool {
        guard isTileableByAX else { return false }
        return WindowEnumerator.isOnScreenLayerZero(id)
    }

    /// The AX part of `isTileable`. `WindowEnumerator` checks the
    /// on-screen part once for all windows.
    var isTileableByAX: Bool {
        guard pid != getpid(), id.raw != 0 else { return false }
        guard subrole == (kAXStandardWindowSubrole as String) else { return false }
        guard !isMinimized, !isFullscreen else { return false }
        return AXHelper.isSettable(element, kAXPositionAttribute)
            && AXHelper.isSettable(element, kAXSizeAttribute)
    }

    public var isMinimized: Bool { AXHelper.bool(element, kAXMinimizedAttribute) ?? false }
    public var isFullscreen: Bool { AXHelper.bool(element, AXNames.fullScreen) ?? false }
    public var subrole: String? { AXHelper.string(element, kAXSubroleAttribute) }
}

/// Small typed readers for AX attributes.
enum AXHelper {
    /// Messaging timeout per app element, in seconds.
    static let appTimeout: Float = 0.5

    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        // CFBoolean bridges to NSNumber.
        (copy(element, attribute) as? NSNumber)?.boolValue
    }

    static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let v = copy(element, attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let v = axValue(element, attribute) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let v = axValue(element, attribute) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = copy(element, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let v = copy(element, attribute), let array = v as? [AnyObject] else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    /// `CGWindowID` of a window element, or nil.
    static func windowID(_ element: AXUIElement) -> WindowID? {
        var wid: UInt32 = 0
        guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { return nil }
        return WindowID(wid)
    }

    /// Application element with the short messaging timeout.
    static func appElement(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, appTimeout)
        return app
    }
}

/// Enumerates windows of regular apps and reads the focused window.
///
/// Each pid uses `AXUIElementSetMessagingTimeout(appElement, 0.5)`. AX lists
/// only windows on visible Spaces, so hidden-Space windows are absent.
@MainActor
public final class WindowEnumerator {
    /// Bundle IDs whose windows float (never tiled).
    public var floatingBundleIDs: Set<String>

    private let log = Logger(subsystem: "com.simplewm.app", category: "windows")

    public init(floatingBundleIDs: Set<String> = []) {
        self.floatingBundleIDs = floatingBundleIDs
        // Global default for elements without their own timeout (default is 6 s).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
    }

    /// Tileable windows across all visible Spaces. Skips our own pid and
    /// apps outside `activationPolicy == .regular`.
    ///
    /// Only windows that `CGWindowListCopyWindowInfo` reports on screen at
    /// layer 0 qualify. Apps without such a window get no AX call.
    public func tileableWindows() -> [AXWindow] {
        let onScreen = Self.onScreenLayerZero()
        guard !onScreen.ids.isEmpty else { return [] }
        let me = getpid()
        var result: [AXWindow] = []
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid != me, pid > 0, !app.isTerminated,
                  app.activationPolicy == .regular,
                  onScreen.pids.contains(pid)
            else { continue }
            let bundleID = app.bundleIdentifier
            if let bundleID, floatingBundleIDs.contains(bundleID) { continue }
            let appElement = AXHelper.appElement(pid)
            for element in AXHelper.elements(appElement, kAXWindowsAttribute) {
                guard let wid = AXHelper.windowID(element), onScreen.ids.contains(wid) else { continue }
                AXUIElementSetMessagingTimeout(element, AXHelper.appTimeout)
                let window = AXWindow(id: wid, pid: pid, element: element, bundleID: bundleID)
                if window.isTileableByAX { result.append(window) }
            }
        }
        return result
    }

    /// Focused window of the frontmost app, or nil.
    public func focusedWindow() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard pid != getpid(), pid > 0 else { return nil }
        let appElement = AXHelper.appElement(pid)
        guard let element = AXHelper.element(appElement, kAXFocusedWindowAttribute),
              let wid = AXHelper.windowID(element)
        else { return nil }
        AXUIElementSetMessagingTimeout(element, AXHelper.appTimeout)
        return AXWindow(id: wid, pid: pid, element: element, bundleID: app.bundleIdentifier)
    }

    /// Window IDs that `CGWindowListCopyWindowInfo` reports on screen at layer 0.
    public func onScreenLayerZeroIDs() -> Set<WindowID> {
        Self.onScreenLayerZero().ids
    }

    /// On-screen layer-0 window IDs and their owner pids.
    nonisolated static func onScreenLayerZero() -> (ids: Set<WindowID>, pids: Set<pid_t>) {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return ([], [])
        }
        var ids = Set<WindowID>()
        var pids = Set<pid_t>()
        for info in list {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber
            else { continue }
            ids.insert(WindowID(number.uint32Value))
            if let owner = info[kCGWindowOwnerPID as String] as? NSNumber {
                pids.insert(pid_t(owner.int32Value))
            }
        }
        return (ids, pids)
    }

    /// True when `CGWindowListCopyWindowInfo(.optionIncludingWindow)` reports
    /// `w` on screen at layer 0.
    nonisolated static func isOnScreenLayerZero(_ w: WindowID) -> Bool {
        guard w.raw != 0,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], w.raw) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == w.raw })
        else { return false }
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
        let onScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        return layer == 0 && onScreen
    }
}
