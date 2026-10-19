import Carbon.HIToolbox
import Foundation

/// Key chord: physical ANSI key code plus Carbon modifier mask.
///
/// Text form: modifiers and key joined by `-`, for example `alt-shift-h`.
/// Modifiers: `alt` (or `opt`), `shift`, `ctrl`, `cmd`.
/// Keys: `a`...`z`, `0`...`9`, `minus`, `equal`, `left`, `right`, `up`, `down`,
/// `space`, `return`, `tab`, `escape`. Key codes are physical, so the keyboard
/// layout does not change bindings.
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public let keyCode: UInt32
    /// Carbon mask: cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000.
    public let modifiers: UInt32
    public let text: String

    public init(keyCode: UInt32, modifiers: UInt32, text: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.text = text
    }

    /// Parses the text form. Returns nil when a token is unknown or no key is present.
    public init?(_ text: String) {
        fatalError("TODO")
    }

    public var description: String { text }

    /// Physical ANSI key codes (`kVK_ANSI_*`).
    public static let keyCodes: [String: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "equal": 0x18,
        "9": 0x19, "7": 0x1A, "minus": 0x1B, "8": 0x1C, "0": 0x1D, "o": 0x1F, "u": 0x20,
        "i": 0x22, "p": 0x23, "return": 0x24, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D,
        "m": 0x2E, "tab": 0x30, "space": 0x31, "escape": 0x35,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
    ]
}

/// Carbon `RegisterEventHotKey` wrapper. Needs no permission.
///
/// The handler runs on the main thread while `NSApplication.run` runs. The
/// system consumes a registered chord, so the focused app sees no key.
/// Status `eventHotKeyExistsErr` (-9878) means another process owns the chord.
@MainActor
public final class HotkeyManager {
    public static let signature: OSType = 0x53574D31 // "SWM1"

    public init() {}

    /// Registers `chord`. Returns the Carbon status. `noErr` means success.
    @discardableResult
    public func bind(_ chord: KeyChord, _ action: @escaping @MainActor () -> Void) -> OSStatus {
        fatalError("TODO")
    }

    /// Unregisters every chord.
    public func unbindAll() {
        fatalError("TODO")
    }

    /// Chords registered now.
    public var bound: [KeyChord] {
        fatalError("TODO")
    }
}
