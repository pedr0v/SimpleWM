import Foundation

/// User command. The config file maps a key chord to the text form of a command.
///
/// Text forms (one per case):
/// - `focus left|down|up|right`
/// - `move left|down|up|right`
/// - `space N` (N in 1...9)
/// - `move-to-space N` (N in 1...9)
/// - `fullscreen` (zoom inside the tree, not native fullscreen)
/// - `toggle-split` (flip the parent orientation of the focused window)
/// - `split horizontal|vertical` (wrap the focused window in a new container)
/// - `balance` (equal weights in every container)
/// - `resize D` (D is a signed fraction, for example `-0.05`)
public enum Command: Equatable, Sendable {
    case focus(Direction)
    case move(Direction)
    case gotoSpace(Int)
    case moveToSpace(Int)
    case toggleFullscreen
    case toggleSplit
    case split(Orientation)
    case balance
    case resize(Double)
    /// Toggles the focused window between tiled and floating.
    case toggleFloat

    /// Parses the text form. Returns nil for unknown text. Parsing is case-insensitive.
    public static func parse(_ text: String) -> Command? {
        let parts = text.lowercased().split(separator: " ").map(String.init)
        guard let head = parts.first else { return nil }
        let arg = parts.count > 1 ? parts[1] : nil
        switch (head, arg) {
        case ("focus", let d?):
            return Direction(rawValue: d).map(Command.focus)
        case ("move", let d?):
            return Direction(rawValue: d).map(Command.move)
        case ("space", let n?):
            return Int(n).flatMap { (1...9).contains($0) ? .gotoSpace($0) : nil }
        case ("move-to-space", let n?):
            return Int(n).flatMap { (1...9).contains($0) ? .moveToSpace($0) : nil }
        case ("fullscreen", nil), ("zoom", nil):
            return .toggleFullscreen
        case ("toggle-split", nil):
            return .toggleSplit
        case ("split", let o?):
            return Orientation(rawValue: o).map(Command.split)
        case ("balance", nil):
            return .balance
        case ("toggle-float", nil), ("float", nil):
            return .toggleFloat
        case ("resize", let d?):
            return Double(d).map(Command.resize)
        default:
            return nil
        }
    }
}
