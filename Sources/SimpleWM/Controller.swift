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
///
/// Tiling runs only when all hold: the controller is enabled, the
/// Accessibility grant exists, and AeroSpace does not run. Space switching
/// runs while the controller is enabled, also while AeroSpace runs.
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

    /// Bundle ID of AeroSpace. The app refuses to tile while it runs.
    public static let aerospaceBundleID = "bobko.aerospace"

    /// Called when `enabled`, `warning`, or `statusText` can have changed.
    public var onStatusChange: (() -> Void)?

    /// True after a Space switch or a window move failed. A later success clears it.
    public private(set) var lastSwitchFailed: Bool = false

    /// True while AeroSpace runs. The timer and app events update it.
    public private(set) var aerospaceRunning: Bool = false

    /// True when the menu bar must show the warning mark.
    public var warning: Bool { lastSwitchFailed || aerospaceRunning }

    /// True when the controller must not change window frames.
    /// The environment variable `SIMPLEWM_DRY_RUN=1` sets it at launch.
    /// Hotkeys, observers, and logs still run.
    public var dryRun: Bool = false

    /// True when the controller may change window frames now.
    public var tilingActive: Bool {
        enabled && !dryRun && !aerospaceRunning && Permissions.isAccessibilityTrusted()
    }

    /// Short reason text for the menu, or nil when all is well.
    public var statusText: String? {
        if !Permissions.isAccessibilityTrusted() { return "Accessibility not granted" }
        if aerospaceRunning { return "AeroSpace is running: tiling is off" }
        if lastSwitchFailed { return "Last Space switch or move failed" }
        if !enabled { return "Disabled" }
        return nil
    }

    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    /// AX windows from the last refresh, by ID.
    private var windowCache: [WindowID: AXWindow] = [:]
    private var warnedSharedSpaces = false

    /// Builds a controller with the production services.
    public static func makeDefault(config: Config) -> WMController {
        let gesture = GestureSwitch(warpCursor: config.spaceSwitch.warpCursor)
        let ctrlN = ControlKeySwitch()
        let switches: [SpaceSwitchStrategy]
        switch config.spaceSwitch.strategy.lowercased() {
        case "gesture": switches = [gesture]
        case "ctrl-n": switches = [ctrlN]
        default: switches = [gesture, ctrlN]
        }
        return WMController(config: config,
                     spaceManager: SpaceManager(
                        switchStrategies: switches,
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

    // MARK: - Lifecycle

    /// Registers hotkeys, starts observers, runs the first refresh.
    /// Refuses to start while AeroSpace (`bobko.aerospace`) runs.
    ///
    /// While AeroSpace runs, the hotkeys stay registered and Space switching
    /// works. Tiling starts on the first refresh after AeroSpace quits.
    public func start() {
        guard !enabled else { return }
        enabled = true
        lastSwitchFailed = false
        updateAeroSpaceState(notify: false)
        if aerospaceRunning {
            log.warning("AeroSpace runs. Tiling stays off until it quits.")
        }
        if !displayManager.screensHaveSeparateSpaces {
            log.warning("Displays share one Space list. Only the focused display tiles.")
        }

        registerBindings()

        observer.onEvent = { [weak self] event in
            self?.handle(event)
        }
        observer.start()
        displayManager.onChange = { [weak self] in
            self?.scheduleRefresh()
        }
        spaceManager.onSpaceChange = { [weak self] in
            self?.scheduleRefresh()
        }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }

        log.info("Started with \(self.hotkeys.bound.count, privacy: .public) hotkeys.")
        refresh()
        onStatusChange?()
    }

    /// Unregisters hotkeys and stops observers. Leaves window frames as they are.
    public func stop() {
        guard enabled else { return }
        enabled = false
        hotkeys.unbindAll()
        observer.stop()
        observer.onEvent = nil
        displayManager.onChange = nil
        spaceManager.onSpaceChange = nil
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        windowCache = [:]
        log.info("Stopped.")
        onStatusChange?()
    }

    /// Reloads config from disk, then restarts when enabled.
    ///
    /// A bad file keeps the last good config. A change of
    /// `spaceSwitch.strategy` takes effect after an app restart.
    public func reloadConfig() {
        let next: Config
        do {
            next = try Config.load()
        } catch {
            log.error("Config reload failed. The last good config stays: \(String(describing: error), privacy: .public)")
            return
        }
        if next.spaceSwitch.strategy != config.spaceSwitch.strategy {
            log.notice("The new spaceSwitch.strategy applies after a restart.")
        }
        config = next
        enumerator.floatingBundleIDs = Set(next.floatingApps)
        for case let gesture as GestureSwitch in spaceManager.switchStrategies {
            gesture.warpCursor = next.spaceSwitch.warpCursor
        }
        log.info("Config reloaded.")
        if enabled {
            stop()
            start()
        } else {
            onStatusChange?()
        }
    }

    // MARK: - Refresh

    /// Debounced refresh request.
    public func scheduleRefresh() {
        guard enabled else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            if NSEvent.pressedMouseButtons & 0x1 != 0 {
                // The user drags or resizes a window. Wait for the mouse up.
                self.scheduleRefresh()
                return
            }
            self.refresh()
        }
    }

    /// Full reconcile and layout pass. See type doc.
    public func refresh() {
        guard tilingActive else { return }
        let displays = spaceManager.displays()
        guard !displays.isEmpty else {
            log.debug("No display snapshot. SkyLight can be absent. Refresh skipped.")
            return
        }

        // Trees of deleted Spaces disappear. Trees of hidden Spaces stay.
        var live = Set<SpaceKey>()
        for d in displays {
            for s in d.spaces { live.insert(SpaceKey(display: d.id, space: s.id)) }
        }
        state.prune(live: live)

        let windows = enumerator.tileableWindows()
        windowCache = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for w in windows { observer.observe(window: w) }
        let focused = enumerator.focusedWindow()

        var targets = displays
        if !displayManager.screensHaveSeparateSpaces, displays.count > 1,
           let fd = focusedDisplay(in: displays) {
            targets = [fd]
        }

        let byDisplay = group(windows, by: displays)
        for d in targets {
            guard d.current.isUser else { continue }
            let key = SpaceKey(display: d.id, space: d.current.id)
            let ids = (byDisplay[d.id] ?? []).map(\.id)
            reconcile(key, present: ids, workArea: d.workArea)
            if let f = focused, ids.contains(f.id) {
                state.update(key) { $0.setFocus(f.id) }
            }
            applyLayout(key, on: d)
        }
    }

    /// Makes the tree for `key` match `present`. A window that now lives
    /// here leaves every other tree.
    private func reconcile(_ key: SpaceKey, present: [WindowID], workArea: Rect) {
        if state.trees[key] == nil {
            state.trees[key] = TilingTree(root: config.rootOrientation(for: workArea))
        }
        let here = Set(present)
        for (other, tree) in state.trees where other != key {
            let stale = tree.windows.filter { here.contains($0) }
            guard !stale.isEmpty else { continue }
            state.update(other) { t in stale.forEach { t.remove($0) } }
        }
        state.update(key) { $0.reconcile(present: present) }
    }

    /// Computes frames for the tree of `key` and writes the frames that
    /// differ by more than 2 pt.
    private func applyLayout(_ key: SpaceKey, on display: DisplaySnapshot) {
        guard let tree = state.trees[key] else { return }
        let frames = tree.layout(in: display.workArea, gaps: config.gaps)
        for (id, rect) in frames {
            guard let w = windowCache[id] else { continue }
            if let current = w.frame, current.isClose(to: rect, tolerance: 2) { continue }
            let status = w.setFrame(rect)
            if status != .success {
                log.debug("Frame write for \(id.description, privacy: .public) returned \(status.rawValue, privacy: .public).")
            }
        }
    }

    /// Splits windows by display. The SkyLight display comes first. The
    /// frame center is the fallback.
    private func group(_ windows: [AXWindow], by displays: [DisplaySnapshot]) -> [DisplayID: [AXWindow]] {
        var result: [DisplayID: [AXWindow]] = [:]
        let ids = Set(displays.map(\.id))
        for w in windows {
            if let d = displayID(of: w, displays: displays, known: ids) {
                result[d, default: []].append(w)
            }
        }
        return result
    }

    private func displayID(of w: AXWindow, displays: [DisplaySnapshot], known: Set<DisplayID>) -> DisplayID? {
        if displays.count == 1 { return displays[0].id }
        if let d = spaceManager.display(of: w.id), known.contains(d) { return d }
        guard let f = w.frame else { return nil }
        return displays.first { $0.frame.contains(x: f.midX, y: f.midY) }?.id
    }

    // MARK: - Events

    private func handle(_ event: WindowEvent) {
        switch event {
        case .focusedWindowChanged, .appActivated:
            if tilingActive, let f = enumerator.focusedWindow(), let key = state.key(of: f.id) {
                state.update(key) { $0.setFocus(f.id) }
            }
        case .appLaunched, .appTerminated:
            updateAeroSpaceState(notify: true)
        default:
            break
        }
        scheduleRefresh()
    }

    private func tick() {
        updateAeroSpaceState(notify: true)
        observer.garbageCollect()
        scheduleRefresh()
    }

    private func updateAeroSpaceState(notify: Bool) {
        let running = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == WMController.aerospaceBundleID }
        guard running != aerospaceRunning else { return }
        aerospaceRunning = running
        if running {
            log.warning("AeroSpace started. Tiling stops.")
        } else {
            log.info("AeroSpace quit. Tiling resumes.")
        }
        if notify { onStatusChange?() }
    }

    // MARK: - Bindings

    private func registerBindings() {
        hotkeys.unbindAll()
        for (chordText, commandText) in config.bindings.sorted(by: { $0.key < $1.key }) {
            if commandText.lowercased() == "none" { continue }
            guard let chord = KeyChord(chordText) else {
                log.error("Unknown key chord \(chordText, privacy: .public). Binding skipped.")
                continue
            }
            guard let command = Command.parse(commandText) else {
                log.error("Unknown command \(commandText, privacy: .public) for \(chordText, privacy: .public). Binding skipped.")
                continue
            }
            let status = hotkeys.bind(chord) { [weak self] in
                self?.run(command)
            }
            if status == -9878 {
                log.error("Another process owns \(chordText, privacy: .public) (status -9878).")
            } else if status != noErr {
                log.error("Hotkey \(chordText, privacy: .public) failed with status \(status, privacy: .public).")
            }
        }
    }

    // MARK: - Commands

    /// Runs one user command.
    public func run(_ command: Command) {
        guard enabled else { return }
        switch command {
        case .gotoSpace(let n):
            gotoSpace(n)
        case .moveToSpace(let n):
            moveToSpace(n)
        case .focus(let d):
            focus(d)
        case .move(let d):
            move(d)
        case .toggleFullscreen:
            mutateFocusedTree { tree in tree.toggleZoom() }
            if let z = focusedContext()?.tree.zoomed { windowCache[z]?.focus() }
        case .toggleSplit:
            mutateFocusedTree { $0.toggleSplit() }
        case .split(let o):
            mutateFocusedTree { $0.split(o) }
        case .balance:
            mutateFocusedTree { $0.balance() }
        case .resize(let delta):
            mutateFocusedTree { $0.resize(delta: delta) }
        }
    }

    private func gotoSpace(_ n: Int) {
        guard let d = focusedDisplay() else {
            log.error("space \(n, privacy: .public): no display found.")
            return
        }
        let user = d.userSpaces
        guard n >= 1, n <= user.count else {
            log.info("space \(n, privacy: .public): the display has \(user.count, privacy: .public) Spaces.")
            return
        }
        if user[n - 1].id == d.current.id { return }
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.spaceManager.switchTo(userSpace: n, on: d)
            self.recordSpaceSwitch(ok, what: "space \(n)")
            self.scheduleRefresh()
        }
    }

    private func moveToSpace(_ n: Int) {
        guard let w = enumerator.focusedWindow() else {
            log.info("move-to-space \(n, privacy: .public): no focused window.")
            return
        }
        let displays = spaceManager.displays()
        let known = Set(displays.map(\.id))
        guard let did = displayID(of: w, displays: displays, known: known)
                ?? focusedDisplay(in: displays)?.id,
              let d = displays.first(where: { $0.id == did }) else {
            log.error("move-to-space \(n, privacy: .public): no display for the window.")
            return
        }
        let user = d.userSpaces
        guard n >= 1, n <= user.count else {
            log.info("move-to-space \(n, privacy: .public): the display has \(user.count, privacy: .public) Spaces.")
            return
        }
        let target = user[n - 1]
        guard target.id != d.current.id else { return }
        let from = state.key(of: w.id) ?? SpaceKey(display: d.id, space: d.current.id)
        let to = SpaceKey(display: d.id, space: target.id)
        let follow = config.followOnMove

        Task { [weak self] in
            guard let self else { return }
            let ok = await self.spaceManager.move(w.id, toUserSpace: n, on: d)
            self.recordSwitch(ok, what: "move-to-space \(n)")
            guard ok else { return }
            if self.tilingActive {
                if self.state.trees[to] == nil {
                    self.state.trees[to] = TilingTree(root: self.config.rootOrientation(for: d.workArea))
                }
                self.state.transfer(w.id, from: from, to: to)
            }
            if follow {
                let switched = await self.spaceManager.switchTo(userSpace: n, on: d)
                self.recordSpaceSwitch(switched, what: "space \(n)")
                if switched { w.focus() }
            } else if self.tilingActive, let next = self.state.trees[from]?.focused {
                self.windowCache[next]?.focus()
            }
            self.scheduleRefresh()
        }
    }

    /// Records a Space switch result. Only the outcome `.failed` counts as a failure.
    /// A superseded request or an out-of-range N changes nothing.
    private func recordSpaceSwitch(_ ok: Bool, what: String) {
        if ok { recordSwitch(true, what: what); return }
        switch spaceManager.lastSwitchOutcome {
        case .superseded?, .outOfRange?, .alreadyCurrent?:
            log.debug("\(what, privacy: .public): no switch (\(String(describing: self.spaceManager.lastSwitchOutcome), privacy: .public)).")
        default:
            recordSwitch(false, what: what)
        }
    }

    private func recordSwitch(_ ok: Bool, what: String) {
        if !ok { log.error("\(what, privacy: .public) failed. No strategy verified.") }
        if lastSwitchFailed != !ok {
            lastSwitchFailed = !ok
            onStatusChange?()
        }
    }

    /// Focused window, its display, and its tree key. Syncs the tree first.
    private struct FocusContext {
        let window: AXWindow?
        let display: DisplaySnapshot
        let key: SpaceKey
        let tree: TilingTree
    }

    private func focusedContext() -> FocusContext? {
        let displays = spaceManager.displays()
        guard let d = focusedDisplay(in: displays), d.current.isUser else { return nil }
        let key = SpaceKey(display: d.id, space: d.current.id)
        guard let tree = state.trees[key] else { return nil }
        let w = enumerator.focusedWindow().flatMap { tree.contains($0.id) ? $0 : nil }
        return FocusContext(window: w, display: d, key: key, tree: tree)
    }

    /// Syncs state, mutates the focused tree, and applies its layout.
    private func mutateFocusedTree(_ body: (inout TilingTree) -> Void) {
        guard tilingActive else { return }
        refresh()
        guard let ctx = focusedContext() else { return }
        if let w = ctx.window { state.update(ctx.key) { $0.setFocus(w.id) } }
        state.update(ctx.key, body)
        applyLayout(ctx.key, on: ctx.display)
    }

    private func focus(_ dir: Direction) {
        guard tilingActive else { return }
        refresh()
        guard let ctx = focusedContext() else {
            focusNeighborDisplay(dir, from: focusedDisplay())
            return
        }
        if let w = ctx.window { state.update(ctx.key) { $0.setFocus(w.id) } }
        if let next = state.tree(for: ctx.key).neighbor(dir) {
            state.update(ctx.key) { $0.setFocus(next) }
            applyLayout(ctx.key, on: ctx.display)
            windowCache[next]?.focus()
        } else {
            focusNeighborDisplay(dir, from: ctx.display)
        }
    }

    private func focusNeighborDisplay(_ dir: Direction, from current: DisplaySnapshot?) {
        guard let current else { return }
        let displays = spaceManager.displays()
        guard let target = neighborDisplay(of: current, dir, in: displays) else { return }
        let key = SpaceKey(display: target.id, space: target.current.id)
        let tree = state.tree(for: key)
        guard let id = tree.focused ?? tree.windows.first, let w = windowCache[id] else {
            log.debug("focus \(dir.rawValue, privacy: .public): the next display has no window.")
            return
        }
        state.update(key) { $0.setFocus(id) }
        w.focus()
    }

    private func move(_ dir: Direction) {
        guard tilingActive else { return }
        refresh()
        guard let ctx = focusedContext(), let w = ctx.window else { return }
        state.update(ctx.key) { $0.setFocus(w.id) }
        var moved = false
        state.update(ctx.key) { moved = $0.moveFocused(dir) }
        if moved {
            applyLayout(ctx.key, on: ctx.display)
            return
        }

        // Root edge: move the window to the next display in `dir`.
        let displays = spaceManager.displays()
        guard let target = neighborDisplay(of: ctx.display, dir, in: displays),
              target.current.isUser else { return }
        let to = SpaceKey(display: target.id, space: target.current.id)
        if state.trees[to] == nil {
            state.trees[to] = TilingTree(root: config.rootOrientation(for: target.workArea))
        }
        state.transfer(w.id, from: ctx.key, to: to)
        applyLayout(ctx.key, on: ctx.display)
        applyLayout(to, on: target)
        w.focus()
        scheduleRefresh()
    }

    /// Nearest display whose center lies in direction `dir` from `current`.
    private func neighborDisplay(of current: DisplaySnapshot, _ dir: Direction,
                                 in displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        let cx = current.frame.midX, cy = current.frame.midY
        let candidates = displays.filter { d in
            guard d.id != current.id else { return false }
            let dx = d.frame.midX - cx, dy = d.frame.midY - cy
            switch dir {
            case .left: return dx < 0 && abs(dx) >= abs(dy) / 2
            case .right: return dx > 0 && abs(dx) >= abs(dy) / 2
            case .up: return dy < 0 && abs(dy) >= abs(dx) / 2
            case .down: return dy > 0 && abs(dy) >= abs(dx) / 2
            }
        }
        return candidates.min { a, b in
            score(a, cx, cy, dir) < score(b, cx, cy, dir)
        }
    }

    private func score(_ d: DisplaySnapshot, _ cx: Double, _ cy: Double, _ dir: Direction) -> Double {
        let dx = abs(d.frame.midX - cx), dy = abs(d.frame.midY - cy)
        return dir.orientation == .horizontal ? dx + 2 * dy : dy + 2 * dx
    }

    // MARK: - Focused display

    /// Display that holds keyboard focus: focused window display, then active
    /// menu bar display, then display under the mouse.
    public func focusedDisplay() -> DisplaySnapshot? {
        focusedDisplay(in: spaceManager.displays())
    }

    private func focusedDisplay(in displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        guard !displays.isEmpty else { return nil }
        if displays.count == 1 { return displays[0] }
        let known = Set(displays.map(\.id))

        if Permissions.isAccessibilityTrusted(), let w = enumerator.focusedWindow(),
           let id = displayID(of: w, displays: displays, known: known),
           let d = displays.first(where: { $0.id == id }) {
            return d
        }
        if let id = spaceManager.activeMenuBarDisplay(),
           let d = displays.first(where: { $0.id == id }) {
            return d
        }
        if let info = displayManager.displayUnderMouse(),
           let d = displays.first(where: { $0.id == info.id }) {
            return d
        }
        // Last fallback: convert the AppKit mouse point to AX coordinates.
        let p = NSEvent.mouseLocation
        let mainHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0
        let ax = (x: Double(p.x), y: Double(mainHeight - p.y))
        return displays.first { $0.frame.contains(x: ax.x, y: ax.y) } ?? displays.first
    }
}
