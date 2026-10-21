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
    /// Total budget for steps 3 to 6.
    static let budgetMs = 3000
    static let addButtonID = "mc.spaces.add"

    private let log = Logger(subsystem: "com.simplewm.app", category: "spaces")
    private let skyLight: SkyLight
    private var busy = false

    public init(skyLight: SkyLight = .shared) {
        self.skyLight = skyLight
    }

    /// True when `createSpace(on:)` can run: Accessibility grant, SkyLight
    /// Space list, and a running Dock.
    public func isAvailable() -> Bool {
        AXIsProcessTrusted() && skyLight.copyManagedDisplaySpaces != nil && MissionControl.dockElement() != nil
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
        guard let dock = MissionControl.dockElement() else {
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
        let alreadyOpen = MissionControl.group(in: dock) != nil
        if alreadyOpen {
            log.info("Create Space: Mission Control is already open. The creator leaves it open.")
        } else {
            MissionControl.toggle()
        }
        let budget = MissionControl.Deadline(ms: Self.budgetMs)

        let created = await addSpace(on: display, dock: dock, known: known, budget: budget)

        // Step 7: close Mission Control only when this call opened it.
        if !alreadyOpen {
            await MissionControl.close(dock: dock)
        }
        await MissionControl.settle(display: display.id)

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
                          budget: MissionControl.Deadline) async -> SpaceID? {
        // Step 3: the Mission Control group.
        let group: AXUIElement? = await MissionControl.poll(everyMs: MissionControl.axPollMs, capMs: MissionControl.waitCapMs, budget: budget) {
            MissionControl.group(in: dock)
        }
        guard let group else {
            log.error("Create Space: Mission Control did not appear.")
            return nil
        }
        log.debug("Create Space: Mission Control is open.")

        // Step 4: the add button of the display. The group can fill in a moment later.
        let shared = SpaceReader.sharedScreens.contains(display.id.uuid.uppercased())
        let button: AXUIElement? = await MissionControl.poll(everyMs: MissionControl.axPollMs, capMs: MissionControl.waitCapMs, budget: budget) {
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
        let created: SpaceID? = await MissionControl.poll(everyMs: MissionControl.skyLightPollMs, capMs: MissionControl.waitCapMs, budget: budget) {
            let now = SpaceReader.spaces(ofDisplay: display.id, self.skyLight) ?? []
            return now.last { $0.isUser && !known.contains($0.id) }?.id
        }
        if created == nil {
            log.error("Create Space: SkyLight lists no new Space after the press.")
        }
        return created
    }

    // MARK: - Accessibility

    /// Button `mc.spaces.add` of the `mc.display` group for `cgID`.
    ///
    /// With shared Spaces ("Displays have separate Spaces" off), a display
    /// can lack its own group. Then any display group with the button works.
    private func addButton(in group: AXUIElement, cgID: CGDirectDisplayID, sharedSpaces: Bool) -> AXUIElement? {
        for display in MissionControl.displayGroups(in: group, cgID: cgID, sharedSpaces: sharedSpaces) {
            if let button = AXTree.find(identifier: Self.addButtonID, in: display, maxDepth: 4) {
                return button
            }
        }
        return nil
    }
}
