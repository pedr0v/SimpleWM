import AppKit
import LayoutEngine
import MacOSBridge
import os

/// Owns the engine state, the bridge services, and the config.
///
/// Event flow:
/// 1. `WindowObserver`, `DisplayManager`, `SpaceManager`, and a 2 s timer call `scheduleRefresh()`.
/// 2. `scheduleRefresh()` debounces 40 ms and waits while the left mouse button is down.
/// 3. `refresh()` reads displays, skips displays whose current Space is type 4,
///    collects tileable windows per display, reconciles each tree, computes
///    frames, and writes only frames that differ by more than 2 pt.
/// 4. Commands mutate the tree, then call `applyLayout()`.
@MainActor
public final class WMController {
    public let log = Logger(subsystem: "com.simplewm.app", category: "controller")

    public private(set) var config: Config
    public private(set) var state: WMState
    public private(set) var enabled: Bool = false

    public let spaceManager: SpaceManager
    public let displayManager: DisplayManager
    public let enumerator: WindowEnumerator
    public let observer: WindowObserver
    public let hotkeys: HotkeyManager

    /// Builds a controller with the production services.
    public static func makeDefault(config: Config) -> WMController {
        WMController(config: config,
                     spaceManager: SpaceManager(
                        switchStrategies: [GestureSwitch(warpCursor: config.spaceSwitch.warpCursor), ControlKeySwitch()],
                        moveStrategies: [BridgedMove(), CompatIDMove(), ManagedSpaceMove()]),
                     displayManager: DisplayManager(),
                     enumerator: WindowEnumerator(floatingBundleIDs: Set(config.floatingApps)),
                     observer: WindowObserver(),
                     hotkeys: HotkeyManager())
    }

    public init(config: Config,
                spaceManager: SpaceManager,
                displayManager: DisplayManager,
                enumerator: WindowEnumerator,
                observer: WindowObserver,
                hotkeys: HotkeyManager) {
        self.config = config
        self.state = WMState()
        self.spaceManager = spaceManager
        self.displayManager = displayManager
        self.enumerator = enumerator
        self.observer = observer
        self.hotkeys = hotkeys
    }

    /// Registers hotkeys, starts observers, runs the first refresh.
    /// Refuses to start while AeroSpace (`bobko.aerospace`) runs.
    public func start() {
        fatalError("TODO")
    }

    /// Unregisters hotkeys and stops observers. Leaves window frames as they are.
    public func stop() {
        fatalError("TODO")
    }

    /// Reloads config from disk, then restarts when enabled.
    public func reloadConfig() {
        fatalError("TODO")
    }

    /// Debounced refresh request.
    public func scheduleRefresh() {
        fatalError("TODO")
    }

    /// Full reconcile and layout pass. See type doc.
    public func refresh() {
        fatalError("TODO")
    }

    /// Runs one user command.
    public func run(_ command: Command) {
        fatalError("TODO")
    }

    /// Display that holds keyboard focus: focused window display, then active
    /// menu bar display, then display under the mouse.
    public func focusedDisplay() -> DisplaySnapshot? {
        fatalError("TODO")
    }
}
