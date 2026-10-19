import XCTest
@testable import LayoutEngine

final class LayoutEngineTests: XCTestCase {
    func testCommandParse() {
        XCTAssertEqual(Command.parse("focus left"), .focus(.left))
        XCTAssertEqual(Command.parse("move-to-space 3"), .moveToSpace(3))
        XCTAssertEqual(Command.parse("resize -0.05"), .resize(-0.05))
        XCTAssertEqual(Command.parse("toggle-float"), .toggleFloat)
        XCTAssertEqual(Command.parse("float"), .toggleFloat)
        XCTAssertNil(Command.parse("toggle-float x"))
        XCTAssertNil(Command.parse("space 0"))
        XCTAssertNil(Command.parse("bogus"))
    }

    func testRectHelpers() {
        let r = Rect(x: 0, y: 0, w: 100, h: 50)
        XCTAssertEqual(r.inset(by: 10), Rect(x: 10, y: 10, w: 80, h: 30))
        XCTAssertTrue(r.isClose(to: Rect(x: 1, y: 0, w: 100, h: 50), tolerance: 1))
    }

    func testRectContainsIsHalfOpen() {
        // Two displays share the edge x == 0. One point never lies in both.
        let left = Rect(x: -1376, y: 0, w: 1376, h: 900)
        let right = Rect(x: 0, y: 0, w: 1512, h: 982)
        XCTAssertFalse(left.contains(x: 0, y: 100))
        XCTAssertTrue(right.contains(x: 0, y: 100))
        XCTAssertTrue(left.contains(x: -1376, y: 0), "left and top edges belong to the rectangle")
        XCTAssertFalse(right.contains(x: 1512, y: 100))
        XCTAssertFalse(right.contains(x: 100, y: 982))
        XCTAssertTrue(right.contains(x: 1511.9, y: 981.9))
    }

    func testEmptyTreeAndPrune() {
        var state = WMState()
        let key = SpaceKey(display: DisplayID("A"), space: SpaceID(1))
        state.trees[key] = TilingTree(root: .horizontal)
        state.prune(live: [])
        XCTAssertTrue(state.trees.isEmpty)
    }
}
