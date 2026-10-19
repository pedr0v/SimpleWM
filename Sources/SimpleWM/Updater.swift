import AppKit
import Sparkle
import os

/// Finds new releases with Sparkle. Installs a release only after the user agrees.
///
/// Rules:
/// - Sparkle's own scheduled checks are off (`SUEnableAutomaticChecks` false).
///   Sparkle never opens a window on its own.
/// - A probe (`checkForUpdateInformation`) runs 10 s after the start and then
///   every 24 h. A probe reads the appcast only. It shows no UI and downloads
///   no release.
/// - A probe reports the newest version through `onAvailableUpdate`.
///   The menu then shows "Update (vX.Y.Z)".
/// - `checkForUpdates()` opens the Sparkle window. The user clicks
///   "Install Update" to download and install. This click is the permission.
///
/// The app is not sandboxed, so Sparkle installs without its XPC services.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    /// Delay of the first probe after the start.
    static let firstProbeDelay: TimeInterval = 10
    /// Interval between two probes.
    static let probeInterval: TimeInterval = 24 * 60 * 60

    /// Receives the display version of a new release, or nil when no release is newer.
    var onAvailableUpdate: ((String?) -> Void)?

    /// True after Sparkle starts. False when the app runs outside a bundle
    /// or the bundle has no feed.
    private(set) var isRunning = false

    private let log = Logger(subsystem: "com.simplewm.app", category: "updater")
    private var updater: SPUUpdater?
    private var firstProbe: Timer?
    private var probeTimer: Timer?

    /// Starts Sparkle and schedules the probes. A failure only logs:
    /// the app works without the updater.
    func start() {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app",
              bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            log.notice("Updater off: the app does not run from an app bundle with SUFeedURL.")
            return
        }

        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle,
                                 userDriver: driver, delegate: self)
        do {
            try updater.start()
        } catch {
            log.error("Updater start failed: \(String(describing: error), privacy: .public)")
            return
        }
        // A user default can override the Info.plist keys. The app keeps both off.
        if updater.automaticallyChecksForUpdates { updater.automaticallyChecksForUpdates = false }
        if updater.automaticallyDownloadsUpdates { updater.automaticallyDownloadsUpdates = false }

        self.updater = updater
        isRunning = true
        let feed = updater.feedURL?.absoluteString ?? "none"
        log.notice("Updater started. Feed \(feed, privacy: .public), first probe in \(Int(Self.firstProbeDelay), privacy: .public) s, then every \(Int(Self.probeInterval), privacy: .public) s.")

        firstProbe = Timer.scheduledTimer(withTimeInterval: Self.firstProbeDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.probe() }
        }
        probeTimer = Timer.scheduledTimer(withTimeInterval: Self.probeInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probe() }
        }
        probeTimer?.tolerance = 60
    }

    /// Opens the Sparkle window. It shows the new release with "Install Update",
    /// or a message that this version is the newest.
    func checkForUpdates() {
        guard let updater else {
            log.notice("Check for updates ignored: the updater does not run.")
            return
        }
        guard updater.canCheckForUpdates else {
            log.notice("Check for updates ignored: a check runs now.")
            return
        }
        log.notice("User check for updates.")
        // The app has no Dock icon. Bring the Sparkle window to the front.
        NSApp.activate()
        updater.checkForUpdates()
    }

    /// Reads the appcast without UI. The delegate methods report the result.
    private func probe() {
        guard let updater else { return }
        if updater.sessionInProgress {
            log.info("Probe skipped: an update session runs.")
            return
        }
        log.info("Probe for updates.")
        updater.checkForUpdateInformation()
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        log.notice("Update found: version \(version, privacy: .public) (build \(item.versionString, privacy: .public)).")
        onAvailableUpdate?(version)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        let info = (error as NSError).userInfo
        let reason = (info[SPUNoUpdateFoundReasonKey] as? NSNumber).map { "\($0.intValue)" } ?? "unknown"
        let latest = (info[SPULatestAppcastItemFoundKey] as? SUAppcastItem)?.displayVersionString ?? "none"
        log.notice("No update found. Reason \(reason, privacy: .public), newest in feed \(latest, privacy: .public).")
        onAvailableUpdate?(nil)
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        let version = updateItem.displayVersionString
        switch choice {
        case .skip:
            // Probes do not report a skipped version. The menu goes back to the check item.
            log.notice("User skipped version \(version, privacy: .public).")
            onAvailableUpdate?(nil)
        case .install:
            log.notice("User chose to install version \(version, privacy: .public).")
        case .dismiss:
            log.notice("User dismissed version \(version, privacy: .public).")
        @unknown default:
            break
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        // `SUNoUpdateError` also arrives at `updaterDidNotFindUpdate`.
        guard !(nsError.domain == SUSparkleErrorDomain && nsError.code == Int(SUError.noUpdateError.rawValue)) else { return }
        log.error("Update check failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public): \(nsError.localizedDescription, privacy: .public)")
    }
}
