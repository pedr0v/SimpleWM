import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LayoutEngine
import os

/// Creates one native desktop (type-0 Space) on one display.
///
/// macOS has no public API for this. The private SkyLight function
/// `SLSSpaceCreate` makes a Space that no display owns when a process other
/// than the Dock calls it. So the creator presses the "+" button of Mission
/// Control through the Accessibility API. The Dock owns that button.
///
/// Steps of `createSpace(on:)`:
/// 1. Read the Space list of the display from SkyLight.
/// 2. Open Mission Control. The app `Mission Control.app` toggles it and does not
///    take focus. When Mission Control is already open, the creator reuses it.
/// 3. Wait for the Dock AX group with identifier `mc`.
/// 4. In the `mc.display` group whose `AXDisplayID` equals the display, find
///    the button `mc.spaces.add`. Match on the identifier. The description
///    text depends on the language.
/// 5. Press the button (`AXPress`).
/// 6. Poll SkyLight until the display lists one more type-0 Space.
/// 7. Close Mission Control, only when the creator opened it. Wait until the
///    close animation ends.
///
/// Waits for steps 3 to 6 share one budget of 3 s. Each wait has its own cap.
/// The Dock appends the new Space at the end of `Spaces[]`. The current Space
/// of the display does not change.
@MainActor
public final class SpaceCreator {
    /// Poll interval for the Dock AX tree: 10 ms.
    static let axPollMs = 10
    /// Poll interval for SkyLight: 50 ms.
    static let skyLightPollMs = 50
    /// Cap for one wait in steps 3, 4, and 6.
    static let waitCapMs = 2000
    /// Total budget for steps 3 to 6.
    static let budgetMs = 3000
    /// Cap for the close wait. Escape is the fallback.
    static let closeCapMs = 1000
    /// Pause after the close, so the animation ends before a Space switch.
    static let settleMs = 300
    /// Timeout of one AX request to the Dock, in seconds.
    static let axMessagingTimeout: Float = 1.0

    static let dockBundleID = "com.apple.dock"
    static let missionControlURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
    static let missionControlID = "mc"
    static let displayGroupID = "mc.display"
    static let addButtonID = "mc.spaces.add"
    /// Virtual key code of Escape.
    static let escapeKeyCode: CGKeyCode = 53

    private let log = Logger(subsystem: "com.simplewm.app", category: "spaces")
    private let skyLight: SkyLight
    private var busy = false

    public init(skyLight: SkyLight = .shared) {
        self.skyLight = skyLight
    }

    /// True when `createSpace(on:)` can run: Accessibility grant, SkyLight
    /// Space list, and a running Dock.
    public func isAvailable() -> Bool {
        AXIsProcessTrusted() && skyLight.copyManagedDisplaySpaces != nil && dockElement() != nil
    }

    /// Creates one desktop on `display`. Returns its Space ID, or nil when a
    /// step fails or times out. The call leaves the current Space of the
    /// display and the focus as they were. A second call during a run returns nil.
    public func createSpace(on display: DisplaySnapshot) async -> SpaceID? {
        guard !busy else {
            log.warning("Create Space: another creation runs. Request skipped.")
            return nil
        }
        busy = true
        defer { busy = false }

        guard AXIsProcessTrusted() else {
            log.error("Create Space: no Accessibility grant.")
            return nil
        }
        guard let dock = dockElement() else {
            log.error("Create Space: the Dock does not run.")
            return nil
        }
        guard let before = SpaceReader.spaces(ofDisplay: display.id, skyLight) else {
            log.error("Create Space: SkyLight does not list display \(display.id.uuid, privacy: .public).")
            return nil
        }
        let known = Set(before.map(\.id))
        let currentBefore = SpaceReader.currentSpace(of: display.id, skyLight)
        let started = Date()
        log.info("Create Space: display \(display.id.uuid, privacy: .public) has \(before.count, privacy: .public) Spaces.")

        // Step 2: open Mission Control, or reuse an open one.
        let alreadyOpen = missionControlGroup(in: dock) != nil
        if alreadyOpen {
            log.info("Create Space: Mission Control is already open. The creator leaves it open.")
        } else {
            toggleMissionControl()
        }
        let budget = Deadline(ms: Self.budgetMs)

        let created = await addSpace(on: display, dock: dock, known: known, budget: budget)

        // Step 7: close Mission Control only when this call opened it.
        if !alreadyOpen {
            await closeMissionControl(dock: dock)
        }
        await settle(display: display.id)

        let currentAfter = SpaceReader.currentSpace(of: display.id, skyLight)
        if currentBefore != currentAfter {
            log.warning("Create Space: the current Space of the display changed (\(currentBefore?.description ?? "nil", privacy: .public) to \(currentAfter?.description ?? "nil", privacy: .public)).")
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if let created {
            log.info("Create Space: Space \(created.description, privacy: .public) exists after \(ms, privacy: .public) ms.")
        } else {
            log.error("Create Space failed after \(ms, privacy: .public) ms.")
        }
        return created
    }

    // MARK: - Steps 3 to 6

    /// Waits for the Mission Control group, presses the add button, and
    /// waits for the new Space. Does not open or close Mission Control.
    private func addSpace(on display: DisplaySnapshot, dock: AXUIElement, known: Set<SpaceID>,
                          budget: Deadline) async -> SpaceID? {
        // Step 3: the Mission Control group.
        let group: AXUIElement? = await poll(everyMs: Self.axPollMs, capMs: Self.waitCapMs, budget: budget) {
            self.missionControlGroup(in: dock)
        }
        guard let group else {
            log.error("Create Space: Mission Control did not appear.")
            return nil
        }
        log.debug("Create Space: Mission Control is open.")

        // Step 4: the add button of the display. The group can fill in a moment later.
        let shared = SpaceReader.sharedScreens.contains(display.id.uuid.uppercased())
        let button: AXUIElement? = await poll(everyMs: Self.axPollMs, capMs: Self.waitCapMs, budget: budget) {
            self.addButton(in: group, cgID: display.cgID, sharedSpaces: shared)
        }
        guard let button else {
            log.error("Create Space: no add button for display \(display.id.uuid, privacy: .public).")
            return nil
        }

        // Step 5: press the button.
        let status = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard status == .success else {
            log.error("Create Space: AXPress failed with AXError \(status.rawValue, privacy: .public).")
            return nil
        }

        // Step 6: wait until SkyLight lists the new Space.
        let created: SpaceID? = await poll(everyMs: Self.skyLightPollMs, capMs: Self.waitCapMs, budget: budget) {
            let now = SpaceReader.spaces(ofDisplay: display.id, self.skyLight) ?? []
            return now.last { $0.isUser && !known.contains($0.id) }?.id
        }
        if created == nil {
            log.error("Create Space: SkyLight lists no new Space after the press.")
        }
        return created
    }

    // MARK: - Mission Control

    /// Toggles Mission Control with `Mission Control.app`. It does not depend
    /// on the keyboard shortcut. `activates` is false, so the focus stays.
    private func toggleMissionControl() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let log = self.log
        NSWorkspace.shared.openApplication(at: Self.missionControlURL, configuration: configuration) { _, error in
            if let error {
                log.error("Create Space: Mission Control did not start: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Closes Mission Control with the same toggle. When the group stays,
    /// the function posts Escape once.
    private func closeMissionControl(dock: AXUIElement) async {
        guard missionControlGroup(in: dock) != nil else { return }
        toggleMissionControl()
        let gone: Bool? = await poll(everyMs: Self.axPollMs, capMs: Self.closeCapMs, budget: Deadline(ms: Self.closeCapMs)) {
            self.missionControlGroup(in: dock) == nil ? true : nil
        }
        if gone == true { return }
        log.warning("Create Space: Mission Control stays open after the toggle. Posting Escape.")
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: Self.escapeKeyCode, keyDown: down)?
                .post(tap: .cghidEventTap)
        }
        let closed: Bool? = await poll(everyMs: Self.axPollMs, capMs: 500, budget: Deadline(ms: 500)) {
            self.missionControlGroup(in: dock) == nil ? true : nil
        }
        if closed != true {
            log.error("Create Space: Mission Control stays open. The user must close it.")
        }
    }

    /// Waits until the close animation ends: a fixed pause, then until
    /// SkyLight reports that the display does not animate.
    private func settle(display: DisplayID) async {
        try? await Task.sleep(nanoseconds: UInt64(Self.settleMs) * 1_000_000)
        await SpaceReader.waitWhileAnimating(display, timeoutMs: 600)
    }

    // MARK: - Accessibility

    /// AX element of the Dock process, or nil when the Dock does not run.
    private func dockElement() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first
        else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, Self.axMessagingTimeout)
        return element
    }

    /// Dock child with identifier `mc` (title "Mission Control"), or nil.
    private func missionControlGroup(in dock: AXUIElement) -> AXUIElement? {
        AXTree.children(dock).first { AXTree.string($0, "AXIdentifier") == Self.missionControlID }
    }

    /// Button `mc.spaces.add` of the `mc.display` group for `cgID`.
    ///
    /// With shared Spaces ("Displays have separate Spaces" off), a display
    /// can lack its own group. Then any display group with the button works.
    private func addButton(in group: AXUIElement, cgID: CGDirectDisplayID, sharedSpaces: Bool) -> AXUIElement? {
        let displays = AXTree.children(group).filter { AXTree.string($0, "AXIdentifier") == Self.displayGroupID }
        let exact = displays.filter {
            (AXTree.attribute($0, "AXDisplayID") as? NSNumber)?.uint32Value == cgID
        }
        let candidates = exact.isEmpty && sharedSpaces ? displays : exact
        for display in candidates {
            if let button = AXTree.find(identifier: Self.addButtonID, in: display, maxDepth: 4) {
                return button
            }
        }
        return nil
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
    private func poll<T>(everyMs: Int, capMs: Int, budget: Deadline,
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
