import LayoutEngine
import XCTest
@testable import MacOSBridge

/// Tests the rules for `space N`, `move-to-space N`, and the empty-Space cleanup.
final class SpaceTargetRulesTests: XCTestCase {
    private let cap = SpaceManager.maxSpaceCount

    private func desktop(_ id: UInt64) -> SpaceInfo { SpaceInfo(id: SpaceID(id), type: 0) }
    private func fullscreen(_ id: UInt64) -> SpaceInfo { SpaceInfo(id: SpaceID(id), type: 4) }

    /// `isEmpty` for a fixed set of Spaces that hold windows.
    private func empty(except used: Set<UInt64>) -> (SpaceID) -> Bool {
        { !used.contains($0.raw) }
    }

    // MARK: - Target

    func testExistingSpace() {
        XCTAssertEqual(SpaceTargetRules.target(n: 1, count: 3, createAllowed: true, maxCount: cap), .existing(index: 0))
        XCTAssertEqual(SpaceTargetRules.target(n: 3, count: 3, createAllowed: true, maxCount: cap), .existing(index: 2))
        // An existing Space does not need creation.
        XCTAssertEqual(SpaceTargetRules.target(n: 3, count: 3, createAllowed: false, maxCount: cap), .existing(index: 2))
    }

    func testMissingSpaceGoesToTheSpare() {
        for n in 4...9 {
            XCTAssertEqual(SpaceTargetRules.target(n: n, count: 3, createAllowed: true, maxCount: cap), .spare, "n = \(n)")
        }
    }

    func testRefusals() {
        XCTAssertEqual(SpaceTargetRules.target(n: 0, count: 3, createAllowed: true, maxCount: cap), .unavailable(.invalidNumber))
        XCTAssertEqual(SpaceTargetRules.target(n: 4, count: 3, createAllowed: false, maxCount: cap), .unavailable(.creationOff))
        XCTAssertEqual(SpaceTargetRules.target(n: 10, count: 3, createAllowed: true, maxCount: cap), .unavailable(.aboveCap))
        // N above the cap still reaches an existing Space.
        XCTAssertEqual(SpaceTargetRules.target(n: 10, count: 12, createAllowed: true, maxCount: cap), .existing(index: 9))
    }

    // MARK: - Spare

    func testLastEmptyDesktopIsReused() {
        let spaces = [desktop(1), desktop(2), desktop(3), desktop(4)]
        XCTAssertEqual(SpaceTargetRules.spare(spaces: spaces, isEmpty: empty(except: [1, 2, 3]), maxCount: cap),
                       .reuse(index: 3))
    }

    func testLastDesktopWithWindowNeedsOneNewSpace() {
        let spaces = [desktop(1), desktop(2), desktop(3)]
        XCTAssertEqual(SpaceTargetRules.spare(spaces: spaces, isEmpty: empty(except: [1, 2, 3]), maxCount: cap), .create)
    }

    func testEmptyDesktopInTheMiddleIsNotTheSpare() {
        let spaces = [desktop(1), desktop(2), desktop(3)]
        XCTAssertEqual(SpaceTargetRules.spare(spaces: spaces, isEmpty: empty(except: [1, 3]), maxCount: cap), .create)
    }

    func testFullscreenLastSpaceIsNotTheSpare() {
        let spaces = [desktop(1), fullscreen(2)]
        XCTAssertEqual(SpaceTargetRules.spare(spaces: spaces, isEmpty: empty(except: [1]), maxCount: cap), .create)
    }

    func testFullDisplay() {
        let spaces = (1...UInt64(cap)).map(desktop)
        XCTAssertEqual(SpaceTargetRules.spare(spaces: spaces, isEmpty: empty(except: Set(1...UInt64(cap))), maxCount: cap),
                       .full)
        // An empty last Space is still the spare on a full display.
        XCTAssertEqual(SpaceTargetRules.spare(spaces: spaces, isEmpty: empty(except: [1]), maxCount: cap),
                       .reuse(index: cap - 1))
    }

    /// Option+9 with 3 Spaces creates one Space. Option+8 then reuses it.
    func testRepeatedMissingNumbersCreateOneSpace() {
        var spaces = [desktop(1), desktop(2), desktop(3)]
        let used: Set<UInt64> = [1, 2, 3]

        XCTAssertEqual(SpaceTargetRules.target(n: 9, count: spaces.count, createAllowed: true, maxCount: cap), .spare)
        XCTAssertEqual(SpaceTargetRules.spare(spaces: spaces, isEmpty: empty(except: used), maxCount: cap), .create)
        spaces.append(desktop(4))

        XCTAssertEqual(SpaceTargetRules.target(n: 8, count: spaces.count, createAllowed: true, maxCount: cap), .spare)
        XCTAssertEqual(SpaceTargetRules.spare(spaces: spaces, isEmpty: empty(except: used), maxCount: cap),
                       .reuse(index: 3))
    }

    // MARK: - Cleanup

    func testRemovableEmptySpacesKeepFirstCurrentAndLast() {
        let spaces = [desktop(1), desktop(2), desktop(3), desktop(4), desktop(5)]
        // Every Space is empty. Space 3 is current.
        let removable = SpaceTargetRules.removableEmptySpaces(spaces: spaces, current: SpaceID(3), isEmpty: empty(except: []))
        XCTAssertEqual(removable.map(\.id.raw), [2, 4])
    }

    func testRemovableEmptySpacesSkipWindowsAndFullscreen() {
        let spaces = [desktop(1), desktop(2), fullscreen(3), desktop(4), desktop(5)]
        let removable = SpaceTargetRules.removableEmptySpaces(spaces: spaces, current: SpaceID(1), isEmpty: empty(except: [2]))
        XCTAssertEqual(removable.map(\.id.raw), [4])
    }

    func testRemovableEmptySpacesNeedThreeSpaces() {
        let spaces = [desktop(1), desktop(2)]
        XCTAssertTrue(SpaceTargetRules.removableEmptySpaces(spaces: spaces, current: SpaceID(1), isEmpty: empty(except: [])).isEmpty)
    }

    /// The live layout before the fix: 3 desktops with windows and 2 empty
    /// desktops at the end. The cleanup leaves one empty spare.
    func testCleanupLeavesOneSpare() {
        let spaces = [desktop(3), desktop(6), desktop(4), desktop(5), desktop(7)]
        let used: Set<UInt64> = [3, 6, 4]
        let removable = SpaceTargetRules.removableEmptySpaces(spaces: spaces, current: SpaceID(3), isEmpty: empty(except: used))
        XCTAssertEqual(removable.map(\.id.raw), [5])
        let left = spaces.filter { s in !removable.contains(s) }
        XCTAssertEqual(left.filter { !used.contains($0.id.raw) }.count, 1)
    }

    // MARK: - Switch tickets

    func testNewerTicketReplacesOlderTicket() {
        var tickets = SwitchTickets()
        let first = tickets.issue()
        XCTAssertTrue(tickets.isLatest(first))
        let second = tickets.issue()
        XCTAssertFalse(tickets.isLatest(first))
        XCTAssertTrue(tickets.isLatest(second))
        XCTAssertGreaterThan(second, first)
    }

    /// `alt-9` takes a ticket and creates Space 4. `alt-2` takes a newer
    /// ticket while the creation runs. When the creation ends, the ticket
    /// of `alt-9` is old, so the display does not switch to Space 4.
    func testPressDuringCreationKeepsTheNewerRequest() {
        var tickets = SwitchTickets()
        let spacePress9 = tickets.issue()
        let spacePress2 = tickets.issue()
        XCTAssertFalse(tickets.isLatest(spacePress9))
        XCTAssertTrue(tickets.isLatest(spacePress2))
    }

    func testFirstTicketIsNotZero() {
        var tickets = SwitchTickets()
        XCTAssertEqual(tickets.latest, 0)
        XCTAssertEqual(tickets.issue(), 1)
        XCTAssertEqual(tickets.latest, 1)
    }
}
