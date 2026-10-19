import Foundation
import LayoutEngine

/// User config at `~/.config/simplewm/config.json`.
///
/// A missing file yields `Config.default`. A bad file keeps the last good
/// config and logs the error. Unknown binding text is logged and skipped.
public struct Config: Codable, Equatable {
    public struct SpaceSwitch: Codable, Equatable {
        /// `auto`, `gesture`, or `ctrl-n`.
        public var strategy: String = "auto"
        public var warpCursor: Bool = true
    }

    public var gaps: Gaps = Gaps(inner: 8, outer: 8)
    /// `horizontal`, `vertical`, or `auto` (longer side of the work area).
    public var rootOrientation: String = "auto"
    public var followOnMove: Bool = false
    public var spaceSwitch: SpaceSwitch = SpaceSwitch()
    public var floatingApps: [String] = ["com.apple.systempreferences"]
    /// Key chord text to command text. See `KeyChord` and `Command.parse`.
    public var bindings: [String: String] = Config.defaultBindings

    public static let defaultBindings: [String: String] = {
        var b: [String: String] = [
            "alt-h": "focus left", "alt-j": "focus down", "alt-k": "focus up", "alt-l": "focus right",
            "alt-shift-h": "move left", "alt-shift-j": "move down", "alt-shift-k": "move up", "alt-shift-l": "move right",
            "alt-f": "fullscreen", "alt-e": "toggle-split", "alt-r": "balance",
            "alt-shift-minus": "resize -0.05", "alt-shift-equal": "resize 0.05",
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
        fatalError("TODO")
    }

    /// Writes `Config.default` to `path` when the file is absent.
    public static func writeDefaultIfMissing(at url: URL = Config.path) throws {
        fatalError("TODO")
    }
}
