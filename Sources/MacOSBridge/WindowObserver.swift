import AppKit
import ApplicationServices
import LayoutEngine

/// Event that the observer reports. Every event triggers a debounced refresh.
public enum WindowEvent: Equatable, Sendable {
    case windowCreated(pid: pid_t)
    case windowDestroyed(WindowID?)
    case windowMiniaturized(WindowID?)
    case windowDeminiaturized(WindowID?)
    case windowMoved(WindowID?)
    case windowResized(WindowID?)
    case focusedWindowChanged(pid: pid_t)
    case appLaunched(pid: pid_t)
    case appTerminated(pid: pid_t)
    case appActivated(pid: pid_t)
    case appHidden(pid: pid_t)
    case appUnhidden(pid: pid_t)
    case activeSpaceChanged
    case screenParametersChanged
}

/// Registers AX observers per app and NSWorkspace notifications.
///
/// App element notifications: `kAXWindowCreatedNotification`,
/// `kAXFocusedWindowChangedNotification`.
/// Window element notifications: `kAXUIElementDestroyedNotification`,
/// `kAXWindowMiniaturizedNotification`, `kAXWindowDeminiaturizedNotification`,
/// `kAXMovedNotification`, `kAXResizedNotification`.
/// `.cannotComplete` during app launch is dropped; the next refresh retries.
/// `.notificationAlreadyRegistered` counts as success.
@MainActor
public final class WindowObserver {
    public var onEvent: ((WindowEvent) -> Void)?

    public init() {}

    /// Starts NSWorkspace and screen observers and watches running apps.
    public func start() {
        fatalError("TODO")
    }

    /// Removes every observer.
    public func stop() {
        fatalError("TODO")
    }

    /// Adds an AX observer for `pid`. Idempotent.
    public func observe(pid: pid_t) {
        fatalError("TODO")
    }

    /// Adds window-level notifications for `window`. Idempotent.
    public func observe(window: AXWindow) {
        fatalError("TODO")
    }

    /// Drops observers of apps that no longer run.
    public func garbageCollect() {
        fatalError("TODO")
    }
}
