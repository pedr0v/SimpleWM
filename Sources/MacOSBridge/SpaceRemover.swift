import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LayoutEngine
import os

/// Removes empty native desktops (type-0 Spaces) from one display.
///
/// macOS has no public API for this. The remover opens Mission Control and
/// runs the Accessibility action `AXRemoveDesktop` on the thumbnail of the
/// Space. The Dock owns the thumbnails. Hammerspoon `hs.spaces.removeSpace`
/// uses the same action.
///
/// Steps of `removeSpaces(_:on:)`:
/// 1. Read the Space list of the display from SkyLight.
/// 2. Open Mission Control, or reuse an open one.
/// 3. Wait for the Dock AX group `mc`, the `mc.display` group of the
///    display, and its list `mc.spaces.list`.
/// 4. For each target, from the highest index down: take the list child at
///    the Mission Control index of the Space, run `AXRemoveDesktop`, and
///    poll SkyLight until the Space is gone.
/// 5. Close Mission Control, only when the remover opened it. Wait until
///    the close animation ends.
///
/// The remover never removes the current Space of the display, the first
/// Space, or a non-user Space. `SpaceManager.emptySpaceCandidates(on:)`
/// applies those rules. The remover checks them again before each action.
@MainActor
public final class SpaceRemover {
    /// Total budget for steps 3 and 4.
    static let budgetMs = 4000
    static let spacesGroupID = "mc.spaces"
    static let spacesListID = "mc.spaces.list"
    static let removeAction = "AXRemoveDesktop"

    private let log = Logger(subsystem: "com.simplewm.app", category: "spaces")
    private let skyLight: SkyLight
    public private(set) var busy = false

    public init(skyLight: SkyLight = .shared) {
        self.skyLight = skyLight
    }

    /// True when `removeSpaces(_:on:)` can run: Accessibility grant,
    /// SkyLight Space list, and a running Dock.
    public func isAvailable() -> Bool {
        AXIsProcessTrusted() && skyLight.copyManagedDisplaySpaces != nil && MissionControl.dockElement() != nil
    }

    /// Removes the Spaces in `ids` from `display`. Returns the count of
    /// removed Spaces. A second call during a run returns 0.
    public func removeSpaces(_ ids: [SpaceID], on display: DisplaySnapshot) async -> Int {
        guard !ids.isEmpty else { return 0 }
        guard !busy else {
            log.warning("Remove Space: another removal runs. Request skipped.")
            return 0
        }
        busy = true
        defer { busy = false }

        guard AXIsProcessTrusted() else {
            log.error("Remove Space: no Accessibility grant.")
            return 0
        }
        guard let dock = MissionControl.dockElement() else {
            log.error("Remove Space: the Dock does not run.")
            return 0
        }
        let started = Date()
        let alreadyOpen = MissionControl.group(in: dock) != nil
        if alreadyOpen {
            log.info("Remove Space: Mission Control is already open. The remover leaves it open.")
        } else {
            MissionControl.toggle()
        }
        let budget = MissionControl.Deadline(ms: Self.budgetMs)

        let removed = await removeAll(ids, on: display, dock: dock, budget: budget)

        if !alreadyOpen {
            await MissionControl.close(dock: dock)
        }
        await MissionControl.settle(display: display.id)

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        log.info("Remove Space: removed \(removed, privacy: .public) of \(ids.count, privacy: .public) Space(s) after \(ms, privacy: .public) ms.")
        return removed
    }

    // MARK: - Steps 3 and 4

    /// Waits for the thumbnail list and removes each target. Does not open
    /// or close Mission Control.
    private func removeAll(_ ids: [SpaceID], on display: DisplaySnapshot, dock: AXUIElement,
                           budget: MissionControl.Deadline) async -> Int {
        let group: AXUIElement? = await MissionControl.poll(everyMs: MissionControl.axPollMs, capMs: MissionControl.waitCapMs, budget: budget) {
            MissionControl.group(in: dock)
        }
        guard let group else {
            log.error("Remove Space: Mission Control did not appear.")
            return 0
        }
        let shared = SpaceReader.sharedScreens.contains(display.id.uuid.uppercased())
        let list: AXUIElement? = await MissionControl.poll(everyMs: MissionControl.axPollMs, capMs: MissionControl.waitCapMs, budget: budget) {
            self.spacesList(in: group, cgID: display.cgID, sharedSpaces: shared)
        }
        guard let list else {
            log.error("Remove Space: no Space list for display \(display.id.uuid, privacy: .public).")
            return 0
        }

        var removed = 0
        // Highest index first: a removal shifts the indexes above it only.
        for id in ids.sorted(by: { indexOf($0, on: display) > indexOf($1, on: display) }) {
            guard let spaces = SpaceReader.spaces(ofDisplay: display.id, skyLight),
                  let index = spaces.firstIndex(where: { $0.id == id }) else {
                log.info("Remove Space: Space \(id.description, privacy: .public) is already gone.")
                continue
            }
            guard index > 0, spaces[index].isUser,
                  SpaceReader.currentSpace(of: display.id, skyLight) != id else {
                log.info("Remove Space: Space \(id.description, privacy: .public) is protected now. Skipped.")
                continue
            }
            let children = AXTree.children(list)
            guard index < children.count else {
                log.error("Remove Space: the list has \(children.count, privacy: .public) thumbnails, index \(index, privacy: .public) is out of range.")
                break
            }
            let thumbnail = children[index]
            guard AXTree.actions(thumbnail).contains(Self.removeAction) else {
                log.error("Remove Space: the thumbnail has no \(Self.removeAction, privacy: .public) action.")
                break
            }
            let status = AXUIElementPerformAction(thumbnail, Self.removeAction as CFString)
            guard status == .success else {
                log.error("Remove Space: \(Self.removeAction, privacy: .public) failed with AXError \(status.rawValue, privacy: .public).")
                break
            }
            let gone: Bool? = await MissionControl.poll(everyMs: MissionControl.skyLightPollMs, capMs: MissionControl.waitCapMs, budget: budget) {
                let now = SpaceReader.spaces(ofDisplay: display.id, self.skyLight) ?? []
                return now.contains { $0.id == id } ? nil : true
            }
            guard gone == true else {
                log.error("Remove Space: SkyLight still lists Space \(id.description, privacy: .public) after the action.")
                break
            }
            removed += 1
            log.info("Remove Space: Space \(id.description, privacy: .public) (index \(index + 1, privacy: .public)) is gone.")
        }
        return removed
    }

    private func indexOf(_ id: SpaceID, on display: DisplaySnapshot) -> Int {
        display.spaces.firstIndex { $0.id == id } ?? -1
    }

    // MARK: - Accessibility

    /// The `mc.spaces.list` group of the `mc.display` group for `cgID`.
    private func spacesList(in group: AXUIElement, cgID: CGDirectDisplayID, sharedSpaces: Bool) -> AXUIElement? {
        for display in MissionControl.displayGroups(in: group, cgID: cgID, sharedSpaces: sharedSpaces) {
            if let list = AXTree.find(identifier: Self.spacesListID, in: display, maxDepth: 4) {
                return list
            }
        }
        return nil
    }
}
