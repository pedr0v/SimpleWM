import XCTest
@testable import MacOSBridge

/// Tests the matching rules of the Mission Control Accessibility tree with
/// fake trees. The WindowManager tree copies a live dump from macOS 27.2.
/// The Dock tree has the layout of macOS 26 and earlier.
final class MissionControlTreeTests: XCTestCase {
    /// Fake Accessibility node.
    struct Node: AXTreeNode, Equatable {
        var name: String
        var identifier: String?
        var displayID: UInt32?
        var actionNames: [String] = []
        var children: [Node] = []
    }

    private static let press = "AXPress"
    private static let remove = MissionControlTree.removeAction

    private static func thumbnails(_ count: Int, removable: Bool, first: Int = 1) -> [Node] {
        (0..<count).map {
            Node(name: "Desktop \(first + $0)",
                 actionNames: removable ? [press, remove] : [press])
        }
    }

    /// One `mc.display` group: window buttons, then the Spaces bar.
    private static func displayGroup(_ cgID: UInt32, spaces: Int, firstNumber: Int = 1) -> Node {
        Node(name: "display \(cgID)", identifier: "mc.display", displayID: cgID, children: [
            Node(name: "window", identifier: "com.example.app.space.3", actionNames: [press]),
            Node(name: "bar \(cgID)", identifier: "mc.spaces", children: [
                Node(name: "list \(cgID)", identifier: "mc.spaces.list",
                     children: thumbnails(spaces, removable: spaces > 1, first: firstNumber)),
                Node(name: "add \(cgID)", identifier: "mc.spaces.add", actionNames: [press]),
            ]),
        ])
    }

    /// macOS 27: the `mc.display` groups are children of the WindowManager application.
    private static let windowManagerOpen = Node(name: "WindowManager", children: [
        displayGroup(1, spaces: 5),
        displayGroup(4, spaces: 1, firstNumber: 6),
    ])

    /// macOS 26 and earlier: the Dock application has the group `mc`.
    private static let dockOpen = Node(name: "Dock", children: [
        Node(name: "dock list"),
        Node(name: "mc", identifier: "mc", children: [
            displayGroup(1, spaces: 3),
        ]),
    ])

    private static let windowManagerClosed = Node(name: "WindowManager")
    private static let dockClosed = Node(name: "Dock", children: [Node(name: "dock list")])

    // MARK: - Root

    func testRootInWindowManagerIsTheApplication() {
        let root = MissionControlTree.root(inApplication: Self.windowManagerOpen)
        XCTAssertEqual(root?.name, "WindowManager")
    }

    func testRootInDockIsTheMcGroup() {
        let root = MissionControlTree.root(inApplication: Self.dockOpen)
        XCTAssertEqual(root?.name, "mc")
    }

    func testNoRootWhenMissionControlIsClosed() {
        XCTAssertNil(MissionControlTree.root(inApplication: Self.windowManagerClosed))
        XCTAssertNil(MissionControlTree.root(inApplication: Self.dockClosed))
    }

    func testNoRootForOtherChildren() {
        let stageManager = Node(name: "WindowManager", children: [Node(name: "strip", identifier: "stage.strip")])
        XCTAssertNil(MissionControlTree.root(inApplication: stageManager))
    }

    // MARK: - Display groups and buttons

    func testAddButtonMatchesTheDisplay() throws {
        let root = try XCTUnwrap(MissionControlTree.root(inApplication: Self.windowManagerOpen))
        XCTAssertEqual(MissionControlTree.addButton(in: root, cgID: 1, sharedSpaces: false)?.name, "add 1")
        XCTAssertEqual(MissionControlTree.addButton(in: root, cgID: 4, sharedSpaces: false)?.name, "add 4")
    }

    func testAddButtonInDockLayout() throws {
        let root = try XCTUnwrap(MissionControlTree.root(inApplication: Self.dockOpen))
        XCTAssertEqual(MissionControlTree.addButton(in: root, cgID: 1, sharedSpaces: false)?.name, "add 1")
    }

    func testUnknownDisplayHasNoButtonWithoutSharedSpaces() throws {
        let root = try XCTUnwrap(MissionControlTree.root(inApplication: Self.windowManagerOpen))
        XCTAssertNil(MissionControlTree.addButton(in: root, cgID: 9, sharedSpaces: false))
    }

    func testSharedSpacesFallBackToAnyDisplayGroup() throws {
        let root = try XCTUnwrap(MissionControlTree.root(inApplication: Self.windowManagerOpen))
        XCTAssertEqual(MissionControlTree.addButton(in: root, cgID: 9, sharedSpaces: true)?.name, "add 1")
        // An exact match wins over the fallback.
        XCTAssertEqual(MissionControlTree.addButton(in: root, cgID: 4, sharedSpaces: true)?.name, "add 4")
    }

    func testSpacesListMatchesTheDisplay() throws {
        let root = try XCTUnwrap(MissionControlTree.root(inApplication: Self.windowManagerOpen))
        let list = try XCTUnwrap(MissionControlTree.spacesList(in: root, cgID: 1, sharedSpaces: false))
        XCTAssertEqual(list.name, "list 1")
        XCTAssertEqual(list.children.count, 5)
    }

    func testFindStopsAtMaxDepth() {
        let display = Self.displayGroup(1, spaces: 2)
        XCTAssertNil(MissionControlTree.find(identifier: "mc.spaces.list", in: display, maxDepth: 1))
        XCTAssertNotNil(MissionControlTree.find(identifier: "mc.spaces.list", in: display, maxDepth: 2))
    }

    // MARK: - Thumbnails

    func testThumbnailAtIndex() throws {
        let root = try XCTUnwrap(MissionControlTree.root(inApplication: Self.windowManagerOpen))
        let list = try XCTUnwrap(MissionControlTree.spacesList(in: root, cgID: 1, sharedSpaces: false))
        guard case .found(let node) = MissionControlTree.thumbnail(in: list, index: 3, spaceCount: 5) else {
            return XCTFail("Expected a thumbnail.")
        }
        XCTAssertEqual(node.name, "Desktop 4")
    }

    func testThumbnailNeedsMatchingCount() throws {
        let root = try XCTUnwrap(MissionControlTree.root(inApplication: Self.windowManagerOpen))
        let list = try XCTUnwrap(MissionControlTree.spacesList(in: root, cgID: 1, sharedSpaces: false))
        guard case .countMismatch(let count) = MissionControlTree.thumbnail(in: list, index: 3, spaceCount: 6) else {
            return XCTFail("Expected a count mismatch.")
        }
        XCTAssertEqual(count, 5)
        guard case .countMismatch = MissionControlTree.thumbnail(in: list, index: 5, spaceCount: 5) else {
            return XCTFail("Expected a count mismatch for an index out of range.")
        }
    }

    func testSingleDesktopHasNoRemoveAction() throws {
        let root = try XCTUnwrap(MissionControlTree.root(inApplication: Self.windowManagerOpen))
        let list = try XCTUnwrap(MissionControlTree.spacesList(in: root, cgID: 4, sharedSpaces: false))
        guard case .noRemoveAction(let node) = MissionControlTree.thumbnail(in: list, index: 0, spaceCount: 1) else {
            return XCTFail("Expected no remove action.")
        }
        XCTAssertEqual(node.name, "Desktop 6")
    }

    // MARK: - Close rules

    func testSessionThatDidNotToggleNeverCloses() {
        // Mission Control was open before the session, or the toggle failed.
        for seen in [false, true] {
            for visible in [false, true] {
                XCTAssertEqual(MissionControlSession.closeAction(toggled: false, treeSeen: seen, treeVisible: visible), .none)
            }
        }
    }

    func testVisibleTreeIsClosedWithToggleAndWait() {
        XCTAssertEqual(MissionControlSession.closeAction(toggled: true, treeSeen: true, treeVisible: true), .toggleAndWait)
    }

    func testTreeThatWentAwayNeedsNoClose() {
        // The user closed Mission Control while the session worked.
        XCTAssertEqual(MissionControlSession.closeAction(toggled: true, treeSeen: true, treeVisible: false), .none)
    }

    func testTreeThatNeverAppearedGetsOneMoreToggle() {
        // Unknown layout or a late open: a second toggle restores the state.
        XCTAssertEqual(MissionControlSession.closeAction(toggled: true, treeSeen: false, treeVisible: false), .blindToggle)
    }
}
