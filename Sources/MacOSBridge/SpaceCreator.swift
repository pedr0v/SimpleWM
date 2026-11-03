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
/// Control through the Accessibility API. See `MissionControlTree` for the
/// tree layouts (Dock before macOS 27, WindowManager from macOS 27).
///
/// Steps of `createSpace(on:)`:
/// 1. Read the Space list of the display from SkyLight.
/// 2. Open Mission Control with `MissionControlSession`. The app
///    `Mission Control.app` toggles it and does not take focus. When
///    Mission Control is already open, the creator reuses it.
/// 3. Wait for the tree root in the Dock or in WindowManager.
/// 4. In the `mc.display` group whose `AXDisplayID` equals the display, find
///    the button `mc.spaces.add`. Match on the identifier. The description
///    text depends on the language.
/// 5. Press the button (`AXPress`).
/// 6. Poll SkyLight until the display lists one more type-0 Space.
/// 7. Close Mission Control, only when the creator opened it. This step
///    runs after every failure too. Wait until the close animation ends.
///
/// Waits for steps 3 to 6 share one budget of 3 s. Each wait has its own cap.
/// Mission Control appends the new Space at the end of `Spaces[]`. The
/// current Space of the display does not change.
@MainActor
public final class SpaceCreator {
    /// Total budget for steps 3 to 6.
    static let budgetMs = 3000

    private let log = Logger(subsystem: "com.simplewm.app", category: "spaces")
    private let skyLight: SkyLight
    private var busy = false

    public init(skyLight: SkyLight = .shared) {
        self.skyLight = skyLight
    }

    /// True when `createSpace(on:)` can run: Accessibility grant, SkyLight
    /// Space list, and a running Mission Control host.
    public func isAvailable() -> Bool {
        AXIsProcessTrusted() && skyLight.copyManagedDisplaySpaces != nil && MissionControl.hostRuns()
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
        guard MissionControl.hostRuns() else {
            log.error("Create Space: no Mission Control host runs (Dock, WindowManager).")
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

        // Steps 2 and 3: open Mission Control, or reuse an open one.
        let budget = MissionControl.Deadline(ms: Self.budgetMs)
        let session = MissionControlSession(what: "Create Space")
        var created: SpaceID?
        if let root = await session.open(budget: budget) {
            created = await addSpace(on: display, root: root, known: known, budget: budget)
        } else {
            log.error("Create Space: Mission Control did not appear.")
        }

        // Step 7: close Mission Control only when this call opened it.
        await session.close()
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

    // MARK: - Steps 4 to 6

    /// Presses the add button and waits for the new Space. Does not open
    /// or close Mission Control.
    private func addSpace(on display: DisplaySnapshot, root: LiveAXNode, known: Set<SpaceID>,
                          budget: MissionControl.Deadline) async -> SpaceID? {
        // Step 4: the add button of the display. The group can fill in a moment later.
        let shared = SpaceReader.sharedScreens.contains(display.id.uuid.uppercased())
        let button: LiveAXNode? = await MissionControl.poll(everyMs: MissionControl.axPollMs, capMs: MissionControl.waitCapMs, budget: budget) {
            MissionControlTree.addButton(in: root, cgID: display.cgID, sharedSpaces: shared)
        }
        guard let button else {
            log.error("Create Space: no add button for display \(display.id.uuid, privacy: .public) (CG \(display.cgID, privacy: .public)).")
            return nil
        }

        // Step 5: press the button.
        let status = AXUIElementPerformAction(button.element, kAXPressAction as CFString)
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
}
