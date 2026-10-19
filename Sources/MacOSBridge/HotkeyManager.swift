import Carbon.HIToolbox
import Foundation
import os

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
    ///
    /// Parsing is case-insensitive. The key must be the last token. `text`
    /// gets the canonical form: modifiers in the order ctrl, alt, shift, cmd,
    /// then the key. For example, `Shift-Opt-H` becomes `alt-shift-h`.
    public init?(_ text: String) {
        let tokens = text.trimmingCharacters(in: .whitespaces).lowercased()
            .split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)
        guard let keyName = tokens.last, !keyName.isEmpty,
              let code = KeyChord.keyCodes[keyName]
        else { return nil }
        var mask: UInt32 = 0
        for token in tokens.dropLast() {
            guard let bit = KeyChord.modifierBits[token] else { return nil }
            mask |= bit
        }
        var parts: [String] = []
        if mask & UInt32(controlKey) != 0 { parts.append("ctrl") }
        if mask & UInt32(optionKey) != 0 { parts.append("alt") }
        if mask & UInt32(shiftKey) != 0 { parts.append("shift") }
        if mask & UInt32(cmdKey) != 0 { parts.append("cmd") }
        parts.append(keyName)
        self.init(keyCode: code, modifiers: mask, text: parts.joined(separator: "-"))
    }

    public var description: String { text }

    /// Modifier token to Carbon mask bit.
    public static let modifierBits: [String: UInt32] = [
        "alt": UInt32(optionKey), "opt": UInt32(optionKey), "option": UInt32(optionKey),
        "shift": UInt32(shiftKey),
        "ctrl": UInt32(controlKey), "control": UInt32(controlKey),
        "cmd": UInt32(cmdKey), "command": UInt32(cmdKey),
    ]

    /// Physical ANSI key codes (`kVK_ANSI_*`).
    public static let keyCodes: [String: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "equal": 0x18,
        "9": 0x19, "7": 0x1A, "minus": 0x1B, "8": 0x1C, "0": 0x1D, "o": 0x1F, "u": 0x20,
        "i": 0x22, "p": 0x23, "return": 0x24, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D,
        "m": 0x2E, "tab": 0x30, "space": 0x31, "escape": 0x35,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        // Extra physical keys (ANSI positions).
        "rightbracket": 0x1E, "leftbracket": 0x21, "quote": 0x27, "semicolon": 0x29,
        "backslash": 0x2A, "comma": 0x2B, "slash": 0x2C, "period": 0x2F, "grave": 0x32,
        "enter": 0x24, "esc": 0x35, "backspace": 0x33,
    ]
}

/// Hotkey signature "SWM1". The C callback reads it without actor isolation.
private let hotkeySignature: OSType = 0x53574D31

/// Weak link from a Carbon callback to its `HotkeyManager`. The box lives
/// forever, so a late callback never reads freed memory.
private final class HotkeyBox {
    weak var manager: HotkeyManager?
}

/// Carbon event handler for `kEventHotKeyPressed`. Runs on the main thread.
private func hotkeyEventHandler(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr, hotKeyID.signature == hotkeySignature else {
        return OSStatus(eventNotHandledErr)
    }
    let box = Unmanaged<HotkeyBox>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    let handled: Bool = MainActor.assumeIsolated {
        box.manager?.dispatch(id: id) ?? false
    }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}

/// Carbon `RegisterEventHotKey` wrapper. Needs no permission.
///
/// The handler runs on the main thread while `NSApplication.run` runs. The
/// system consumes a registered chord, so the focused app sees no key.
/// Status `eventHotKeyExistsErr` (-9878) means another process owns the chord.
@MainActor
public final class HotkeyManager {
    public static let signature: OSType = hotkeySignature // "SWM1"

    private struct Binding {
        let chord: KeyChord
        let ref: EventHotKeyRef
        var action: @MainActor () -> Void
    }

    private let log = Logger(subsystem: "com.simplewm.app", category: "hotkeys")
    private var bindings: [UInt32: Binding] = [:]
    private var nextID: UInt32 = 1
    private var handlerRef: EventHandlerRef?
    private let box: UnsafeMutableRawPointer

    public init() {
        let b = HotkeyBox()
        box = Unmanaged.passRetained(b).toOpaque()
        b.manager = self
    }

    /// Registers `chord`. Returns the Carbon status. `noErr` means success.
    ///
    /// A chord that is already bound here gets the new action. The status is
    /// then `noErr`.
    @discardableResult
    public func bind(_ chord: KeyChord, _ action: @escaping @MainActor () -> Void) -> OSStatus {
        if let existing = bindings.first(where: {
            $0.value.chord.keyCode == chord.keyCode && $0.value.chord.modifiers == chord.modifiers
        }) {
            bindings[existing.key]?.action = action
            return noErr
        }
        let installStatus = installHandlerIfNeeded()
        guard installStatus == noErr else { return installStatus }

        let id = nextID
        nextID &+= 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(chord.keyCode,
                                         chord.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetEventDispatcherTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else {
            if status == OSStatus(eventHotKeyExistsErr) {
                log.error("Hotkey \(chord.text, privacy: .public) is taken by another process (-9878)")
            } else {
                log.error("Hotkey \(chord.text, privacy: .public) failed: OSStatus \(status)")
            }
            return status == noErr ? OSStatus(paramErr) : status
        }
        bindings[id] = Binding(chord: chord, ref: ref, action: action)
        return noErr
    }

    /// Unregisters every chord.
    public func unbindAll() {
        for binding in bindings.values {
            UnregisterEventHotKey(binding.ref)
        }
        bindings.removeAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    /// Chords registered now.
    public var bound: [KeyChord] {
        bindings.keys.sorted().compactMap { bindings[$0]?.chord }
    }

    /// Runs the action of hotkey `id`. Returns false for an unknown ID.
    fileprivate func dispatch(id: UInt32) -> Bool {
        guard let action = bindings[id]?.action else { return false }
        action()
        return true
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard handlerRef == nil else { return noErr }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        let status = InstallEventHandler(GetEventDispatcherTarget(),
                                         hotkeyEventHandler,
                                         1,
                                         &spec,
                                         box,
                                         &ref)
        if status == noErr {
            handlerRef = ref
        } else {
            log.error("InstallEventHandler failed: OSStatus \(status)")
        }
        return status
    }
}
