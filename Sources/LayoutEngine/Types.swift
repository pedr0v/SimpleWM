import Foundation

/// Window identifier. It equals the `CGWindowID` that `_AXUIElementGetWindow` returns.
public struct WindowID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: UInt32
    public init(_ raw: UInt32) { self.raw = raw }
    public var description: String { "w\(raw)" }
}

/// Native Space identifier. It equals the `ManagedSpaceID` from `SLSCopyManagedDisplaySpaces`.
public struct SpaceID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: UInt64
    public init(_ raw: UInt64) { self.raw = raw }
    public var description: String { "s\(raw)" }
}

/// Display identifier. It equals the 36-char UUID string from `CGDisplayCreateUUIDFromDisplayID`.
/// When displays share one Space list, macOS reports the single identifier `Main`.
public struct DisplayID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let uuid: String
    public init(_ uuid: String) { self.uuid = uuid }
    public var description: String { uuid }
}

/// Key of one tiling workspace: one native Space on one display.
public struct SpaceKey: Hashable, Sendable, Codable {
    public let display: DisplayID
    public let space: SpaceID
    public init(display: DisplayID, space: SpaceID) {
        self.display = display
        self.space = space
    }
}

/// Rectangle in Accessibility coordinates: origin at the top-left corner of the
/// main display, y grows downward. Values are points.
public struct Rect: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public static let zero = Rect(x: 0, y: 0, w: 0, h: 0)

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + w }
    public var maxY: Double { y + h }
    public var midX: Double { x + w / 2 }
    public var midY: Double { y + h / 2 }

    /// Returns true when the point lies inside the rectangle (edges included).
    public func contains(x px: Double, y py: Double) -> Bool {
        px >= minX && px <= maxX && py >= minY && py <= maxY
    }

    /// Returns the rectangle reduced by `amount` on each side.
    public func inset(by amount: Double) -> Rect {
        Rect(x: x + amount, y: y + amount, w: max(0, w - 2 * amount), h: max(0, h - 2 * amount))
    }

    /// Returns true when every coordinate differs by at most `tolerance`.
    public func isClose(to other: Rect, tolerance: Double) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
            && abs(w - other.w) <= tolerance && abs(h - other.h) <= tolerance
    }
}

/// Axis of a split container. `horizontal` places children left to right.
public enum Orientation: String, Sendable, Codable, CaseIterable {
    case horizontal
    case vertical

    /// The other orientation.
    public var flipped: Orientation {
        self == .horizontal ? .vertical : .horizontal
    }
}

/// Movement direction. Names follow vim keys: h=left, j=down, k=up, l=right.
public enum Direction: String, Sendable, Codable, CaseIterable {
    case left
    case down
    case up
    case right

    /// The container orientation that this direction moves along.
    public var orientation: Orientation {
        switch self {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }

    /// True for `right` and `down` (toward a higher child index).
    public var isForward: Bool {
        self == .right || self == .down
    }

    /// The opposite direction.
    public var opposite: Direction {
        switch self {
        case .left: return .right
        case .right: return .left
        case .up: return .down
        case .down: return .up
        }
    }
}

/// Gap sizes in points. `inner` separates sibling windows. `outer` separates
/// the tree from the display work area.
public struct Gaps: Equatable, Sendable, Codable {
    public var inner: Double
    public var outer: Double
    public init(inner: Double = 8, outer: Double = 8) {
        self.inner = inner
        self.outer = outer
    }
    public static let none = Gaps(inner: 0, outer: 0)
}
