import Foundation
import CoreGraphics
import LayoutEngine

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

    /// Only type-0 Spaces, in order. Option+N indexes this list (1-based).
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

    public init(skyLight: SkyLight = .shared,
                switchStrategies: [SpaceSwitchStrategy] = [],
                moveStrategies: [WindowMoveStrategy] = []) {
        self.skyLight = skyLight
        self.switchStrategies = switchStrategies
        self.moveStrategies = moveStrategies
    }

    /// Reads `SLSCopyManagedDisplaySpaces` and builds one snapshot per display.
    public func displays() -> [DisplaySnapshot] {
        fatalError("TODO")
    }

    /// Current Space of `display` from `SLSManagedDisplayGetCurrentSpace`.
    public func currentSpace(of display: DisplayID) -> SpaceID? {
        fatalError("TODO")
    }

    /// Display that holds `w` (`SLSCopyManagedDisplayForWindow`).
    public func display(of w: WindowID) -> DisplayID? {
        fatalError("TODO")
    }

    /// Display with the active menu bar (`SLSCopyActiveMenuBarDisplayIdentifier`).
    public func activeMenuBarDisplay() -> DisplayID? {
        fatalError("TODO")
    }

    /// Spaces that hold `w` (`SLSCopySpacesForWindows`, mask 0x7).
    public func spaces(of w: WindowID) -> [SpaceID] {
        fatalError("TODO")
    }

    /// Switches `display` to its Nth user Space (1-based). Does nothing when
    /// N exceeds the count. Never creates a Space.
    public func switchTo(userSpace n: Int, on display: DisplaySnapshot) async -> Bool {
        fatalError("TODO")
    }

    /// Moves `w` to the Nth user Space of its display (1-based).
    public func move(_ w: WindowID, toUserSpace n: Int, on display: DisplaySnapshot) async -> Bool {
        fatalError("TODO")
    }
}

/// Synthetic Dock swipe (yabai v7.1.19 method). Primary strategy.
/// It warps the cursor to the target display, posts one swipe per step,
/// and polls `SLSManagedDisplayGetCurrentSpace` (30 ms, 600 ms max).
/// It repeats at most two rounds, then restores the cursor.
@MainActor
public final class GestureSwitch: SpaceSwitchStrategy {
    public let name = "gesture"
    public var warpCursor: Bool
    public init(warpCursor: Bool = true) { self.warpCursor = warpCursor }
    public func isAvailable() -> Bool { fatalError("TODO") }
    public func switchTo(_ target: SpaceID, on display: DisplaySnapshot) async -> Bool { fatalError("TODO") }
}

/// Posts Ctrl+N as a CGEvent. Runs only when "Switch to Desktop N" is enabled
/// in `com.apple.symbolichotkeys` (IDs 118...126). Mission Control may count
/// fullscreen Spaces, so the strategy verifies the result.
@MainActor
public final class ControlKeySwitch: SpaceSwitchStrategy {
    public let name = "ctrl-n"
    public init() {}
    public func isAvailable() -> Bool { fatalError("TODO") }
    public func switchTo(_ target: SpaceID, on display: DisplaySnapshot) async -> Bool { fatalError("TODO") }
}

/// `SLSBridgedMoveWindowsToManagedSpaceOperation` run by the file-local
/// `SLSPerformAsynchronousBridgedWindowManagementOperation`.
@MainActor
public final class BridgedMove: WindowMoveStrategy {
    public let name = "bridged"
    public init() {}
    public func isAvailable() -> Bool { fatalError("TODO") }
    public func move(_ w: WindowID, to target: SpaceID) async -> Bool { fatalError("TODO") }
}

/// Compat-ID trick: `SLSSpaceSetCompatID(sid, 0x79616265)`,
/// `SLSSetWindowListWorkspace`, `SLSSpaceSetCompatID(sid, 0)`.
@MainActor
public final class CompatIDMove: WindowMoveStrategy {
    public let name = "compat-id"
    public init() {}
    public func isAvailable() -> Bool { fatalError("TODO") }
    public func move(_ w: WindowID, to target: SpaceID) async -> Bool { fatalError("TODO") }
}

/// Plain `SLSMoveWindowsToManagedSpace`. Known to fail silently on 14.5+.
@MainActor
public final class ManagedSpaceMove: WindowMoveStrategy {
    public let name = "managed-space"
    public init() {}
    public func isAvailable() -> Bool { fatalError("TODO") }
    public func move(_ w: WindowID, to target: SpaceID) async -> Bool { fatalError("TODO") }
}
