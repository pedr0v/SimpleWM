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
    /// The manager subscribes when this property gets a value.
    public var onChange: (() -> Void)? {
        didSet { updateSubscription() }
    }

    private var token: NSObjectProtocol?

    public init() {}

    /// All displays. Order follows `NSScreen.screens`.
    public func displays() -> [DisplayInfo] {
        Self.currentDisplays()
    }

    /// Display that contains the mouse pointer.
    public func displayUnderMouse() -> DisplayInfo? {
        let all = Self.currentDisplays()
        guard let p = CGEvent(source: nil)?.location else { return all.first }
        let x = Double(p.x), y = Double(p.y)
        return all.first { $0.frame.contains(x: x, y: y) }
    }

    /// `NSScreen.screensHaveSeparateSpaces`. Read after `NSApplication.shared` exists.
    public var screensHaveSeparateSpaces: Bool {
        NSScreen.screensHaveSeparateSpaces
    }

    /// Converts an AppKit frame (bottom-left origin) to AX coordinates.
    ///
    /// The reference is the screen with origin (0, 0), else the first screen.
    public static func axRect(fromAppKit frame: CGRect) -> Rect {
        let screens = NSScreen.screens
        let primary = screens.first { $0.frame.origin == .zero } ?? screens.first
        let primaryMaxY = primary?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
        return Rect(x: Double(frame.minX),
                    y: Double(primaryMaxY - frame.maxY),
                    w: Double(frame.width),
                    h: Double(frame.height))
    }

    // MARK: Helpers

    /// All displays, without an instance. Order follows `NSScreen.screens`.
    public static func currentDisplays() -> [DisplayInfo] {
        NSScreen.screens.compactMap(info(for:))
    }

    /// Display of `NSScreen.main` (the screen with the key window or the menu bar).
    public static func mainDisplayInfo() -> DisplayInfo? {
        (NSScreen.main ?? NSScreen.screens.first).flatMap(info(for:))
    }

    /// Builds the info for one screen. Returns nil when the screen has no display ID.
    public static func info(for screen: NSScreen) -> DisplayInfo? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        let cgID = CGDirectDisplayID(number.uint32Value)
        guard let uuid = uuidString(for: cgID) else { return nil }
        return DisplayInfo(id: DisplayID(uuid),
                           cgID: cgID,
                           frame: rect(CGDisplayBounds(cgID)),
                           visibleFrame: axRect(fromAppKit: screen.visibleFrame))
    }

    /// Display UUID string that SkyLight uses as `Display Identifier`.
    public static func uuidString(for cgID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(cgID)?.takeRetainedValue(),
              let s = CFUUIDCreateString(nil, uuid)
        else { return nil }
        return s as String
    }

    /// Fallback for a display that SkyLight lists but `NSScreen` does not.
    /// Uses `CGDisplayBounds` for both frames.
    public static func cgDisplayInfo(uuid: String) -> DisplayInfo? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        for cgID in ids.prefix(Int(count)) {
            guard let s = uuidString(for: cgID), s.caseInsensitiveCompare(uuid) == .orderedSame else { continue }
            let r = rect(CGDisplayBounds(cgID))
            return DisplayInfo(id: DisplayID(s), cgID: cgID, frame: r, visibleFrame: r)
        }
        return nil
    }

    static func rect(_ r: CGRect) -> Rect {
        Rect(x: Double(r.minX), y: Double(r.minY), w: Double(r.width), h: Double(r.height))
    }

    private func updateSubscription() {
        if onChange == nil {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            return
        }
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onChange?()
            }
        }
    }
}
