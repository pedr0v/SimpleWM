import Foundation
import LayoutEngine

/// User config at `~/.config/simplewm/config.json`.
///
/// A missing file yields `Config.default`. A bad file keeps the last good
/// config and logs the error. Unknown binding text is logged and skipped.
/// A missing key takes its default value. A present `bindings` object
/// replaces the default bindings. A binding with the command `none` is skipped.
public struct Config: Codable, Equatable {
    public struct SpaceSwitch: Codable, Equatable {
        /// `auto`, `gesture`, or `ctrl-n`.
        public var strategy: String = "auto"
        public var warpCursor: Bool = true
    }

    public var gaps: Gaps = Gaps(inner: 0, outer: 0)
    /// `horizontal`, `vertical`, or `auto` (longer side of the work area).
    public var rootOrientation: String = "auto"
    public var followOnMove: Bool = false
    public var spaceSwitch: SpaceSwitch = SpaceSwitch()
    public var floatingApps: [String] = ["com.apple.systempreferences"]
    /// When true, a window without a usable zoom button floats. Settings
    /// panels and utility windows have no zoom button.
    public var floatWindowsWithoutZoom: Bool = true
    /// Key chord text to command text. See `KeyChord` and `Command.parse`.
    public var bindings: [String: String] = Config.defaultBindings

    enum CodingKeys: String, CodingKey {
        case gaps, rootOrientation, followOnMove, spaceSwitch, floatingApps, floatWindowsWithoutZoom, bindings
    }

    public static let defaultBindings: [String: String] = {
        var b: [String: String] = [
            "alt-h": "focus left", "alt-j": "focus down", "alt-k": "focus up", "alt-l": "focus right",
            "alt-shift-h": "move left", "alt-shift-j": "move down", "alt-shift-k": "move up", "alt-shift-l": "move right",
            "alt-f": "fullscreen", "alt-e": "toggle-split", "alt-r": "balance",
            "alt-shift-minus": "resize -0.05", "alt-shift-equal": "resize 0.05",
            "alt-shift-space": "toggle-float",
        ]
        for n in 1...9 {
            b["alt-\(n)"] = "space \(n)"
            b["alt-shift-\(n)"] = "move-to-space \(n)"
        }
        return b
    }()

    public static let `default` = Config()

    public static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/simplewm/config.json")
    }

    /// Loads the file at `path`. Throws on read or decode errors.
    public static func load(from url: URL = Config.path) throws -> Config {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    /// Writes `Config.default` to `path` when the file is absent.
    public static func writeDefaultIfMissing(at url: URL = Config.path) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try Config.default.save(to: url)
    }

    /// Writes this config as sorted, pretty JSON. Creates the folder when needed.
    public func save(to url: URL = Config.path) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(self)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    /// Root orientation for a work area. `auto` picks the longer side.
    public func rootOrientation(for area: Rect) -> Orientation {
        switch rootOrientation.lowercased() {
        case "horizontal": return .horizontal
        case "vertical": return .vertical
        default: return area.w >= area.h ? .horizontal : .vertical
        }
    }
}

// The decoder lives in an extension. This keeps the synthesized `init()`.
extension Config {
    /// Gaps with optional members, so a partial `gaps` object decodes.
    private struct PartialGaps: Decodable {
        var inner: Double?
        var outer: Double?
    }

    /// Decodes a partial file. A missing key keeps its default value.
    /// Throws when a value is present but not valid.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let g = try c.decodeIfPresent(PartialGaps.self, forKey: .gaps) {
            gaps = Gaps(inner: g.inner ?? gaps.inner, outer: g.outer ?? gaps.outer)
        }
        guard gaps.inner >= 0, gaps.outer >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .gaps, in: c, debugDescription: "Gaps must be zero or more.")
        }
        if let o = try c.decodeIfPresent(String.self, forKey: .rootOrientation) {
            guard ["auto", "horizontal", "vertical"].contains(o.lowercased()) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .rootOrientation, in: c,
                    debugDescription: "Use auto, horizontal, or vertical.")
            }
            rootOrientation = o.lowercased()
        }
        followOnMove = try c.decodeIfPresent(Bool.self, forKey: .followOnMove) ?? followOnMove
        if let s = try c.decodeIfPresent(SpaceSwitch.self, forKey: .spaceSwitch) {
            guard ["auto", "gesture", "ctrl-n"].contains(s.strategy.lowercased()) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .spaceSwitch, in: c,
                    debugDescription: "Use auto, gesture, or ctrl-n.")
            }
            spaceSwitch = s
        }
        floatingApps = try c.decodeIfPresent([String].self, forKey: .floatingApps) ?? floatingApps
        floatWindowsWithoutZoom = try c.decodeIfPresent(Bool.self, forKey: .floatWindowsWithoutZoom) ?? floatWindowsWithoutZoom
        bindings = try c.decodeIfPresent([String: String].self, forKey: .bindings) ?? bindings
    }
}

extension Config.SpaceSwitch {
    enum CodingKeys: String, CodingKey {
        case strategy, warpCursor
    }

    /// Decodes a partial object. A missing key keeps its default value.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strategy = try c.decodeIfPresent(String.self, forKey: .strategy)?.lowercased() ?? strategy
        warpCursor = try c.decodeIfPresent(Bool.self, forKey: .warpCursor) ?? warpCursor
    }
}
