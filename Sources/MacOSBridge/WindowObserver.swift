import AppKit
import ApplicationServices
import LayoutEngine
import os

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

/// Weak link from an AX callback to its `WindowObserver`. The box lives
/// forever, so a late callback never reads freed memory.
private final class ObserverBox {
    weak var owner: WindowObserver?
}

/// `AXObserverCallback`. The run loop source is on the main run loop, so the
/// callback runs on the main thread.
private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let box = Unmanaged<ObserverBox>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated {
        box.owner?.handle(notification: name, element: element)
    }
}

/// Registers AX observers per app and NSWorkspace notifications.
///
/// App element notifications: `kAXWindowCreatedNotification`,
/// `kAXUIElementDestroyedNotification`, `kAXFocusedWindowChangedNotification`,
/// `kAXWindowMovedNotification`, `kAXWindowResizedNotification`,
/// `kAXWindowMiniaturizedNotification`, `kAXWindowDeminiaturizedNotification`.
/// Window element notifications: `kAXUIElementDestroyedNotification`,
/// `kAXWindowMiniaturizedNotification`, `kAXWindowDeminiaturizedNotification`,
/// `kAXMovedNotification`, `kAXResizedNotification`.
/// The observer adds window notifications by itself for each window of an
/// observed app and for each new window.
/// `.cannotComplete` (app not ready or not responding) causes up to 3
/// retries, 250 ms apart. After the last retry the pid rests for 30 s; then
/// the next `observe(pid:)` call tries again. Each AX call can block the main
/// thread for the 0.5 s messaging timeout.
/// `.notificationAlreadyRegistered` counts as success.
@MainActor
public final class WindowObserver {
    public var onEvent: ((WindowEvent) -> Void)?

    private struct AppEntry {
        let observer: AXObserver
        let app: AXUIElement
    }

    private struct WindowEntry {
        let pid: pid_t
        let element: AXUIElement
    }

    private static let appNotifications: [String] = [
        kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXFocusedWindowChangedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]

    private static let windowNotifications: [String] = [
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXMovedNotification,
        kAXResizedNotification,
    ]

    private static let maxRetries = 3
    private static let retryDelayNs: UInt64 = 250_000_000
    private static let cooldown: TimeInterval = 30

    private let log = Logger(subsystem: "com.simplewm.app", category: "observer")
    private let refcon: UnsafeMutableRawPointer
    private var apps: [pid_t: AppEntry] = [:]
    private var windows: [WindowID: WindowEntry] = [:]
    private var pendingRetry: Set<pid_t> = []
    /// Pids that failed every retry, with the time of the last failure.
    private var failedAt: [pid_t: Date] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var centerTokens: [NSObjectProtocol] = []
    /// Changes on `stop()`. Retries from an older generation do nothing.
    private var generation = 0

    public init() {
        let box = ObserverBox()
        refcon = Unmanaged.passRetained(box).toOpaque()
        box.owner = self
    }

    /// Starts NSWorkspace and screen observers and watches running apps.
    public func start() {
        guard workspaceTokens.isEmpty, centerTokens.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter

        func appObserver(_ name: Notification.Name, _ body: @escaping @MainActor (WindowObserver, pid_t) -> Void) -> NSObjectProtocol {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = app?.processIdentifier ?? 0
                MainActor.assumeIsolated {
                    guard let self, pid > 0 else { return }
                    body(self, pid)
                }
            }
        }

        workspaceTokens = [
            appObserver(NSWorkspace.didLaunchApplicationNotification) { me, pid in
                me.observe(pid: pid)
                me.onEvent?(.appLaunched(pid: pid))
            },
            appObserver(NSWorkspace.didTerminateApplicationNotification) { me, pid in
                me.remove(pid: pid)
                me.onEvent?(.appTerminated(pid: pid))
            },
            appObserver(NSWorkspace.didActivateApplicationNotification) { me, pid in
                // Catch-up path: apps that were not ready at launch.
                me.observe(pid: pid)
                me.onEvent?(.appActivated(pid: pid))
            },
            appObserver(NSWorkspace.didHideApplicationNotification) { me, pid in
                me.onEvent?(.appHidden(pid: pid))
            },
            appObserver(NSWorkspace.didUnhideApplicationNotification) { me, pid in
                me.onEvent?(.appUnhidden(pid: pid))
            },
            ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onEvent?(.activeSpaceChanged)
                }
            },
        ]
        centerTokens = [
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onEvent?(.screenParametersChanged)
                }
            },
        ]

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observe(pid: app.processIdentifier)
        }
    }

    /// Removes every observer.
    public func stop() {
        generation += 1
        let ws = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach { ws.removeObserver($0) }
        centerTokens.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceTokens.removeAll()
        centerTokens.removeAll()
        for pid in Array(apps.keys) { remove(pid: pid) }
        windows.removeAll()
        pendingRetry.removeAll()
        failedAt.removeAll()
    }

    /// Adds an AX observer for `pid`. Idempotent.
    ///
    /// Only apps with `activationPolicy == .regular` get an observer. The
    /// observer also registers window notifications for the current windows.
    public func observe(pid: pid_t) {
        attach(pid: pid, attempt: 0, generation: generation)
    }

    /// Adds window-level notifications for `window`. Idempotent.
    public func observe(window: AXWindow) {
        observe(pid: window.pid)
        attachWindow(window.element, pid: window.pid, id: window.id)
    }

    /// Drops observers of apps that no longer run.
    public func garbageCollect() {
        for pid in Array(apps.keys) where !Self.isRunning(pid) {
            remove(pid: pid)
        }
        windows = windows.filter { apps[$0.value.pid] != nil }
        failedAt = failedAt.filter { Self.isRunning($0.key) }
    }

    // MARK: Internals

    private static func isRunning(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }

    private func attach(pid: pid_t, attempt: Int, generation gen: Int) {
        guard gen == generation, pid > 0, pid != getpid(), apps[pid] == nil else { return }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.activationPolicy == .regular
        else { return }
        if attempt == 0 {
            if pendingRetry.contains(pid) { return }
            if let t = failedAt[pid], Date().timeIntervalSince(t) < Self.cooldown { return }
        }

        var created: AXObserver?
        let createStatus = AXObserverCreate(pid, axObserverCallback, &created)
        guard createStatus == .success, let observer = created else {
            log.debug("AXObserverCreate(\(pid)) failed: \(createStatus.rawValue)")
            scheduleRetry(pid: pid, attempt: attempt, generation: gen, when: createStatus == .cannotComplete)
            return
        }
        let appElement = AXHelper.appElement(pid)
        var registered: [String] = []
        var notReady = false
        for name in Self.appNotifications {
            let status = AXObserverAddNotification(observer, appElement, name as CFString, refcon)
            if status == .success || status == .notificationAlreadyRegistered {
                registered.append(name)
            } else if status == .cannotComplete {
                // One timeout means that the app does not answer now. Stop early.
                notReady = true
                break
            } else {
                log.debug("AX notification \(name, privacy: .public) unsupported by pid \(pid): \(status.rawValue)")
            }
        }
        if notReady && attempt < Self.maxRetries {
            // The app is not ready yet. Drop the partial set and retry.
            for name in registered {
                AXObserverRemoveNotification(observer, appElement, name as CFString)
            }
            scheduleRetry(pid: pid, attempt: attempt, generation: gen, when: true)
            return
        }
        guard !registered.isEmpty else {
            log.debug("No AX notification for pid \(pid)")
            pendingRetry.remove(pid)
            failedAt[pid] = Date()
            return
        }
        pendingRetry.remove(pid)
        failedAt.removeValue(forKey: pid)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        apps[pid] = AppEntry(observer: observer, app: appElement)

        for element in AXHelper.elements(appElement, kAXWindowsAttribute) {
            attachWindow(element, pid: pid, id: nil)
        }
    }

    private func scheduleRetry(pid: pid_t, attempt: Int, generation gen: Int, when condition: Bool) {
        guard condition, attempt < Self.maxRetries else {
            pendingRetry.remove(pid)
            failedAt[pid] = Date()
            return
        }
        pendingRetry.insert(pid)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.retryDelayNs)
            self?.attach(pid: pid, attempt: attempt + 1, generation: gen)
        }
    }

    private func remove(pid: pid_t) {
        pendingRetry.remove(pid)
        failedAt.removeValue(forKey: pid)
        windows = windows.filter { $0.value.pid != pid }
        guard let entry = apps.removeValue(forKey: pid) else { return }
        for name in Self.appNotifications {
            AXObserverRemoveNotification(entry.observer, entry.app, name as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(entry.observer), .commonModes)
    }

    /// Registers window notifications for one window element. Idempotent.
    private func attachWindow(_ element: AXUIElement, pid: pid_t, id: WindowID?) {
        guard let entry = apps[pid], let wid = id ?? AXHelper.windowID(element) else { return }
        if windows[wid] != nil { return }
        AXUIElementSetMessagingTimeout(element, AXHelper.appTimeout)
        var any = false
        for name in Self.windowNotifications {
            let status = AXObserverAddNotification(entry.observer, element, name as CFString, refcon)
            if status == .success || status == .notificationAlreadyRegistered { any = true }
        }
        if any { windows[wid] = WindowEntry(pid: pid, element: element) }
    }

    /// Finds the window ID of `element`: first the known window list, then
    /// `_AXUIElementGetWindow`.
    private func windowID(of element: AXUIElement, pid: pid_t) -> WindowID? {
        if let known = windows.first(where: { $0.value.pid == pid && CFEqual($0.value.element, element) }) {
            return known.key
        }
        return AXHelper.windowID(element)
    }

    /// Maps one AX notification to a `WindowEvent`.
    fileprivate func handle(notification name: String, element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        switch name {
        case kAXWindowCreatedNotification:
            attachWindow(element, pid: pid, id: nil)
            onEvent?(.windowCreated(pid: pid))
        case kAXFocusedWindowChangedNotification:
            onEvent?(.focusedWindowChanged(pid: pid))
        case kAXUIElementDestroyedNotification:
            // Ignore destroyed elements that are not windows (menus, sheets).
            guard let wid = windowID(of: element, pid: pid) else { return }
            windows.removeValue(forKey: wid)
            onEvent?(.windowDestroyed(wid))
        case kAXWindowMiniaturizedNotification:
            onEvent?(.windowMiniaturized(windowID(of: element, pid: pid)))
        case kAXWindowDeminiaturizedNotification:
            onEvent?(.windowDeminiaturized(windowID(of: element, pid: pid)))
        case kAXWindowMovedNotification, kAXMovedNotification:
            onEvent?(.windowMoved(windowID(of: element, pid: pid)))
        case kAXWindowResizedNotification, kAXResizedNotification:
            onEvent?(.windowResized(windowID(of: element, pid: pid)))
        default:
            break
        }
    }
}
