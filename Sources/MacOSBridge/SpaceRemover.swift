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
/// Space. Hammerspoon `hs.spaces.removeSpace` uses the same action. See
/// `MissionControlTree` for the tree layouts (Dock before macOS 27,
/// WindowManager from macOS 27).
///
/// Steps of `removeSpaces(_:on:isEmpty:)`:
/// 1. Open Mission Control with `MissionControlSession`, or reuse an open one.
/// 2. Wait for the tree root, the `mc.display` group of the display, and
///    its list `mc.spaces.list`.
/// 3. For each target, from the highest index down: check the rules again,
///    take the list child at the index of the Space, run
///    `AXRemoveDesktop`, and poll SkyLight until the Space is gone.
/// 4. Close Mission Control, only when the remover opened it. This step
///    runs after every failure too. Wait until the close animation ends.
///
/// The remover never removes the first Space, the current Space, the last
/// Space, a non-user Space, or a Space with a window.
/// `SpaceManager.emptySpaceCandidates(on:)` applies those rules. The
/// remover checks them again before each action. It uses an index only when
/// the list has as many thumbnails as SkyLight has Spaces.
@MainActor
public final class SpaceRemover {
    /// True when the system has `AXRemoveDesktop` on a desktop thumbnail.
    /// macOS 27 has it. The Dock of macOS 26 does not, so a cleanup pass
    /// there only opens Mission Control and fails. `Config` uses this value
    /// as the default of `removeEmptySpaces`.
    nonisolated public static let systemSupportsRemoval: Bool =
        (DockSwipeEvent.osProductVersion().flatMap(DockSwipeEvent.majorVersion) ?? 0) >= 27

    /// Result of `removeSpaces(_:on:isEmpty:)`.
    public struct Result: Equatable, Sendable {
        /// Spaces that SkyLight does not list after the action.
        public var removed: [SpaceID] = []
        /// True when a step failed: no tree, no list, an AX error, or a
        /// timeout. A Space that is protected now (it got a window, or it is
        /// current now) is skipped. A skip is not a failure.
        public var failed = false
    }

    /// Total budget for steps 2 and 3.
    static let budgetMs = 4000

    private let log = Logger(subsystem: "com.simplewm.app", category: "spaces")
    private let skyLight: SkyLight
    public private(set) var busy = false

    public init(skyLight: SkyLight = .shared) {
        self.skyLight = skyLight
    }

    /// True when `removeSpaces(_:on:isEmpty:)` can run: Accessibility
    /// grant, SkyLight Space list, and a running Mission Control host.
    public func isAvailable() -> Bool {
        AXIsProcessTrusted() && skyLight.copyManagedDisplaySpaces != nil && MissionControl.hostRuns()
    }

    /// Removes the Spaces in `ids` from `display`. `isEmpty` tells if a
    /// Space has no window now. A second call during a run removes nothing
    /// and does not count as a failure.
    public func removeSpaces(_ ids: [SpaceID], on display: DisplaySnapshot,
                             isEmpty: (SpaceID) -> Bool) async -> Result {
        guard !ids.isEmpty else { return Result() }
        guard !busy else {
            log.warning("Remove Space: another removal runs. Request skipped.")
            return Result()
        }
        busy = true
        defer { busy = false }

        guard AXIsProcessTrusted() else {
            log.error("Remove Space: no Accessibility grant.")
            return Result(failed: true)
        }
        guard MissionControl.hostRuns() else {
            log.error("Remove Space: no Mission Control host runs (Dock, WindowManager).")
            return Result(failed: true)
        }
        let started = Date()
        let budget = MissionControl.Deadline(ms: Self.budgetMs)
        let session = MissionControlSession(what: "Remove Space")
        var result = Result()
        if let root = await session.open(budget: budget) {
            result = await removeAll(ids, on: display, root: root, isEmpty: isEmpty, budget: budget)
        } else {
            log.error("Remove Space: Mission Control did not appear.")
            result.failed = true
        }

        await session.close()
        await MissionControl.settle(display: display.id)

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        log.info("Remove Space: removed \(result.removed.count, privacy: .public) of \(ids.count, privacy: .public) Space(s) after \(ms, privacy: .public) ms. Failed: \(result.failed, privacy: .public).")
        return result
    }

    // MARK: - Steps 2 and 3

    /// Waits for the thumbnail list and removes each target. Does not open
    /// or close Mission Control.
    private func removeAll(_ ids: [SpaceID], on display: DisplaySnapshot, root: LiveAXNode,
                           isEmpty: (SpaceID) -> Bool, budget: MissionControl.Deadline) async -> Result {
        let shared = SpaceReader.sharedScreens.contains(display.id.uuid.uppercased())
        let list: LiveAXNode? = await MissionControl.poll(everyMs: MissionControl.axPollMs, capMs: MissionControl.waitCapMs, budget: budget) {
            MissionControlTree.spacesList(in: root, cgID: display.cgID, sharedSpaces: shared)
        }
        guard let list else {
            log.error("Remove Space: no Space list for display \(display.id.uuid, privacy: .public) (CG \(display.cgID, privacy: .public)).")
            return Result(failed: true)
        }

        var result = Result()
        // Highest index first: a removal shifts the indexes above it only.
        for id in ids.sorted(by: { indexOf($0, on: display) > indexOf($1, on: display) }) {
            guard let spaces = SpaceReader.spaces(ofDisplay: display.id, skyLight),
                  let index = spaces.firstIndex(where: { $0.id == id }) else {
                log.info("Remove Space: Space \(id.description, privacy: .public) is already gone.")
                continue
            }
            guard index > 0, index < spaces.count - 1, spaces[index].isUser,
                  SpaceReader.currentSpace(of: display.id, skyLight) != id, isEmpty(id) else {
                log.info("Remove Space: Space \(id.description, privacy: .public) is protected now. Skipped.")
                continue
            }
            // The list can lag behind SkyLight after a removal. Wait until the counts agree.
            let lookup = await MissionControl.poll(everyMs: MissionControl.axPollMs, capMs: MissionControl.waitCapMs, budget: budget) {
                () -> MissionControlTree.ThumbnailLookup<LiveAXNode>? in
                let result = MissionControlTree.thumbnail(in: list, index: index, spaceCount: spaces.count)
                if case .countMismatch = result { return nil }
                return result
            }
            let thumbnail: LiveAXNode
            switch lookup {
            case .found(let node)?:
                thumbnail = node
            case .noRemoveAction(let node)?:
                log.error("Remove Space: the thumbnail has no \(MissionControlTree.removeAction, privacy: .public) action.")
                log.error("Remove Space: thumbnail tree:\n\(AXTree.dump(node.element, maxDepth: 3), privacy: .public)")
                result.failed = true
                return result
            case .countMismatch(let count)?:
                log.error("Remove Space: the list has \(count, privacy: .public) thumbnails, SkyLight has \(spaces.count, privacy: .public) Spaces.")
                result.failed = true
                return result
            case nil:
                log.error("Remove Space: the list has \(list.children.count, privacy: .public) thumbnails, SkyLight has \(spaces.count, privacy: .public) Spaces. No removal.")
                log.error("Remove Space: list tree:\n\(AXTree.dump(list.element, maxDepth: 1), privacy: .public)")
                result.failed = true
                return result
            }
            let status = AXUIElementPerformAction(thumbnail.element, MissionControlTree.removeAction as CFString)
            guard status == .success else {
                log.error("Remove Space: \(MissionControlTree.removeAction, privacy: .public) failed with AXError \(status.rawValue, privacy: .public).")
                result.failed = true
                return result
            }
            let gone: Bool? = await MissionControl.poll(everyMs: MissionControl.skyLightPollMs, capMs: MissionControl.waitCapMs, budget: budget) {
                let now = SpaceReader.spaces(ofDisplay: display.id, self.skyLight) ?? []
                return now.contains { $0.id == id } ? nil : true
            }
            guard gone == true else {
                log.error("Remove Space: SkyLight still lists Space \(id.description, privacy: .public) after the action.")
                result.failed = true
                return result
            }
            result.removed.append(id)
            log.info("Remove Space: Space \(id.description, privacy: .public) (index \(index + 1, privacy: .public)) is gone.")
        }
        return result
    }

    private func indexOf(_ id: SpaceID, on display: DisplaySnapshot) -> Int {
        display.spaces.firstIndex { $0.id == id } ?? -1
    }
}
