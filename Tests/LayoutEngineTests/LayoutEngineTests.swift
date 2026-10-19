import XCTest
@testable import LayoutEngine

final class LayoutEngineTests: XCTestCase {
    func testCommandParse() {
        XCTAssertEqual(Command.parse("focus left"), .focus(.left))
        XCTAssertEqual(Command.parse("move-to-space 3"), .moveToSpace(3))
        XCTAssertEqual(Command.parse("resize -0.05"), .resize(-0.05))
        XCTAssertNil(Command.parse("space 0"))
        XCTAssertNil(Command.parse("bogus"))
    }

    func testRectHelpers() {
        let r = Rect(x: 0, y: 0, w: 100, h: 50)
        XCTAssertEqual(r.inset(by: 10), Rect(x: 10, y: 10, w: 80, h: 30))
        XCTAssertTrue(r.isClose(to: Rect(x: 1, y: 0, w: 100, h: 50), tolerance: 1))
    }

    func testEmptyTreeAndPrune() {
        var state = WMState()
        let key = SpaceKey(display: DisplayID("A"), space: SpaceID(1))
        state.trees[key] = TilingTree(root: .horizontal)
        state.prune(live: [])
        XCTAssertTrue(state.trees.isEmpty)
    }
}
