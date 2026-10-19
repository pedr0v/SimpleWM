// SimpleWM entry point.
// The app runs as an accessory (no Dock icon) with one status item.
// `AppDelegate` loads the config, builds `WMController`, and installs `MenuBar`.
import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    // `NSApplication.delegate` is weak. Keep the delegate alive while the app runs.
    withExtendedLifetime(delegate) {
        app.run()
    }
}
