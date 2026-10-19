import AppKit
import LayoutEngine

/// One display as AppKit and CoreGraphics report it.
public struct DisplayInfo: Equatable, Sendable {
    public let id: DisplayID
    public let cgID: CGDirectDisplayID
    /// Full bounds in AX coordinates (`CGDisplayBounds`).
    public let frame: Rect
    /// `NSScreen.visibleFrame` converted to AX coordinates.
    public let visibleFrame: Rect
    public init(id: DisplayID, cgID: CGDirectDisplayID, frame: Rect, visibleFrame: Rect) {
        self.id = id
        self.cgID = cgID
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// Maps `NSScreen` to SkyLight display identifiers.
///
/// UUID: `CFUUIDCreateString(CGDisplayCreateUUIDFromDisplayID(NSScreenNumber))`.
/// AX y = mainScreen.frame.maxY - nsFrame.maxY, where mainScreen is the
/// `NSScreen` with origin (0, 0).
@MainActor
public final class DisplayManager {
    /// Called after `NSApplication.didChangeScreenParametersNotification`.
    public var onChange: (() -> Void)?

    public init() {}

    /// All displays. Order follows `NSScreen.screens`.
    public func displays() -> [DisplayInfo] {
        fatalError("TODO")
    }

    /// Display that contains the mouse pointer.
    public func displayUnderMouse() -> DisplayInfo? {
        fatalError("TODO")
    }

    /// `NSScreen.screensHaveSeparateSpaces`. Read after `NSApplication.shared` exists.
    public var screensHaveSeparateSpaces: Bool {
        NSScreen.screensHaveSeparateSpaces
    }

    /// Converts an AppKit frame (bottom-left origin) to AX coordinates.
    public static func axRect(fromAppKit frame: CGRect) -> Rect {
        fatalError("TODO")
    }
}
