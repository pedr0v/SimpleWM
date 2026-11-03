import CoreGraphics
import Foundation

/// Builds the synthetic Dock swipe events for macOS 27 and later.
///
/// macOS 27 ignores a Dock swipe that has only the classic CGEvent fields.
/// WindowServer logs "Failed to extract HID event from indirect gesture" for
/// each event. The event must also carry a serialized IOHID payload in the
/// private CGEvent field 4205. This type builds that payload.
///
/// One step is three events, one per phase: began, changed, ended.
/// The byte helpers are pure. Tests call them without a WindowServer.
public enum DockSwipeEvent {
    // CGEvent field numbers (private).
    static let fieldEventType: UInt32 = 55          // kCGSEventTypeField
    static let fieldGestureHIDType: UInt32 = 110    // kCGEventGestureHIDType
    static let fieldSwipeMotion: UInt32 = 123       // kCGEventGestureSwipeMotion
    static let fieldSwipeProgress: UInt32 = 124     // kCGEventGestureSwipeProgress
    static let fieldSwipePositionX: UInt32 = 125    // kCGEventGestureSwipePositionX
    static let fieldSwipeVelocityX: UInt32 = 129    // kCGEventGestureSwipeVelocityX
    static let fieldGesturePhase: UInt32 = 132      // kCGEventGesturePhase
    /// Field tag of the serialized IOHID payload (field 4205 = 0x106D).
    static let payloadFieldTag: [UInt8] = [0x10, 0x6D]

    static let dockControlEventType: Int64 = 30     // kCGSEventDockControl
    static let dockSwipeHIDType: Int64 = 23         // kIOHIDEventTypeDockSwipe
    static let swipeMotionHorizontal: Int64 = 1

    /// IOHID gesture phases.
    public static let phaseBegan: Int64 = 1
    public static let phaseChanged: Int64 = 2
    public static let phaseEnded: Int64 = 4
    /// Phase order of one step.
    public static let stepPhases: [Int64] = [phaseBegan, phaseChanged, phaseEnded]

    /// Progress magnitude of each event. The progress is `sign * 0.1`.
    public static let progressMagnitude: Double = 0.1
    /// Swipe position X of each event.
    public static let positionX: Double = 0.1
    /// Velocity magnitude of the ended event. The velocity is `sign * 9999`.
    public static let velocityMagnitude: Double = 9999.0

    // IOHID record constants.
    static let fluidRecordSize: UInt32 = 40
    static let fluidRecordType: UInt32 = 23         // DockSwipe
    static let velocityRecordSize: UInt32 = 28
    static let velocityRecordType: UInt32 = 9       // Velocity
    static let flavorDockPrimary: UInt16 = 3

    // MARK: - Pure byte helpers

    /// Converts `v` to IOHID 16.16 fixed point. A non-zero value never
    /// becomes 0: a tiny value becomes +1 or -1.
    public static func fixed1616(_ v: Double) -> Int32 {
        let f = Int32(truncatingIfNeeded: Int64(v * 65536.0))
        if f == 0 && v != 0 { return v > 0 ? 1 : -1 }
        return f
    }

    /// Builds the IOHID payload of one event (packed, little-endian).
    ///
    /// Layout:
    /// - Header, 28 bytes: timestamp, sender ID, options, attribute length,
    ///   event count (2 for the ended phase, else 1).
    /// - Fluid DockSwipe record, 40 bytes.
    /// - Velocity record, 28 bytes. Only the ended phase has it.
    ///
    /// The payload is 68 bytes, or 96 bytes for the ended phase.
    public static func payload(phase: Int64, progress: Double, positionX: Double,
                               velocityX: Double, timestamp: UInt64) -> [UInt8] {
        let ended = phase == phaseEnded
        var p = [UInt8]()
        p.reserveCapacity(ended ? 96 : 68)
        // Header.
        p.appendLE(timestamp)
        p.appendLE(UInt64(0))                       // sender ID
        p.appendLE(UInt32(0))                       // options
        p.appendLE(UInt32(0))                       // attribute length
        p.appendLE(UInt32(ended ? 2 : 1))           // event count
        // Fluid DockSwipe record.
        p.appendLE(fluidRecordSize)
        p.appendLE(fluidRecordType)
        p.appendLE((UInt32(truncatingIfNeeded: phase) & 0xFF) << 24)  // options: phase
        p += [0, 0, 0, 0]                           // depth 0, 3 pad bytes
        p.appendLE(fixed1616(positionX))
        p.appendLE(Int32(0))                        // position Y
        p.appendLE(Int32(0))                        // position Z
        p.appendLE(UInt32(0))                       // swipe mask
        p.appendLE(UInt16(swipeMotionHorizontal))   // motion
        p.appendLE(flavorDockPrimary)               // flavor
        p.appendLE(fixed1616(progress))
        // Velocity record.
        if ended {
            p.appendLE(velocityRecordSize)
            p.appendLE(velocityRecordType)
            p.appendLE(UInt32(0))                   // options
            p += [1, 0, 0, 0]                       // depth 1, 3 pad bytes
            p.appendLE(fixed1616(velocityX))
            p.appendLE(Int32(0))                    // velocity Y
            p.appendLE(Int32(0))                    // velocity Z
        }
        return p
    }

    /// Appends `payload` as field 4205 to serialized CGEvent `data`.
    /// The field is: payload length (2 bytes, big-endian), tag `0x10 0x6D`,
    /// then the payload. Returns nil when the data header is not version 2
    /// (`00 00 00 02`) or the payload is longer than 65535 bytes.
    public static func appendPayloadField(_ payload: [UInt8], to data: [UInt8]) -> [UInt8]? {
        guard data.count >= 4, data[0] == 0, data[1] == 0, data[2] == 0, data[3] == 2,
              payload.count <= 0xFFFF
        else { return nil }
        var out = data
        out.reserveCapacity(data.count + 4 + payload.count)
        out.append(UInt8((payload.count >> 8) & 0xFF))
        out.append(UInt8(payload.count & 0xFF))
        out += payloadFieldTag
        out += payload
        return out
    }

    /// Base sign of the progress and velocity on macOS 27.
    /// `forward` is a move to a higher index in `Spaces[]`.
    /// With Natural scrolling, a forward move has the base sign -1. Without
    /// it, +1. A backward move has the opposite sign.
    /// The posted sign is the base sign times `GestureSwitch.directionFactor`.
    public static func baseSign(forward: Bool, naturalScrolling: Bool) -> Double {
        let base: Double = naturalScrolling ? -1 : 1
        return forward ? base : -base
    }

    /// Parses the major version from a string like "27.2". Nil when invalid.
    static func majorVersion(_ productVersion: String) -> Int? {
        guard let first = productVersion.split(separator: ".").first else { return nil }
        return Int(first)
    }

    /// Decides the payload path from the env override and the macOS major.
    /// The override "1" forces the path on, "0" forces it off.
    static func payloadDecision(override: String?, major: Int?) -> Bool {
        switch override {
        case "1": return true
        case "0": return false
        default: return (major ?? 0) >= 27
        }
    }

    // MARK: - System reads

    /// `true` when the Dock swipe needs the field 4205 payload.
    /// The value comes from `kern.osproductversion` (major 27 or later), not
    /// from `ProcessInfo`: compatibility versioning can report another value.
    /// `SIMPLEWM_SWIPE_PAYLOAD=1` or `0` forces the path on or off.
    /// The first read caches the value.
    public static let requiresPayload: Bool = payloadDecision(
        override: ProcessInfo.processInfo.environment["SIMPLEWM_SWIPE_PAYLOAD"],
        major: osProductVersion().flatMap(majorVersion))

    /// Reads `kern.osproductversion`, for example "27.2". Nil on failure.
    static func osProductVersion() -> String? {
        var size = 0
        guard sysctlbyname("kern.osproductversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osproductversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Reads the Natural scrolling setting (`com.apple.swipescrolldirection`).
    /// A missing key means `true`, the system default.
    /// The Dock reads this setting at launch. After a change, the Dock keeps
    /// the old value until `killall Dock`.
    public static func naturalScrolling() -> Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let value = CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString,
                                              kCFPreferencesAnyApplication)
        return value as? Bool ?? true
    }

    // MARK: - Event building

    /// Builds one event of a step for `phase`. `sign` is +1 or -1.
    /// The progress is `sign * 0.1` on each phase. Only the ended phase sets
    /// the velocity (`sign * 9999`). The event keeps the cursor location.
    /// Returns nil when the system cannot create or serialize the event.
    public static func event(phase: Int64, sign: Double) -> CGEvent? {
        guard let ev = CGEvent(source: nil) else { return nil }
        let progress = sign * progressMagnitude
        let ended = phase == phaseEnded
        let velocityX = ended ? sign * velocityMagnitude : 0
        setInt(ev, fieldEventType, dockControlEventType)
        setInt(ev, fieldGestureHIDType, dockSwipeHIDType)
        setInt(ev, fieldGesturePhase, phase)
        setDouble(ev, fieldSwipeProgress, progress)
        setInt(ev, fieldSwipeMotion, swipeMotionHorizontal)
        setDouble(ev, fieldSwipePositionX, positionX)
        if ended { setDouble(ev, fieldSwipeVelocityX, velocityX) }

        let ts = ev.timestamp
        let bytes = payload(phase: phase, progress: progress, positionX: positionX,
                            velocityX: velocityX,
                            timestamp: ts != 0 ? ts : mach_absolute_time())
        guard let data = ev.data,
              let serialized = appendPayloadField(bytes, to: [UInt8](data as Data))
        else { return nil }
        return CGEvent(withDataAllocator: nil, data: Data(serialized) as CFData)
    }

    /// Builds the full event sequence of one request: `steps` steps, three
    /// phases each (began, changed, ended). Returns nil when any event fails,
    /// so the caller never posts a truncated sequence. A truncated sequence
    /// leaves the Dock stuck in the middle of a swipe.
    /// `steps` of 0 or less gives an empty sequence.
    public static func sequence(steps: Int, sign: Double) -> [CGEvent]? {
        guard steps > 0 else { return [] }
        var events: [CGEvent] = []
        events.reserveCapacity(steps * stepPhases.count)
        for _ in 0..<steps {
            for phase in stepPhases {
                guard let e = event(phase: phase, sign: sign) else { return nil }
                events.append(e)
            }
        }
        return events
    }

    private static func setInt(_ ev: CGEvent, _ field: UInt32, _ value: Int64) {
        guard let f = CGEventField(rawValue: field) else { return }
        ev.setIntegerValueField(f, value: value)
    }

    private static func setDouble(_ ev: CGEvent, _ field: UInt32, _ value: Double) {
        guard let f = CGEventField(rawValue: field) else { return }
        ev.setDoubleValueField(f, value: value)
    }
}

extension Array where Element == UInt8 {
    /// Appends the little-endian bytes of `v`.
    fileprivate mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}
