import AppKit

/// Status item with: Enable/Disable, Open Config, Reload Config, Quit.
/// The title shows `WM` normally and `WM!` after a failed Space switch.
///
/// Title states:
/// - `WM`: enabled, no warning.
/// - `WM!`: a warning is active, or the Accessibility grant is missing.
/// - `WM·`: disabled.
@MainActor
public final class MenuBar: NSObject {
    public let item: NSStatusItem
    public var onToggleEnabled: (() -> Void)?
    public var onOpenConfig: (() -> Void)?
    public var onReloadConfig: (() -> Void)?

    private let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledMenuItem = NSMenuItem(title: "Enabled", action: nil, keyEquivalent: "")

    public override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    /// Builds the menu and sets the title.
    public func install() {
        if let button = item.button {
            let image = NSImage(systemSymbolName: "rectangle.split.2x1",
                                accessibilityDescription: "SimpleWM")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.title = "WM"
            button.toolTip = "SimpleWM"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        statusMenuItem.isEnabled = false
        statusMenuItem.isHidden = true
        menu.addItem(statusMenuItem)

        enabledMenuItem.target = self
        enabledMenuItem.action = #selector(toggleEnabled)
        enabledMenuItem.state = .off
        menu.addItem(enabledMenuItem)

        menu.addItem(makeItem("Open Config", #selector(openConfig), key: ","))
        menu.addItem(makeItem("Reload Config", #selector(reloadConfig), key: "r"))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit", #selector(quit), key: "q"))

        item.menu = menu
    }

    /// Updates the Enable/Disable title and the warning mark.
    public func update(enabled: Bool, warning: Bool, accessibilityGranted: Bool) {
        // A warning has priority over the disabled mark.
        let title: String
        if warning || !accessibilityGranted {
            title = "WM!"
        } else if !enabled {
            title = "WM\u{00B7}"
        } else {
            title = "WM"
        }
        item.button?.title = title
        enabledMenuItem.state = enabled ? .on : .off
    }

    /// Shows `text` as a disabled first menu row. Nil hides the row.
    public func setStatus(_ text: String?) {
        statusMenuItem.title = text ?? ""
        statusMenuItem.isHidden = (text ?? "").isEmpty
        item.button?.toolTip = text.map { "SimpleWM: \($0)" } ?? "SimpleWM"
    }

    private func makeItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    @objc private func toggleEnabled() { onToggleEnabled?() }
    @objc private func openConfig() { onOpenConfig?() }
    @objc private func reloadConfig() { onReloadConfig?() }
    @objc private func quit() { NSApp.terminate(nil) }
}
