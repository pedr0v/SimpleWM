import AppKit
import LayoutEngine
import MacOSBridge
import os

/// Wires the config, the controller, the menu bar, and the updater.
///
/// Startup:
/// 1. Write the default config when the file is absent. Load the config.
/// 2. Build the controller and install the menu bar.
/// 3. Start the updater. It probes for a new release 10 s later and every 24 h.
///    The menu shows "Update (vX.Y.Z)" when a release is newer.
/// 4. Check the Accessibility grant. Without it, show the system prompt and
///    poll every 2 s. Start the controller when the grant arrives.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.simplewm.app", category: "app")
    private var controller: WMController!
    private let menuBar = MenuBar()
    private let updater = Updater()
    private var permissionTimer: Timer?
    /// False after the user disables the app in the menu.
    private var wantsEnabled = true

    /// Handles SIGTERM and SIGINT on the main queue.
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        let dryRun = ProcessInfo.processInfo.environment["SIMPLEWM_DRY_RUN"] == "1"
        let config = Self.loadInitialConfig(log: log)
        controller = WMController.makeDefault(config: config)
        controller.dryRun = dryRun
        if dryRun {
            log.notice("Dry run: the app does not change window frames.")
        }
        logStartupDiagnostics()
        controller.onStatusChange = { [weak self] in
            self?.updateMenu()
        }

        menuBar.onToggleEnabled = { [weak self] in self?.toggleEnabled() }
        menuBar.onOpenConfig = { [weak self] in self?.openConfig() }
        menuBar.onReloadConfig = { [weak self] in self?.reloadConfig() }
        menuBar.install()
        updateMenu()

        // The updater runs only inside the app bundle. `.build/debug/SimpleWM` has no update item.
        updater.onAvailableUpdate = { [weak self] version in
            self?.menuBar.setAvailableUpdate(version: version)
        }
        updater.start()
        if updater.isRunning {
            menuBar.onCheckForUpdates = { [weak self] in self?.updater.checkForUpdates() }
        }

        // A dry run never shows the system Accessibility prompt.
        startWhenTrusted(prompt: !dryRun)
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        controller?.stop()
        log.notice("SimpleWM quits. Bound hotkeys left: \(self.controller?.hotkeys.bound.count ?? 0, privacy: .public)")
    }

    // MARK: - Startup diagnostics

    /// Logs the displays, the Spaces, and the Accessibility grant.
    /// This function only reads state. It never switches a Space.
    private func logStartupDiagnostics() {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        log.notice("SimpleWM starts. pid \(ProcessInfo.processInfo.processIdentifier, privacy: .public), macOS \(version, privacy: .public)")
        let trusted = Permissions.isAccessibilityTrusted()
        log.notice("Accessibility granted: \(trusted, privacy: .public)")
        log.notice("Displays have separate Spaces: \(self.controller.displayManager.screensHaveSeparateSpaces, privacy: .public)")

        let screens = controller.displayManager.displays()
        log.notice("Screens (AppKit): \(screens.count, privacy: .public)")
        let snapshots = controller.spaceManager.displays()
        if snapshots.isEmpty {
            log.warning("No Space snapshot. SkyLight can be absent. Space switching is off.")
        }
        log.notice("Displays (SkyLight): \(snapshots.count, privacy: .public)")
        for (i, d) in snapshots.enumerated() {
            let f = d.frame
            log.notice("Display \(i + 1, privacy: .public): uuid \(d.id.uuid, privacy: .public), cgID \(d.cgID, privacy: .public), frame (\(Int(f.x), privacy: .public), \(Int(f.y), privacy: .public), \(Int(f.w), privacy: .public), \(Int(f.h), privacy: .public)), current Space \(d.current.id.raw, privacy: .public) type \(d.current.type, privacy: .public), user Spaces \(d.userSpaces.count, privacy: .public) of \(d.spaces.count, privacy: .public)")
        }

        let switches = controller.spaceManager.switchStrategies
            .map { "\($0.name)=\($0.isAvailable())" }.joined(separator: ", ")
        let moves = controller.spaceManager.moveStrategies
            .map { "\($0.name)=\($0.isAvailable())" }.joined(separator: ", ")
        log.notice("Switch strategies: \(switches, privacy: .public)")
        log.notice("Move strategies: \(moves, privacy: .public)")

        let aerospace = !NSRunningApplication
            .runningApplications(withBundleIdentifier: WMController.aerospaceBundleID).isEmpty
        if aerospace {
            log.warning("AeroSpace (\(WMController.aerospaceBundleID, privacy: .public)) runs. Tiling stays off until it quits.")
        }
    }

    // MARK: - Signals

    /// Turns SIGTERM and SIGINT into a normal `NSApp.terminate`.
    /// `applicationWillTerminate` then stops the controller and unregisters the hotkeys.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.log.notice("Signal \(sig, privacy: .public) received. The app quits.")
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Config

    /// Writes the default file when absent, then loads it. A bad file yields
    /// the default config and a log entry.
    static func loadInitialConfig(log: Logger) -> Config {
        do {
            try Config.writeDefaultIfMissing()
        } catch {
            log.error("Cannot write the default config: \(String(describing: error), privacy: .public)")
        }
        do {
            return try Config.load()
        } catch {
            log.error("Config load failed. The default config applies: \(String(describing: error), privacy: .public)")
            return .default
        }
    }

    private func openConfig() {
        let url = Config.path
        do {
            try Config.writeDefaultIfMissing(at: url)
        } catch {
            log.error("Cannot write the default config: \(String(describing: error), privacy: .public)")
        }
        if NSWorkspace.shared.open(url) { return }
        // No app claims `.json`. Use TextEdit as the fallback editor.
        if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            log.error("Cannot open \(url.path, privacy: .public).")
        }
    }

    private func reloadConfig() {
        controller.reloadConfig()
        updateMenu()
    }

    // MARK: - Enable state

    private func toggleEnabled() {
        if controller.enabled {
            wantsEnabled = false
            permissionTimer?.invalidate()
            permissionTimer = nil
            controller.stop()
        } else {
            wantsEnabled = true
            startWhenTrusted(prompt: true)
        }
        updateMenu()
    }

    /// Starts the controller now when the grant exists. Else polls every 2 s.
    private func startWhenTrusted(prompt: Bool) {
        guard wantsEnabled else { return }
        if Permissions.isAccessibilityTrusted() {
            controller.start()
            updateMenu()
            return
        }
        if prompt { _ = Permissions.requestAccessibility() }
        log.warning("Accessibility is not granted. The app polls every 2 s.")
        updateMenu()
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollPermission()
            }
        }
    }

    private func pollPermission() {
        guard Permissions.isAccessibilityTrusted() else { return }
        permissionTimer?.invalidate()
        permissionTimer = nil
        log.info("Accessibility granted.")
        if wantsEnabled && !controller.enabled {
            controller.start()
        }
        updateMenu()
    }

    private func updateMenu() {
        guard let controller else { return }
        menuBar.update(enabled: controller.enabled,
                       warning: controller.warning,
                       accessibilityGranted: Permissions.isAccessibilityTrusted())
        menuBar.setStatus(controller.statusText)
    }
}
