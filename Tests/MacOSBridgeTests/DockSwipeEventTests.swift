import CoreGraphics
import Foundation
import XCTest
@testable import MacOSBridge

/// Tests the macOS 27 Dock swipe bytes. Most tests call the pure helpers with
/// fixed inputs. `testSequenceRoundTrip` builds real events and skips on a
/// host that cannot build them.
final class DockSwipeEventTests: XCTestCase {
    private let ts: UInt64 = 0x0102_0304_0506_0708

    private func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | UInt16(b[o + 1]) << 8
    }

    private func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[o + $1]) << (8 * UInt32($1)) }
    }

    private func i32(_ b: [UInt8], _ o: Int) -> Int32 { Int32(bitPattern: u32(b, o)) }

    private func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) }
    }

    private func payload(_ phase: Int64, sign: Double = 1) -> [UInt8] {
        DockSwipeEvent.payload(phase: phase, progress: sign * 0.1, positionX: 0.1,
                               velocityX: phase == DockSwipeEvent.phaseEnded ? sign * 9999 : 0,
                               timestamp: ts)
    }

    // MARK: - Payload

    func testPayloadSizes() {
        XCTAssertEqual(payload(DockSwipeEvent.phaseBegan).count, 68)
        XCTAssertEqual(payload(DockSwipeEvent.phaseChanged).count, 68)
        XCTAssertEqual(payload(DockSwipeEvent.phaseEnded).count, 96)
    }

    func testHeader() {
        for phase in DockSwipeEvent.stepPhases {
            let p = payload(phase)
            XCTAssertEqual(u64(p, 0), ts, "timestamp")
            XCTAssertEqual(u64(p, 8), 0, "sender ID")
            XCTAssertEqual(u32(p, 16), 0, "options")
            XCTAssertEqual(u32(p, 20), 0, "attribute length")
            XCTAssertEqual(u32(p, 24), phase == DockSwipeEvent.phaseEnded ? 2 : 1, "event count")
        }
    }

    func testFluidRecord() {
        for phase in DockSwipeEvent.stepPhases {
            for sign in [1.0, -1.0] {
                let p = payload(phase, sign: sign)
                XCTAssertEqual(u32(p, 28), 40, "record size")
                XCTAssertEqual(u32(p, 32), 23, "record type")
                XCTAssertEqual(Int64(u32(p, 36) >> 24), phase, "options carry the phase")
                XCTAssertEqual(u32(p, 36) & 0x00FF_FFFF, 0)
                XCTAssertEqual(Array(p[40..<44]), [0, 0, 0, 0], "depth 0 and padding")
                XCTAssertEqual(i32(p, 44), 6553, "position X")
                XCTAssertEqual(i32(p, 48), 0, "position Y")
                XCTAssertEqual(i32(p, 52), 0, "position Z")
                XCTAssertEqual(u32(p, 56), 0, "swipe mask")
                XCTAssertEqual(u16(p, 60), 1, "motion")
                XCTAssertEqual(u16(p, 62), 3, "flavor")
                XCTAssertEqual(i32(p, 64), DockSwipeEvent.fixed1616(sign * 0.1), "progress")
                XCTAssertEqual(i32(p, 64), Int32(sign) * 6553)
            }
        }
    }

    func testVelocityRecordOnlyOnEnded() {
        for sign in [1.0, -1.0] {
            let p = payload(DockSwipeEvent.phaseEnded, sign: sign)
            XCTAssertEqual(u32(p, 68), 28, "record size")
            XCTAssertEqual(u32(p, 72), 9, "record type")
            XCTAssertEqual(u32(p, 76), 0, "options")
            XCTAssertEqual(p[80], 1, "depth")
            XCTAssertEqual(Array(p[81..<84]), [0, 0, 0])
            XCTAssertEqual(i32(p, 84), Int32(sign) * 655_294_464, "velocity X")
            XCTAssertEqual(i32(p, 88), 0, "velocity Y")
            XCTAssertEqual(i32(p, 92), 0, "velocity Z")
        }
        XCTAssertEqual(payload(DockSwipeEvent.phaseBegan).count, 68)
        XCTAssertEqual(payload(DockSwipeEvent.phaseChanged).count, 68)
    }

    // MARK: - Fixed point

    func testFixed1616() {
        XCTAssertEqual(DockSwipeEvent.fixed1616(0), 0)
        XCTAssertEqual(DockSwipeEvent.fixed1616(1), 65536)
        XCTAssertEqual(DockSwipeEvent.fixed1616(-1), -65536)
        XCTAssertEqual(DockSwipeEvent.fixed1616(0.1), 6553)
        XCTAssertEqual(DockSwipeEvent.fixed1616(9999), 655_294_464)
        XCTAssertEqual(DockSwipeEvent.fixed1616(-9999), -655_294_464)
        XCTAssertEqual(DockSwipeEvent.fixed1616(1e-9), 1, "tiny positive clamps to +1")
        XCTAssertEqual(DockSwipeEvent.fixed1616(-1e-9), -1, "tiny negative clamps to -1")
    }

    // MARK: - Field 4205

    func testAppendPayloadFieldRejectsOtherHeaders() {
        let payload: [UInt8] = [9, 9]
        XCTAssertNil(DockSwipeEvent.appendPayloadField(payload, to: []))
        XCTAssertNil(DockSwipeEvent.appendPayloadField(payload, to: [0, 0, 0]))
        XCTAssertNil(DockSwipeEvent.appendPayloadField(payload, to: [0, 0, 0, 1, 7]))
        XCTAssertNil(DockSwipeEvent.appendPayloadField(payload, to: [0, 0, 0, 3, 7]))
        XCTAssertNil(DockSwipeEvent.appendPayloadField(payload, to: [1, 0, 0, 2, 7]))
    }

    func testAppendPayloadField() {
        let data: [UInt8] = [0, 0, 0, 2, 0xAA, 0xBB]
        let p = payload(DockSwipeEvent.phaseEnded)
        let out = DockSwipeEvent.appendPayloadField(p, to: data)
        XCTAssertEqual(out, data + [0x00, 0x60, 0x10, 0x6D] + p)

        let long = [UInt8](repeating: 7, count: 0x0123)
        XCTAssertEqual(DockSwipeEvent.appendPayloadField(long, to: data),
                       data + [0x01, 0x23, 0x10, 0x6D] + long)
    }

    // MARK: - Sign and gate

    func testBaseSign() {
        XCTAssertEqual(DockSwipeEvent.baseSign(forward: true, naturalScrolling: true), -1)
        XCTAssertEqual(DockSwipeEvent.baseSign(forward: false, naturalScrolling: true), 1)
        XCTAssertEqual(DockSwipeEvent.baseSign(forward: true, naturalScrolling: false), 1)
        XCTAssertEqual(DockSwipeEvent.baseSign(forward: false, naturalScrolling: false), -1)
    }

    func testPayloadDecision() {
        XCTAssertTrue(DockSwipeEvent.payloadDecision(override: nil, major: 27))
        XCTAssertTrue(DockSwipeEvent.payloadDecision(override: nil, major: 28))
        XCTAssertFalse(DockSwipeEvent.payloadDecision(override: nil, major: 26))
        XCTAssertFalse(DockSwipeEvent.payloadDecision(override: nil, major: nil))
        XCTAssertTrue(DockSwipeEvent.payloadDecision(override: "1", major: 15))
        XCTAssertFalse(DockSwipeEvent.payloadDecision(override: "0", major: 27))
        XCTAssertTrue(DockSwipeEvent.payloadDecision(override: "x", major: 27))
    }

    func testMajorVersion() {
        XCTAssertEqual(DockSwipeEvent.majorVersion("27.2"), 27)
        XCTAssertEqual(DockSwipeEvent.majorVersion("26"), 26)
        XCTAssertEqual(DockSwipeEvent.majorVersion("15.7.1"), 15)
        XCTAssertNil(DockSwipeEvent.majorVersion(""))
        XCTAssertNil(DockSwipeEvent.majorVersion("abc"))
    }

    // MARK: - Sequence

    func testSequenceOfZeroStepsIsEmpty() {
        XCTAssertEqual(DockSwipeEvent.sequence(steps: 0, sign: 1)?.count, 0)
        XCTAssertEqual(DockSwipeEvent.sequence(steps: -2, sign: 1)?.count, 0)
    }

    /// Builds real events. Skips when the host cannot create a CGEvent or its
    /// serialized header is not version 2.
    func testSequenceRoundTrip() throws {
        guard let probe = CGEvent(source: nil) else { throw XCTSkip("CGEvent(source: nil) is nil") }
        guard let data = probe.data,
              DockSwipeEvent.appendPayloadField([], to: [UInt8](data as Data)) != nil
        else { throw XCTSkip("Serialized CGEvent header is not version 2") }

        // A host before macOS 27 can reject the field 4205 tag.
        let major = DockSwipeEvent.osProductVersion().flatMap(DockSwipeEvent.majorVersion) ?? 0
        guard let built = DockSwipeEvent.sequence(steps: 2, sign: -1) else {
            if major < 27 { throw XCTSkip("macOS \(major) cannot build field 4205 events") }
            return XCTFail("macOS \(major) cannot build the Dock swipe sequence")
        }
        let events = built
        XCTAssertEqual(events.count, 6)
        for (i, ev) in events.enumerated() {
            let phase = DockSwipeEvent.stepPhases[i % 3]
            // The event stores these fields as 32-bit floats.
            func int(_ n: UInt32) -> Int64 { ev.getIntegerValueField(CGEventField(rawValue: n)!) }
            func dbl(_ n: UInt32) -> Double { ev.getDoubleValueField(CGEventField(rawValue: n)!) }
            XCTAssertEqual(int(55), 30)
            XCTAssertEqual(int(110), 23)
            XCTAssertEqual(int(132), phase)
            XCTAssertEqual(int(123), 1)
            XCTAssertEqual(dbl(124), -0.1, accuracy: 1e-6)
            XCTAssertEqual(dbl(125), 0.1, accuracy: 1e-6)
            XCTAssertEqual(dbl(129), phase == DockSwipeEvent.phaseEnded ? -9999 : 0, accuracy: 1e-6)
        }
    }
}
