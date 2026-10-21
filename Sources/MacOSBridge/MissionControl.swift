import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LayoutEngine
import os

/// Shared access to Mission Control through the Dock Accessibility tree.
///
/// `SpaceCreator` and `SpaceRemover` use these functions. Only the Dock can
/// add or remove a desktop. So both classes press Dock elements while
/// Mission Control is open.
@MainActor
public enum MissionControl {
    /// Poll interval for the Dock AX tree: 10 ms.
    static let axPollMs = 10
    /// Poll interval for SkyLight: 50 ms.
    static let skyLightPollMs = 50
    /// Cap for one wait on the Dock or on SkyLight.
    static let waitCapMs = 2000
    /// Cap for the close wait. Escape is the fallback.
    static let closeCapMs = 1000
    /// Pause after the close, so the animation ends before a Space switch.
    static let settleMs = 300
    /// Timeout of one AX request to the Dock, in seconds.
    static let axMessagingTimeout: Float = 1.0

    static let dockBundleID = "com.apple.dock"
    static let appURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
    static let groupID = "mc"
    static let displayGroupID = "mc.display"
    /// Virtual key code of Escape.
    static let escapeKeyCode: CGKeyCode = 53

    static let log = Logger(subsystem: "com.simplewm.app", category: "spaces")

    /// True when the Dock shows the Mission Control group now.
    public static func isOpen() -> Bool {
        guard let dock = dockElement() else { return false }
        return group(in: dock) != nil
    }

    /// Toggles Mission Control with `Mission Control.app`. It does not depend
    /// on the keyboard shortcut. `activates` is false, so the focus stays.
    static func toggle() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let log = self.log
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                log.error("Mission Control did not start: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Closes Mission Control with the same toggle. When the group stays,
    /// the function posts Escape once.
    static func close(dock: AXUIElement) async {
        guard group(in: dock) != nil else { return }
        toggle()
        let gone: Bool? = await poll(everyMs: axPollMs, capMs: closeCapMs, budget: Deadline(ms: closeCapMs)) {
            group(in: dock) == nil ? true : nil
        }
        if gone == true { return }
        log.warning("Mission Control stays open after the toggle. Posting Escape.")
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: escapeKeyCode, keyDown: down)?
                .post(tap: .cghidEventTap)
        }
        let closed: Bool? = await poll(everyMs: axPollMs, capMs: 500, budget: Deadline(ms: 500)) {
            group(in: dock) == nil ? true : nil
        }
        if closed != true {
            log.error("Mission Control stays open. The user must close it.")
        }
    }

    /// Waits until the close animation ends: a fixed pause, then until
    /// SkyLight reports that the display does not animate.
    static func settle(display: DisplayID) async {
        try? await Task.sleep(nanoseconds: UInt64(settleMs) * 1_000_000)
        await SpaceReader.waitWhileAnimating(display, timeoutMs: 600)
    }

    // MARK: - Accessibility

    /// AX element of the Dock process, or nil when the Dock does not run.
    static func dockElement() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: dockBundleID).first
        else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
        return element
    }

    /// Dock child with identifier `mc` (title "Mission Control"), or nil.
    static func group(in dock: AXUIElement) -> AXUIElement? {
        AXTree.children(dock).first { AXTree.string($0, "AXIdentifier") == groupID }
    }

    /// The `mc.display` groups for `cgID`.
    ///
    /// With shared Spaces ("Displays have separate Spaces" off), a display
    /// can lack its own group. Then every display group is a candidate.
    static func displayGroups(in group: AXUIElement, cgID: CGDirectDisplayID, sharedSpaces: Bool) -> [AXUIElement] {
        let displays = AXTree.children(group).filter { AXTree.string($0, "AXIdentifier") == displayGroupID }
        let exact = displays.filter {
            (AXTree.attribute($0, "AXDisplayID") as? NSNumber)?.uint32Value == cgID
        }
        return exact.isEmpty && sharedSpaces ? displays : exact
    }

    // MARK: - Waiting

    /// End of a time budget.
    struct Deadline {
        let end: Date
        init(ms: Int) { end = Date().addingTimeInterval(Double(ms) / 1000) }
        var remaining: TimeInterval { end.timeIntervalSinceNow }
    }

    /// Calls `body` now and then every `everyMs` until it returns a value.
    /// Stops after `capMs` or when `budget` ends. Returns nil on a timeout.
    static func poll<T>(everyMs: Int, capMs: Int, budget: Deadline,
                        _ body: () -> T?) async -> T? {
        let stop = min(Date().addingTimeInterval(Double(capMs) / 1000), budget.end)
        while true {
            if let value = body() { return value }
            if Date() >= stop { return nil }
            try? await Task.sleep(nanoseconds: UInt64(everyMs) * 1_000_000)
        }
    }
}

/// Small Accessibility reads. Each function returns nil or an empty value on an AX error.
enum AXTree {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
    }

    /// Action names of `element`, or an empty list on an AX error.
    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    /// Text dump of `root` and its descendants, one line per element:
    /// identifier, role, subrole, description, actions. For diagnostics.
    static func dump(_ root: AXUIElement, maxDepth: Int, depth: Int = 0) -> String {
        let pad = String(repeating: "  ", count: depth)
        let fields = [
            string(root, "AXIdentifier").map { "id=\($0)" },
            string(root, kAXRoleAttribute as String).map { "role=\($0)" },
            string(root, kAXSubroleAttribute as String).map { "subrole=\($0)" },
            string(root, kAXDescriptionAttribute as String).map { "desc=\($0)" },
            string(root, kAXTitleAttribute as String).map { "title=\($0)" },
        ].compactMap { $0 }
        var line = pad + fields.joined(separator: " ") + " actions=" + actions(root).joined(separator: ",")
        if depth < maxDepth {
            for child in children(root) {
                line += "\n" + dump(child, maxDepth: maxDepth, depth: depth + 1)
            }
        }
        return line
    }

    /// Breadth-first search for the first descendant with `AXIdentifier`
    /// equal to `identifier`. The search goes at most `maxDepth` levels down.
    static func find(identifier: String, in root: AXUIElement, maxDepth: Int) -> AXUIElement? {
        var level = children(root)
        var depth = 1
        while !level.isEmpty, depth <= maxDepth {
            if let hit = level.first(where: { string($0, "AXIdentifier") == identifier }) { return hit }
            level = level.flatMap(children)
            depth += 1
        }
        return nil
    }
}
