import Foundation
import ServiceManagement
import os

/// Registers the app as a login item with `SMAppService.mainApp`.
///
/// Rules:
/// - The app registers itself once, at the first start from `/Applications`.
/// - A build in `.build/debug` or `dist/` never registers.
/// - After the first attempt, the app never registers on its own again.
///   The user controls the login item with the "Start at Login" menu item.
@MainActor
enum LoginItem {
    /// The user defaults key that records the first registration attempt.
    static let registeredKey = "loginItemRegistered"

    /// True when the app runs from an app bundle.
    static var runsFromBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// True when the app bundle is in `/Applications`.
    static var isInstalled: Bool {
        runsFromBundle && Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    /// True when macOS starts the app at login.
    static var isEnabled: Bool {
        status == .enabled
    }

    /// The login item status that macOS reports.
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// Registers or unregisters the login item.
    static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Registers the login item at the first start from `/Applications`.
    /// The app records the attempt also on failure, so it never asks again.
    static func registerOnFirstRun(log: Logger) {
        guard isInstalled else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: registeredKey) else { return }
        do {
            try setEnabled(true)
            log.info("Login item registered.")
        } catch {
            log.error("Login item registration failed: \(String(describing: error), privacy: .public)")
        }
        defaults.set(true, forKey: registeredKey)
        if status == .requiresApproval {
            log.notice("Login item: macOS waits for approval in System Settings > General > Login Items.")
        }
    }
}
