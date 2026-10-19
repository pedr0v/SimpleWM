import AppKit
import Foundation
import CoreGraphics
import LayoutEngine
import ObjectiveC
import os

/// One native Space as SkyLight reports it.
public struct SpaceInfo: Equatable, Sendable {
    public let id: SpaceID
    /// `SLSSpaceGetType` value: 0 user Space, 2 system, 4 fullscreen or tile pair.
    public let type: Int32
    public var isUser: Bool { type == 0 }
    public var isFullscreen: Bool { type == 4 }
    public init(id: SpaceID, type: Int32) {
        self.id = id
        self.type = type
    }
}

/// Snapshot of one display and its ordered Space list.
public struct DisplaySnapshot: Equatable, Sendable {
    public let id: DisplayID
    public let cgID: CGDirectDisplayID
    /// Full display bounds in AX coordinates (`CGDisplayBounds`).
    public let frame: Rect
    /// Work area in AX coordinates (menu bar and Dock excluded).
    public let workArea: Rect
    /// All Spaces in `Spaces[]` order, fullscreen entries included.
    public let spaces: [SpaceInfo]
    public let current: SpaceInfo

    public init(id: DisplayID, cgID: CGDirectDisplayID, frame: Rect, workArea: Rect, spaces: [SpaceInfo], current: SpaceInfo) {
        self.id = id
        self.cgID = cgID
        self.frame = frame
        self.workArea = workArea
        self.spaces = spaces
        self.current = current
    }

    /// Only type-0 Spaces, in order. Tiling uses this list.
    /// `space N` indexes `spaces` (all Spaces, Mission Control order).
    public var userSpaces: [SpaceInfo] { spaces.filter(\.isUser) }
}

/// Strategy that switches the current Space of one display.
@MainActor
public protocol SpaceSwitchStrategy: AnyObject {
    var name: String { get }
    /// Returns true when the strategy can run now (symbols present, shortcuts enabled).
    func isAvailable() -> Bool
    /// Switches `display` to `target`. Returns true after verification.
    func switchTo(_ target: SpaceID, on display: DisplaySnapshot) async -> Bool
}

/// Strategy that moves one window to another Space.
@MainActor
public protocol WindowMoveStrategy: AnyObject {
    var name: String { get }
    func isAvailable() -> Bool
    /// Moves `w` to `target`. Returns true after `SLSCopySpacesForWindows` confirms.
    func move(_ w: WindowID, to target: SpaceID) async -> Bool
}

/// Result of the last `SpaceManager.switchTo(userSpace:on:)` call.
///
/// The controller reads it to tell a real failure from a normal no-op. Only
/// `.failed` means that every strategy failed.
public enum SpaceSwitchOutcome: Equatable, Sendable {
    /// A strategy switched the display and verification passed.
    case switched(strategy: String)
    /// The target Space was already current. No event was posted.
    case alreadyCurrent
    /// N is less than 1 or greater than the user-Space count. Nothing ran.
    case outOfRange
    /// A newer request replaced this request before it ran.
    case superseded
    /// No strategy is available or no strategy verified.
    case failed
}

// MARK: - Space reader

/// Raw Space data of one display from `SLSCopyManagedDisplaySpaces`.
struct RawDisplaySpaces {
    /// `Display Identifier`: display UUID, or `Main` when displays share Spaces.
    let identifier: String
    let current: SpaceInfo?
    let spaces: [SpaceInfo]
}

/// Reads Space state from SkyLight. Every function returns empty or nil
/// when a symbol is absent.
enum SpaceReader {
    static let log = Logger(subsystem: "com.simplewm.app", category: "spaces")
    /// Mask for `SLSCopySpacesForWindows`: current, other, and user Spaces.
    static let allSpacesMask: Int32 = 0x7

    /// Screen UUIDs (upper case) that `SpaceManager.displays()` made from the
    /// shared `Main` entry. SkyLight knows these screens only as `Main`.
    /// `displays()` sets the value on the main thread.
    nonisolated(unsafe) static var sharedScreens: Set<String> = []

    /// Identifier that SkyLight accepts for `display`. A screen of the shared
    /// Space list maps to `Main`. Every other display keeps its UUID.
    static func skyLightIdentifier(for display: DisplayID) -> String {
        sharedScreens.contains(display.uuid.uppercased()) ? "Main" : display.uuid
    }

    /// Parses `SLSCopyManagedDisplaySpaces`. Order follows the SkyLight array.
    static func rawDisplays(_ sl: SkyLight = .shared) -> [RawDisplaySpaces] {
        guard let copy = sl.copyManagedDisplaySpaces,
              let array = copy(sl.cid)?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return array.compactMap { dict in
            guard let identifier = dict["Display Identifier"] as? String else { return nil }
            let current = (dict["Current Space"] as? [String: Any]).flatMap(spaceInfo)
            let spaces = (dict["Spaces"] as? [[String: Any]] ?? []).compactMap(spaceInfo)
            return RawDisplaySpaces(identifier: identifier, current: current, spaces: spaces)
        }
    }

    /// Builds a `SpaceInfo` from one Space dictionary. `ManagedSpaceID` is
    /// the ID; `id64` is the fallback.
    static func spaceInfo(_ dict: [String: Any]) -> SpaceInfo? {
        let raw = (dict["ManagedSpaceID"] as? NSNumber) ?? (dict["id64"] as? NSNumber)
        guard let raw, raw.uint64Value != 0 else { return nil }
        let type = (dict["type"] as? NSNumber)?.int32Value ?? 0
        return SpaceInfo(id: SpaceID(raw.uint64Value), type: type)
    }

    /// Full Space list (fullscreen entries included) of one display.
    static func spaces(ofDisplay id: DisplayID, _ sl: SkyLight = .shared) -> [SpaceInfo]? {
        let name = skyLightIdentifier(for: id)
        return rawDisplays(sl).first { $0.identifier.caseInsensitiveCompare(name) == .orderedSame }?.spaces
    }

    /// `SLSManagedDisplayGetCurrentSpace`. Returns nil for zero or a missing symbol.
    static func currentSpace(of display: DisplayID, _ sl: SkyLight = .shared) -> SpaceID? {
        guard let fn = sl.managedDisplayGetCurrentSpace else { return nil }
        let sid = fn(sl.cid, skyLightIdentifier(for: display) as CFString)
        return sid == 0 ? nil : SpaceID(sid)
    }

    /// `SLSManagedDisplayIsAnimating`. False when the symbol is absent.
    static func isAnimating(_ display: DisplayID, _ sl: SkyLight = .shared) -> Bool {
        guard let fn = sl.managedDisplayIsAnimating else { return false }
        return fn(sl.cid, skyLightIdentifier(for: display) as CFString)
    }

    /// `SLSCopySpacesForWindows` with mask 0x7 for one window.
    static func spaces(ofWindow w: WindowID, _ sl: SkyLight = .shared) -> [SpaceID] {
        guard let fn = sl.copySpacesForWindows else { return [] }
        let list = [NSNumber(value: w.raw)] as CFArray
        guard let result = fn(sl.cid, allSpacesMask, list)?.takeRetainedValue() as? [NSNumber] else {
            return []
        }
        return result.map { SpaceID($0.uint64Value) }
    }

    /// Polls the current Space of `display` until it equals `target`.
    /// Interval 30 ms. Returns false after `timeoutMs`.
    @MainActor
    static func waitForCurrentSpace(_ target: SpaceID, on display: DisplayID, timeoutMs: Int = 600) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while true {
            if currentSpace(of: display) == target { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// Waits while SkyLight animates `display`. Interval 30 ms.
    @MainActor
    static func waitWhileAnimating(_ display: DisplayID, timeoutMs: Int = 600) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while isAnimating(display), Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// Waits until `display` stops. The display stops when it does not animate
    /// and shows the same current Space for `stablePolls` polls in a row, each
    /// `pollMs` apart. A burst of Dock swipes reports every hop as the current
    /// Space, so one reading in the middle of a burst does not count.
    ///
    /// Returns the stable Space. Returns `target` at once when the display
    /// reaches it. After `capMs` the function returns the last reading.
    @MainActor
    static func waitForStableSpace(on display: DisplayID, target: SpaceID? = nil,
                                   pollMs: Int = 100, stablePolls: Int = 3, capMs: Int = 3000) async -> SpaceID? {
        let deadline = Date().addingTimeInterval(Double(capMs) / 1000)
        var last = currentSpace(of: display)
        var same = 0
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollMs) * 1_000_000)
            let now = currentSpace(of: display)
            if let target, now == target { return now }
            if now == last, !isAnimating(display) {
                same += 1
                if same >= stablePolls { return now }
            } else {
                same = 0
                last = now
            }
        }
        return last
    }

    /// Polls `SLSCopySpacesForWindows` until it lists `target`.
    /// Interval 30 ms. Returns false after `timeoutMs`.
    @MainActor
    static func waitForWindow(_ w: WindowID, on target: SpaceID, timeoutMs: Int = 500) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while true {
            if spaces(ofWindow: w).contains(target) { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }
}

// MARK: - Space manager

/// Reads Space state and runs switch and move strategies.
///
/// Order of switch strategies: `GestureSwitch`, then `ControlKeySwitch`.
/// Order of move strategies: `BridgedMove`, `CompatIDMove`, `ManagedSpaceMove`.
/// The manager caches the first strategy that verifies. One switch runs at a
/// time; only the latest queued request stays.
@MainActor
public final class SpaceManager {
    public let skyLight: SkyLight
    public private(set) var switchStrategies: [SpaceSwitchStrategy]
    public private(set) var moveStrategies: [WindowMoveStrategy]

    /// Called after a verified Space switch or move. Debounce before refresh.
    public var onSpaceChange: (() -> Void)?

    /// Outcome of the last `switchTo(userSpace:on:)` call.
    public private(set) var lastSwitchOutcome: SpaceSwitchOutcome?
    /// Count of Spaces that the last `ensureSpaces` call created.
    public private(set) var lastCreatedSpaceCount: Int = 0
    /// Name of the switch strategy that verified last. The manager tries it first.
    public private(set) var cachedSwitchStrategy: String?
    /// Name of the move strategy that verified last. The manager tries it first.
    public private(set) var cachedMoveStrategy: String?

    private let log = Logger(subsystem: "com.simplewm.app", category: "spaces")
    private var switchBusy = false
    private var switchGeneration = 0

    public init(skyLight: SkyLight = .shared,
                switchStrategies: [SpaceSwitchStrategy] = [],
                moveStrategies: [WindowMoveStrategy] = []) {
        self.skyLight = skyLight
        self.switchStrategies = switchStrategies
        self.moveStrategies = moveStrategies
    }

    /// Reads `SLSCopyManagedDisplaySpaces` and builds one snapshot per display.
    ///
    /// Geometry comes from `NSScreen` (matched by display UUID). A display
    /// without geometry is skipped.
    ///
    /// With shared Spaces ("Displays have separate Spaces" off), SkyLight lists
    /// one display named `Main`. The manager then builds one snapshot per
    /// physical screen. Each snapshot has the screen UUID as `id`, the screen
    /// geometry, and the shared Space list. So the tree of each screen stays
    /// apart, and a layout never uses the geometry of another screen.
    public func displays() -> [DisplaySnapshot] {
        let raw = SpaceReader.rawDisplays(skyLight)
        guard !raw.isEmpty else { return [] }
        let infos = DisplayManager.currentDisplays()
        var result: [DisplaySnapshot] = []
        var shared = Set<String>()
        for entry in raw {
            let id = DisplayID(entry.identifier)
            guard let current = currentSpaceInfo(of: entry, id: id) else { continue }
            if entry.identifier == "Main" {
                let screens = infos.isEmpty ? (DisplayManager.mainDisplayInfo().map { [$0] } ?? []) : infos
                for info in screens {
                    shared.insert(info.id.uuid.uppercased())
                    result.append(DisplaySnapshot(id: info.id,
                                                  cgID: info.cgID,
                                                  frame: info.frame,
                                                  workArea: info.visibleFrame,
                                                  spaces: entry.spaces,
                                                  current: current))
                }
                continue
            }
            let info = infos.first { $0.id.uuid.caseInsensitiveCompare(entry.identifier) == .orderedSame }
                ?? DisplayManager.cgDisplayInfo(uuid: entry.identifier)
            guard let info else {
                log.debug("No geometry for display \(entry.identifier, privacy: .public)")
                continue
            }
            result.append(DisplaySnapshot(id: id,
                                          cgID: info.cgID,
                                          frame: info.frame,
                                          workArea: info.visibleFrame,
                                          spaces: entry.spaces,
                                          current: current))
        }
        SpaceReader.sharedScreens = shared
        return result
    }

    /// Current Space of one SkyLight display entry. The live reading wins over
    /// the entry. Returns nil when neither source has a Space.
    private func currentSpaceInfo(of entry: RawDisplaySpaces, id: DisplayID) -> SpaceInfo? {
        let liveCurrent = SpaceReader.currentSpace(of: id, skyLight)
        if let liveCurrent, let match = entry.spaces.first(where: { $0.id == liveCurrent }) {
            return match
        }
        if let c = entry.current {
            return entry.spaces.first { $0.id == c.id } ?? c
        }
        if let liveCurrent {
            let type = skyLight.spaceGetType?(skyLight.cid, liveCurrent.raw) ?? 0
            return SpaceInfo(id: liveCurrent, type: type)
        }
        return nil
    }

    /// Every Space that SkyLight lists now, with the displays that own it.
    ///
    /// The function reads the raw SkyLight list, so a display without screen
    /// geometry still counts. With shared Spaces, every screen owns every
    /// Space. The controller uses the result to move and prune trees.
    public func liveSpaceOwners() -> [SpaceID: Set<DisplayID>] {
        var owners: [SpaceID: Set<DisplayID>] = [:]
        for entry in SpaceReader.rawDisplays(skyLight) {
            let displays: Set<DisplayID>
            if entry.identifier == "Main" {
                let screens = DisplayManager.currentDisplays().map(\.id)
                displays = screens.isEmpty ? [DisplayID("Main")] : Set(screens)
            } else {
                displays = [DisplayID(entry.identifier)]
            }
            for space in entry.spaces { owners[space.id, default: []].formUnion(displays) }
        }
        return owners
    }

    /// True while a Space switch runs. A refresh that reads the on-screen
    /// windows now sees a half-finished switch.
    public var isSwitching: Bool { switchBusy }

    /// True while SkyLight animates the Space change of `display`.
    public func isAnimating(_ display: DisplayID) -> Bool {
        SpaceReader.isAnimating(display, skyLight)
    }

    /// True while SkyLight animates any display.
    public func isAnyDisplayAnimating() -> Bool {
        SpaceReader.rawDisplays(skyLight).contains {
            SpaceReader.isAnimating(DisplayID($0.identifier), skyLight)
        }
    }

    /// Current Space of `display` from `SLSManagedDisplayGetCurrentSpace`.
    public func currentSpace(of display: DisplayID) -> SpaceID? {
        SpaceReader.currentSpace(of: display, skyLight)
    }

    /// Display that holds `w` (`SLSCopyManagedDisplayForWindow`).
    public func display(of w: WindowID) -> DisplayID? {
        guard let fn = skyLight.copyManagedDisplayForWindow,
              let s = fn(skyLight.cid, w.raw)?.takeRetainedValue() as String?,
              !s.isEmpty
        else { return nil }
        return DisplayID(s)
    }

    /// Display with the active menu bar (`SLSCopyActiveMenuBarDisplayIdentifier`).
    public func activeMenuBarDisplay() -> DisplayID? {
        guard let fn = skyLight.copyActiveMenuBarDisplayIdentifier,
              let s = fn(skyLight.cid)?.takeRetainedValue() as String?,
              !s.isEmpty
        else { return nil }
        return DisplayID(s)
    }

    /// Spaces that hold `w` (`SLSCopySpacesForWindows`, mask 0x7).
    public func spaces(of w: WindowID) -> [SpaceID] {
        SpaceReader.spaces(ofWindow: w, skyLight)
    }

    /// Switches `display` to its Nth user Space (1-based). Does nothing when
    /// N exceeds the count. Never creates a Space: call `ensureSpaces` first.
    ///
    /// Returns true when the target Space is current after the call. A newer
    /// request replaces an older request that still waits; the older request
    /// returns false with outcome `.superseded`. Read `lastSwitchOutcome`
    /// to tell a no-op from a failure.
    public func switchTo(userSpace n: Int, on display: DisplaySnapshot) async -> Bool {
        switchGeneration += 1
        let generation = switchGeneration
        while switchBusy {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if generation != switchGeneration {
                log.debug("Switch to Space \(n) superseded")
                lastSwitchOutcome = .superseded
                return false
            }
        }
        switchBusy = true
        defer { switchBusy = false }

        let outcome = await performSwitch(userSpace: n, on: display)
        lastSwitchOutcome = outcome
        switch outcome {
        case .switched:
            onSpaceChange?()
            return true
        case .alreadyCurrent:
            return true
        case .outOfRange, .superseded, .failed:
            return false
        }
    }

    /// Most Spaces per display that `ensureSpaces` creates. It matches the
    /// largest N of `space N`.
    public static let maxSpaceCount = 9

    /// Creates desktops on `display` until it lists at least `n` Spaces.
    ///
    /// The cap for `n` is `maxSpaceCount`. The function creates at most
    /// `maxSpaceCount` minus the current count of Spaces, one by one, and
    /// reads the display again after each one. It does nothing when the
    /// display has enough Spaces. It does not switch Spaces and does not
    /// move windows: `switchTo(userSpace:on:)` and `move(_:toUserSpace:on:)`
    /// stay as they are. The caller runs them with the fresh snapshot.
    ///
    /// The function holds the switch lock while it runs. A Space switch waits
    /// for it. A tiling refresh waits for it too, because Mission Control is
    /// open for a moment.
    ///
    /// Returns the fresh snapshot, or nil when a creation fails.
    public func ensureSpaces(count n: Int, on display: DisplaySnapshot, creator: SpaceCreator) async -> DisplaySnapshot? {
        let wanted = min(n, Self.maxSpaceCount)
        // Wait for a running switch or creation. A stuck flag cannot block forever.
        let waitUntil = Date().addingTimeInterval(8)
        while switchBusy, Date() < waitUntil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard !switchBusy else {
            log.error("Create Spaces: the switch lock stays busy. Request dropped.")
            return nil
        }
        switchBusy = true
        defer { switchBusy = false }

        lastCreatedSpaceCount = 0
        var fresh = displays().first { $0.id == display.id } ?? display
        let budget = max(0, Self.maxSpaceCount - fresh.spaces.count)
        var created = 0
        while fresh.spaces.count < wanted {
            guard created < budget else {
                log.error("Create Spaces: the cap of \(budget, privacy: .public) new Spaces is reached.")
                return nil
            }
            guard await creator.createSpace(on: fresh) != nil else {
                log.error("Create Spaces: creation \(created + 1, privacy: .public) failed on \(fresh.id.uuid, privacy: .public).")
                return nil
            }
            created += 1
            lastCreatedSpaceCount = created
            guard let next = displays().first(where: { $0.id == display.id }) else {
                log.error("Create Spaces: display \(display.id.uuid, privacy: .public) is gone after creation.")
                return nil
            }
            fresh = next
        }
        if created > 0 {
            log.info("Created \(created, privacy: .public) Space(s) on \(fresh.id.uuid, privacy: .public). The display has \(fresh.spaces.count, privacy: .public).")
        }
        return fresh
    }

    private func performSwitch(userSpace n: Int, on display: DisplaySnapshot) async -> SpaceSwitchOutcome {
        // Read a fresh snapshot: the caller's snapshot can be old.
        let fresh = displays().first { $0.id == display.id } ?? display
        let all = fresh.spaces
        guard n >= 1, n <= all.count else {
            log.info("Space \(n) does not exist on \(fresh.id.uuid, privacy: .public) (\(all.count) Spaces)")
            return .outOfRange
        }
        let target = all[n - 1].id
        if currentSpace(of: fresh.id) == target { return .alreadyCurrent }

        let ordered = orderedSwitchStrategies()
        for strategy in ordered where strategy.isAvailable() {
            if await strategy.switchTo(target, on: fresh) {
                if cachedSwitchStrategy != strategy.name {
                    log.info("Space switch strategy: \(strategy.name, privacy: .public)")
                }
                cachedSwitchStrategy = strategy.name
                return .switched(strategy: strategy.name)
            }
            log.warning("Space switch strategy \(strategy.name, privacy: .public) failed for \(target.description, privacy: .public)")
            // Stop when the display reached the target late.
            if currentSpace(of: fresh.id) == target {
                return .switched(strategy: strategy.name)
            }
        }
        log.error("Space switch to \(n) on \(fresh.id.uuid, privacy: .public) failed: no strategy verified")
        return .failed
    }

    private func orderedSwitchStrategies() -> [SpaceSwitchStrategy] {
        guard let cached = cachedSwitchStrategy,
              let first = switchStrategies.first(where: { $0.name == cached })
        else { return switchStrategies }
        return [first] + switchStrategies.filter { $0 !== first }
    }

    private func orderedMoveStrategies() -> [WindowMoveStrategy] {
        guard let cached = cachedMoveStrategy,
              let first = moveStrategies.first(where: { $0.name == cached })
        else { return moveStrategies }
        return [first] + moveStrategies.filter { $0 !== first }
    }

    /// Moves `w` to the Nth user Space of its display (1-based).
    ///
    /// Returns true when `SLSCopySpacesForWindows` lists the target Space.
    /// Returns true without a move when `w` is already on the target.
    public func move(_ w: WindowID, toUserSpace n: Int, on display: DisplaySnapshot) async -> Bool {
        let fresh = displays().first { $0.id == display.id } ?? display
        let all = fresh.spaces
        guard n >= 1, n <= all.count, all[n - 1].isUser else {
            log.info("Space \(n) is not a normal desktop on \(fresh.id.uuid, privacy: .public); window \(w.description, privacy: .public) stays")
            return false
        }
        let target = all[n - 1].id
        if spaces(of: w).contains(target) { return true }

        for strategy in orderedMoveStrategies() where strategy.isAvailable() {
            if await strategy.move(w, to: target) {
                if cachedMoveStrategy != strategy.name {
                    log.info("Window move strategy: \(strategy.name, privacy: .public)")
                }
                cachedMoveStrategy = strategy.name
                onSpaceChange?()
                return true
            }
            log.warning("Window move strategy \(strategy.name, privacy: .public) failed for \(w.description, privacy: .public) -> \(target.description, privacy: .public)")
        }
        // A bridged move only queues its operation. It can land after its wait
        // ends. Look once more before the call reports a failure.
        try? await Task.sleep(nanoseconds: 300_000_000)
        if spaces(of: w).contains(target) {
            let late = orderedMoveStrategies().first { $0.isAvailable() }?.name
            log.notice("Window move of \(w.description, privacy: .public) landed late. It counts as a success.")
            if let late { cachedMoveStrategy = late }
            onSpaceChange?()
            return true
        }
        log.error("Window move of \(w.description, privacy: .public) to Space \(n) failed: no strategy verified")
        return false
    }
}

// MARK: - Switch strategies

/// Synthetic Dock swipe (yabai v7.1.19 method). Primary strategy.
/// It warps the cursor to the target display, posts one swipe per step,
/// and polls `SLSManagedDisplayGetCurrentSpace` (30 ms). The wait grows with
/// the step count: 300 ms plus 250 ms per step, at least 600 ms.
/// It repeats at most two rounds, then restores the cursor.
///
/// A burst of swipes reports every hop as the current Space. Round 2 starts
/// only after the display stops: not animating, and the same Space for three
/// polls 100 ms apart. So round 2 never adds swipes on top of queued hops.
@MainActor
public final class GestureSwitch: SpaceSwitchStrategy {
    public let name = "gesture"
    /// `true`: warp the cursor to the target display for the swipes.
    /// `false`: do not warp. The event location points at the target display
    /// instead. The Dock can ignore that location. When a round moves nothing,
    /// the next round warps the cursor anyway.
    public var warpCursor: Bool
    /// Sign multiplier for swipe progress. The strategy flips it when a
    /// round moves the display the wrong way.
    public private(set) var directionFactor: Double = 1

    private let log = Logger(subsystem: "com.simplewm.app", category: "gesture")
    private static let maxRounds = 2

    // CGEvent field numbers from yabai v7.1.19 (private).
    private static let fieldEventType: UInt32 = 55          // kCGSEventTypeField
    private static let fieldGestureHIDType: UInt32 = 110    // kCGEventGestureHIDType
    private static let fieldSwipeMotion: UInt32 = 123       // kCGEventGestureSwipeMotion
    private static let fieldSwipeProgress: UInt32 = 124     // kCGEventGestureSwipeProgress
    private static let fieldSwipeVelocityX: UInt32 = 129    // kCGEventGestureSwipeVelocityX
    private static let fieldGesturePhase: UInt32 = 132      // kCGEventGesturePhase
    private static let dockControlEventType: Int64 = 30     // kCGSEventDockControl
    private static let dockSwipeHIDType: Int64 = 23         // kIOHIDEventTypeDockSwipe
    private static let swipeMotionHorizontal: Int64 = 1
    private static let phaseBegan: Int64 = 1
    private static let phaseEnded: Int64 = 4

    public init(warpCursor: Bool = true) { self.warpCursor = warpCursor }

    public func isAvailable() -> Bool {
        let sl = SkyLight.shared
        return sl.copyManagedDisplaySpaces != nil && sl.managedDisplayGetCurrentSpace != nil
    }

    /// Verification wait for one round: 300 ms plus 250 ms per step, at least 600 ms.
    static func verifyTimeoutMs(steps: Int) -> Int {
        max(600, 300 + 250 * steps)
    }

    /// True when `point` lies on `display`. Uses `CGGetDisplaysWithPoint`, so
    /// the shared edge of two displays belongs to one display only.
    static func isCursor(_ point: CGPoint, on display: DisplaySnapshot) -> Bool {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 {
            return id == display.cgID
        }
        return display.frame.contains(x: Double(point.x), y: Double(point.y))
    }

    public func switchTo(_ target: SpaceID, on display: DisplaySnapshot) async -> Bool {
        guard isAvailable() else { return false }

        // Warp only when the cursor is on another display.
        var restorePoint: CGPoint?
        func warpIfNeeded() {
            guard let here = CGEvent(source: nil)?.location, !Self.isCursor(here, on: display) else { return }
            if restorePoint == nil { restorePoint = here }
            CGWarpMouseCursorPosition(CGPoint(x: display.frame.midX, y: display.frame.midY))
            // Cancel the short local-event suppression after a warp.
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        if warpCursor { warpIfNeeded() }
        defer {
            if let p = restorePoint {
                CGWarpMouseCursorPosition(p)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }

        var lastRoundMoved = true
        for round in 1...Self.maxRounds {
            // yabai refuses to switch while the display animates. Wait instead.
            await SpaceReader.waitWhileAnimating(display.id, timeoutMs: 600)
            let spaces = SpaceReader.spaces(ofDisplay: display.id)?.map(\.id) ?? display.spaces.map(\.id)
            guard let current = SpaceReader.currentSpace(of: display.id) else { return false }
            if current == target { return true }
            guard let targetIndex = spaces.firstIndex(of: target),
                  let currentIndex = spaces.firstIndex(of: current)
            else {
                log.warning("Gesture: Space \(target.description, privacy: .public) or \(current.description, privacy: .public) not in list")
                return false
            }
            let delta = targetIndex - currentIndex
            let sign: Double = delta > 0 ? 1 : -1
            let steps = abs(delta)

            // Without a warp the Dock may act on the display under the real
            // cursor. When the last round moved nothing, warp now.
            if warpCursor || !lastRoundMoved {
                if !warpCursor { log.notice("Gesture: no move without a warp. Warping the cursor (round \(round)).") }
                warpIfNeeded()
            }
            postSwipes(steps: steps, sign: sign * directionFactor, at: display)

            if await SpaceReader.waitForCurrentSpace(target, on: display.id,
                                                     timeoutMs: Self.verifyTimeoutMs(steps: steps)) {
                return true
            }
            // The burst can still run. Wait until the display stops. Then read.
            let settled = await SpaceReader.waitForStableSpace(on: display.id, target: target)
            if settled == target { return true }

            guard let after = settled, let afterIndex = spaces.firstIndex(of: after) else { return false }
            lastRoundMoved = afterIndex != currentIndex
            // Learn the swipe direction when the display moved the wrong way.
            if lastRoundMoved, (afterIndex - currentIndex > 0) != (delta > 0) {
                directionFactor = -directionFactor
                log.notice("Gesture: swipe direction flipped (round \(round))")
            }
        }
        return false
    }

    /// Posts `steps` swipe pairs (began, ended) to the session event tap.
    private func postSwipes(steps: Int, sign: Double, at display: DisplaySnapshot) {
        guard steps > 0, let event = CGEvent(source: nil) else { return }
        func setInt(_ field: UInt32, _ value: Int64) {
            guard let f = CGEventField(rawValue: field) else { return }
            event.setIntegerValueField(f, value: value)
        }
        func setDouble(_ field: UInt32, _ value: Double) {
            guard let f = CGEventField(rawValue: field) else { return }
            event.setDoubleValueField(f, value: value)
        }
        // With a warp, the event keeps the real cursor location (yabai does
        // the same). When the cursor stays on another display, point the event
        // at the target display. The Dock can ignore this hint.
        if !Self.isCursor(event.location, on: display) {
            event.location = CGPoint(x: display.frame.midX, y: display.frame.midY)
        }
        setInt(Self.fieldEventType, Self.dockControlEventType)
        setInt(Self.fieldGestureHIDType, Self.dockSwipeHIDType)
        setInt(Self.fieldSwipeMotion, Self.swipeMotionHorizontal)
        setDouble(Self.fieldSwipeProgress, sign)
        setDouble(Self.fieldSwipeVelocityX, sign * 9999.0)
        for _ in 0..<steps {
            setInt(Self.fieldGesturePhase, Self.phaseBegan)
            event.post(tap: .cgSessionEventTap)
            setInt(Self.fieldGesturePhase, Self.phaseEnded)
            event.post(tap: .cgSessionEventTap)
        }
    }
}

/// Posts Ctrl+N as a CGEvent. Runs only when "Switch to Desktop N" is enabled
/// in `com.apple.symbolichotkeys` (IDs 118...126). Mission Control may count
/// fullscreen Spaces, so the strategy verifies the result.
///
/// N is the global index of the target among user Spaces of all displays, in
/// `SLSCopyManagedDisplaySpaces` order. Mission Control numbers desktops across
/// displays this way. The key code and modifiers come from the shortcut entry.
@MainActor
public final class ControlKeySwitch: SpaceSwitchStrategy {
    public let name = "ctrl-n"
    private let log = Logger(subsystem: "com.simplewm.app", category: "ctrl-n")

    /// First symbolic hotkey ID: "Switch to Desktop 1".
    static let firstHotKeyID = 118
    /// Mission Control offers shortcuts for desktops 1...16 (IDs 118...133).
    static let maxDesktop = 16

    public init() {}

    public func isAvailable() -> Bool {
        let sl = SkyLight.shared
        guard sl.copyManagedDisplaySpaces != nil, sl.managedDisplayGetCurrentSpace != nil else { return false }
        let table = Self.readHotKeys()
        return (1...9).contains { Self.shortcut(desktop: $0, in: table) != nil }
    }

    public func switchTo(_ target: SpaceID, on display: DisplaySnapshot) async -> Bool {
        guard let n = Self.desktopNumber(of: target) else {
            log.warning("Ctrl-N: Space \(target.description, privacy: .public) has no desktop number")
            return false
        }
        guard let key = Self.shortcut(desktop: n, in: Self.readHotKeys()) else {
            log.info("Ctrl-N: shortcut for Desktop \(n) is disabled")
            return false
        }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: key.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: key.keyCode, keyDown: false)
        else { return false }
        down.flags = key.flags
        up.flags = key.flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return await SpaceReader.waitForCurrentSpace(target, on: display.id, timeoutMs: 600)
    }

    /// Global 1-based index of `target` among user Spaces of all displays.
    static func desktopNumber(of target: SpaceID) -> Int? {
        var n = 0
        for display in SpaceReader.rawDisplays() {
            for space in display.spaces where space.isUser {
                n += 1
                if space.id == target { return n <= maxDesktop ? n : nil }
            }
        }
        return nil
    }

    /// Key code and flags of one "Switch to Desktop N" shortcut.
    struct Shortcut {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    /// Reads `AppleSymbolicHotKeys` from `com.apple.symbolichotkeys`.
    static func readHotKeys() -> [String: Any] {
        let app = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(app)
        guard let value = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, app),
              let dict = value as? [String: Any]
        else { return [:] }
        return dict
    }

    /// Returns the enabled shortcut for desktop `n`, or nil. A missing entry
    /// counts as disabled (the macOS default).
    static func shortcut(desktop n: Int, in table: [String: Any]) -> Shortcut? {
        guard (1...maxDesktop).contains(n),
              let entry = table[String(firstHotKeyID + n - 1)] as? [String: Any],
              (entry["enabled"] as? NSNumber)?.boolValue == true
        else { return nil }
        // Default: Ctrl + digit row key (kVK_ANSI_1 ... kVK_ANSI_9).
        let digitCodes: [CGKeyCode] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]
        var keyCode: CGKeyCode? = n <= 9 ? digitCodes[n - 1] : nil
        var flags: CGEventFlags = .maskControl
        if let value = entry["value"] as? [String: Any],
           let params = value["parameters"] as? [NSNumber], params.count >= 3 {
            let code = params[1].intValue
            if code >= 0, code < 0xFFFF { keyCode = CGKeyCode(code) }
            let mods = params[2].uint64Value
            if mods != 0 { flags = CGEventFlags(rawValue: mods) }
        }
        guard let keyCode else { return nil }
        return Shortcut(keyCode: keyCode, flags: flags)
    }
}

// MARK: - Move strategies

/// `SLSBridgedMoveWindowsToManagedSpaceOperation` run by the file-local
/// `SLSPerformAsynchronousBridgedWindowManagementOperation`.
///
/// The operation is built with the Objective-C runtime: `+alloc`, then
/// `-initWithWindows:spaceID:`. The window list holds `NSNumber` values.
@MainActor
public final class BridgedMove: WindowMoveStrategy {
    public let name = "bridged"
    private let log = Logger(subsystem: "com.simplewm.app", category: "move")

    static let className = "SLSBridgedMoveWindowsToManagedSpaceOperation"
    static let initSelector = NSSelectorFromString("initWithWindows:spaceID:")

    typealias AllocFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
    typealias InitFn = @convention(c) (Unmanaged<AnyObject>, Selector, NSArray, UInt64) -> Unmanaged<AnyObject>?

    public init() {}

    public func isAvailable() -> Bool {
        let sl = SkyLight.shared
        guard sl.performBridgedOperation != nil, sl.copySpacesForWindows != nil,
              let cls = NSClassFromString(Self.className)
        else { return false }
        return class_getInstanceMethod(cls, Self.initSelector) != nil
    }

    public func move(_ w: WindowID, to target: SpaceID) async -> Bool {
        guard isAvailable(),
              let perform = SkyLight.shared.performBridgedOperation,
              let op = makeOperation(windows: [w], space: target)
        else { return false }
        _ = perform(op)
        // The call only queues the operation. Give it time to land.
        return await SpaceReader.waitForWindow(w, on: target, timeoutMs: 800)
    }

    /// Creates the operation object. Returns nil when the runtime refuses.
    func makeOperation(windows: [WindowID], space: SpaceID) -> AnyObject? {
        guard let cls = NSClassFromString(Self.className),
              let meta = object_getClass(cls)
        else { return nil }
        let allocSel = NSSelectorFromString("alloc")
        guard class_getInstanceMethod(meta, allocSel) != nil,
              class_getInstanceMethod(cls, Self.initSelector) != nil,
              let allocIMP = class_getMethodImplementation(meta, allocSel),
              let initIMP = class_getMethodImplementation(cls, Self.initSelector)
        else { return nil }
        let alloc = unsafeBitCast(allocIMP, to: AllocFn.self)
        let initialize = unsafeBitCast(initIMP, to: InitFn.self)
        // `alloc` returns +1. `init` consumes it and returns +1.
        guard let allocated = alloc(cls, allocSel) else { return nil }
        let list = windows.map { NSNumber(value: Int32(bitPattern: $0.raw)) } as NSArray
        guard let op = initialize(allocated, Self.initSelector, list, space.raw) else {
            log.warning("Bridged: initWithWindows:spaceID: returned nil")
            return nil
        }
        return op.takeRetainedValue()
    }
}

/// Compat-ID trick: `SLSSpaceSetCompatID(sid, 0x79616265)`,
/// `SLSSetWindowListWorkspace`, `SLSSpaceSetCompatID(sid, 0)`.
@MainActor
public final class CompatIDMove: WindowMoveStrategy {
    public let name = "compat-id"
    /// Temporary workspace number ("yabe", from yabai).
    static let compatID: Int32 = 0x79616265
    private let log = Logger(subsystem: "com.simplewm.app", category: "move")

    public init() {}

    public func isAvailable() -> Bool {
        let sl = SkyLight.shared
        return sl.spaceSetCompatID != nil && sl.setWindowListWorkspace != nil && sl.copySpacesForWindows != nil
    }

    public func move(_ w: WindowID, to target: SpaceID) async -> Bool {
        let sl = SkyLight.shared
        guard sl.spaceSetCompatID != nil, sl.setWindowListWorkspace != nil,
              sl.copySpacesForWindows != nil
        else { return false }
        let before = SpaceReader.spaces(ofWindow: w)
        guard apply(w, to: target) else { return false }
        if await SpaceReader.waitForWindow(w, on: target, timeoutMs: 500) { return true }
        // No Space lists the window now: the window is orphaned. Put it back.
        if SpaceReader.spaces(ofWindow: w).isEmpty, let home = before.first {
            log.warning("Compat-ID: no Space lists \(w.description, privacy: .public). Moving it back to \(home.description, privacy: .public).")
            _ = apply(w, to: home)
        }
        return false
    }

    /// Runs the three calls for one window. Returns false, without a move,
    /// when `SLSSpaceSetCompatID` fails: then no Space owns the temporary
    /// number, and a move to it could orphan the window.
    private func apply(_ w: WindowID, to space: SpaceID) -> Bool {
        let sl = SkyLight.shared
        guard let setCompat = sl.spaceSetCompatID, let setWorkspace = sl.setWindowListWorkspace else { return false }
        let e1 = setCompat(sl.cid, space.raw, Self.compatID)
        guard e1 == .success else {
            // Clear the compat ID also after an error.
            _ = setCompat(sl.cid, space.raw, 0)
            log.warning("Compat-ID: SLSSpaceSetCompatID failed (status \(e1.rawValue)). The window stays.")
            return false
        }
        var wid = w.raw
        let e2 = setWorkspace(sl.cid, &wid, 1, Self.compatID)
        // Always clear the compat ID, also after an error.
        let e3 = setCompat(sl.cid, space.raw, 0)
        if e2 != .success || e3 != .success {
            log.warning("Compat-ID: status \(e1.rawValue) \(e2.rawValue) \(e3.rawValue)")
        }
        return true
    }
}

/// Plain `SLSMoveWindowsToManagedSpace`. Known to fail silently on 14.5+.
@MainActor
public final class ManagedSpaceMove: WindowMoveStrategy {
    public let name = "managed-space"
    public init() {}

    public func isAvailable() -> Bool {
        let sl = SkyLight.shared
        return sl.moveWindowsToManagedSpace != nil && sl.copySpacesForWindows != nil
    }

    public func move(_ w: WindowID, to target: SpaceID) async -> Bool {
        let sl = SkyLight.shared
        guard let fn = sl.moveWindowsToManagedSpace else { return false }
        let list = [NSNumber(value: Int32(bitPattern: w.raw))] as CFArray
        fn(sl.cid, list, target.raw)
        return await SpaceReader.waitForWindow(w, on: target, timeoutMs: 500)
    }
}
