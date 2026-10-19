import AppKit

/// Status item with: Enable/Disable, Open Config, Reload Config, Quit.
/// The title shows `WM` normally and `WM!` after a failed Space switch.
@MainActor
public final class MenuBar: NSObject {
    public let item: NSStatusItem
    public var onToggleEnabled: (() -> Void)?
    public var onOpenConfig: (() -> Void)?
    public var onReloadConfig: (() -> Void)?

    public override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    /// Builds the menu and sets the title.
    public func install() {
        fatalError("TODO")
    }

    /// Updates the Enable/Disable title and the warning mark.
    public func update(enabled: Bool, warning: Bool, accessibilityGranted: Bool) {
        fatalError("TODO")
    }
}
