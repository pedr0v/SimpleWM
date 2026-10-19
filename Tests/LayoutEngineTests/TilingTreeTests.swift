import XCTest
@testable import LayoutEngine

/// Short window identifier for tests.
private func w(_ n: UInt32) -> WindowID { WindowID(n) }

/// Returns the window identifiers as numbers, in tree order.
private func order(_ t: TilingTree) -> [UInt32] { t.windows.map(\.raw) }

/// Returns a tree that holds windows `ns`, inserted in order.
private func tree(_ ns: UInt32..., root: Orientation = .horizontal) -> TilingTree {
    var t = TilingTree(root: root)
    for n in ns { t.insert(w(n)) }
    return t
}

private let area = Rect(x: 0, y: 0, w: 1000, h: 600)

private func frames(_ t: TilingTree, gaps: Gaps = .none) -> [WindowID: Rect] {
    t.layout(in: area, gaps: gaps)
}

/// Checks the internal links of the tree: parents match children, weights
/// and mru match children, no orphan nodes.
private func assertConsistent(_ t: TilingTree, file: StaticString = #filePath, line: UInt = #line) {
    var seen: Set<NodeID> = [t.root]
    var stack = [t.root]
    while let id = stack.popLast() {
        guard case .container(let c)? = t.nodes[id] else { continue }
        XCTAssertEqual(c.children.count, c.weights.count, "weights", file: file, line: line)
        XCTAssertEqual(c.mru.sorted(), Array(c.children.indices), "mru", file: file, line: line)
        XCTAssertTrue(c.weights.allSatisfy { $0 > 0 }, "weights > 0", file: file, line: line)
        if id != t.root {
            XCTAssertGreaterThanOrEqual(c.children.count, 1, "empty container", file: file, line: line)
        }
        for child in c.children {
            XCTAssertEqual(t.parents[child], id, "parent link", file: file, line: line)
            seen.insert(child)
            stack.append(child)
        }
    }
    XCTAssertEqual(Set(t.nodes.keys), seen, "orphan nodes", file: file, line: line)
    XCTAssertEqual(Set(t.parents.keys), seen.subtracting([t.root]), "orphan parents", file: file, line: line)
    if let f = t.focused { XCTAssertTrue(t.contains(f), "focused present", file: file, line: line) }
    if let z = t.zoomed { XCTAssertEqual(z, t.focused, "zoomed is focused", file: file, line: line) }
}

final class TilingTreeTests: XCTestCase {

    // MARK: Layout

    func testEmptyTree() {
        var t = TilingTree(root: .horizontal)
        XCTAssertTrue(t.isEmpty)
        XCTAssertEqual(t.windows, [])
        XCTAssertEqual(frames(t), [:])
        XCTAssertNil(t.neighbor(.left))
        XCTAssertFalse(t.moveFocused(.right))
        t.toggleSplit()
        t.toggleZoom()
        t.balance()
        t.resize(delta: 0.1)
        t.remove(w(1))
        XCTAssertNil(t.zoomed)
        assertConsistent(t)
    }

    func testOneWindowFillsAreaMinusOuterGap() {
        let t = tree(1)
        XCTAssertEqual(t.focused, w(1))
        XCTAssertEqual(frames(t, gaps: Gaps(inner: 5, outer: 10)), [w(1): Rect(x: 10, y: 10, w: 980, h: 580)])
        XCTAssertEqual(frames(t), [w(1): area])
    }

    func testTwoWindowsSplitEqually() {
        let t = tree(1, 2)
        XCTAssertEqual(frames(t), [
            w(1): Rect(x: 0, y: 0, w: 500, h: 600),
            w(2): Rect(x: 500, y: 0, w: 500, h: 600),
        ])
    }

    func testTwoWindowsWithGaps() {
        let t = tree(1, 2)
        XCTAssertEqual(t.layout(in: area, gaps: Gaps(inner: 10, outer: 20)), [
            w(1): Rect(x: 20, y: 20, w: 475, h: 560),
            w(2): Rect(x: 505, y: 20, w: 475, h: 560),
        ])
    }

    func testThreeWindowsTakeHalfOfFocused() {
        let t = tree(1, 2, 3)
        XCTAssertEqual(order(t), [1, 2, 3])
        XCTAssertEqual(frames(t), [
            w(1): Rect(x: 0, y: 0, w: 500, h: 600),
            w(2): Rect(x: 500, y: 0, w: 250, h: 600),
            w(3): Rect(x: 750, y: 0, w: 250, h: 600),
        ])
        assertConsistent(t)
    }

    func testVerticalRoot() {
        let t = tree(1, 2, root: .vertical)
        XCTAssertEqual(frames(t), [
            w(1): Rect(x: 0, y: 0, w: 1000, h: 300),
            w(2): Rect(x: 0, y: 300, w: 1000, h: 300),
        ])
    }

    func testLayoutOffsetAreaAndRounding() {
        var t = tree(1, 2, 3)
        t.balance()
        let f = t.layout(in: Rect(x: 100, y: 50, w: 1000, h: 600), gaps: .none)
        XCTAssertEqual(f[w(1)], Rect(x: 100, y: 50, w: 333, h: 600))
        XCTAssertEqual(f[w(2)], Rect(x: 433, y: 50, w: 334, h: 600))
        XCTAssertEqual(f[w(3)], Rect(x: 767, y: 50, w: 333, h: 600))
    }

    // MARK: Insert and remove

    func testInsertGoesAfterFocused() {
        var t = tree(1, 2, 3)
        t.setFocus(w(1))
        t.insert(w(4))
        XCTAssertEqual(order(t), [1, 4, 2, 3])
        XCTAssertEqual(t.focused, w(4))
        XCTAssertEqual(t.weight(of: w(1)), 0.25)
        XCTAssertEqual(t.weight(of: w(4)), 0.25)
        assertConsistent(t)
    }

    func testInsertDuplicateDoesNothing() {
        var t = tree(1, 2)
        t.setFocus(w(1))
        let before = t
        t.insert(w(2))
        XCTAssertEqual(t, before)
    }

    func testRemoveCollapsesContainer() {
        var t = tree(1, 2)
        t.split(.vertical)
        t.insert(w(3))
        // H[1, V[2, 3]]
        XCTAssertEqual(t.parentContainer(of: w(3))?.orientation, .vertical)
        XCTAssertEqual(t.nodes.count, 5)
        t.remove(w(3))
        // H[1, 2]
        XCTAssertEqual(order(t), [1, 2])
        XCTAssertEqual(t.nodes.count, 3)
        XCTAssertEqual(t.parents[t.leafID(of: w(2))!], t.root)
        XCTAssertEqual(t.weight(of: w(2)), 0.5)
        XCTAssertEqual(t.focused, w(2))
        XCTAssertEqual(frames(t)[w(2)], Rect(x: 500, y: 0, w: 500, h: 600))
        assertConsistent(t)
    }

    func testRemoveDropsEmptyContainer() {
        var t = tree(1, 2)
        t.split(.vertical)
        // H[1, V[2]]
        XCTAssertEqual(t.nodes.count, 4)
        t.remove(w(2))
        XCTAssertEqual(order(t), [1])
        XCTAssertEqual(t.nodes.count, 2)
        XCTAssertEqual(t.focused, w(1))
        assertConsistent(t)
    }

    func testRemoveFocusedMovesFocusToMruSibling() {
        var t = tree(1, 2, 3)
        t.setFocus(w(1))
        t.setFocus(w(3))
        t.remove(w(3))
        XCTAssertEqual(t.focused, w(1))
        t.remove(w(1))
        XCTAssertEqual(t.focused, w(2))
        t.remove(w(2))
        XCTAssertNil(t.focused)
        XCTAssertTrue(t.isEmpty)
        assertConsistent(t)
    }

    func testRemoveFocusedLastInContainerFocusesOutside() {
        var t = tree(1, 2)
        t.split(.vertical)
        // H[1, V[2]]
        t.setFocus(w(2))
        t.remove(w(2))
        XCTAssertEqual(t.focused, w(1))
    }

    func testRemoveUnfocusedKeepsFocus() {
        var t = tree(1, 2, 3)
        t.setFocus(w(2))
        t.remove(w(3))
        XCTAssertEqual(t.focused, w(2))
        t.remove(w(9))
        XCTAssertEqual(order(t), [1, 2])
    }

    func testReconcileAddsAndRemoves() {
        var t = tree(1, 2, 3)
        t.reconcile(present: [w(1), w(3), w(5), w(6)])
        XCTAssertEqual(order(t), [1, 3, 5, 6])
        XCTAssertEqual(t.focused, w(6))
        let before = t
        t.reconcile(present: [w(6), w(5), w(3), w(1)])
        XCTAssertEqual(t, before)
        t.reconcile(present: [])
        XCTAssertTrue(t.isEmpty)
        XCTAssertNil(t.focused)
        assertConsistent(t)
    }

    // MARK: Focus

    /// Builds H[1, V[2, 3], 4] with focus on 3.
    private func nested() -> TilingTree {
        var t = tree(1, 2, 4)
        t.setFocus(w(2))
        t.split(.vertical)
        t.insert(w(3))
        return t
    }

    func testNestedLayout() {
        let t = nested()
        XCTAssertEqual(order(t), [1, 2, 3, 4])
        XCTAssertEqual(frames(t), [
            w(1): Rect(x: 0, y: 0, w: 500, h: 600),
            w(2): Rect(x: 500, y: 0, w: 250, h: 300),
            w(3): Rect(x: 500, y: 300, w: 250, h: 300),
            w(4): Rect(x: 750, y: 0, w: 250, h: 600),
        ])
        assertConsistent(t)
    }

    func testFocusAcrossNestedContainers() {
        var t = nested()
        XCTAssertEqual(t.focused, w(3))
        XCTAssertEqual(t.neighbor(.up), w(2))
        XCTAssertNil(t.neighbor(.down))
        XCTAssertEqual(t.neighbor(.left), w(1))
        XCTAssertEqual(t.neighbor(.right), w(4))

        t.setFocus(w(1))
        XCTAssertNil(t.neighbor(.left))
        XCTAssertNil(t.neighbor(.up))
        XCTAssertNil(t.neighbor(.down))
        XCTAssertEqual(t.neighbor(.right), w(3), "mru picks 3")

        t.setFocus(w(2))
        t.setFocus(w(4))
        XCTAssertEqual(t.neighbor(.left), w(2), "mru picks 2")
        XCTAssertNil(t.neighbor(.right))

        t.setFocus(w(3))
        t.setFocus(w(4))
        XCTAssertEqual(t.neighbor(.left), w(3), "mru picks 3")
    }

    func testFocusIgnoresAbsentWindow() {
        var t = tree(1, 2)
        t.setFocus(w(9))
        XCTAssertEqual(t.focused, w(2))
    }

    // MARK: Move

    func testMoveSwapsWithSiblingLeaf() {
        var t = tree(1, 2, 3)
        t.setFocus(w(1))
        XCTAssertTrue(t.moveFocused(.right))
        XCTAssertEqual(order(t), [2, 1, 3])
        XCTAssertEqual(t.focused, w(1))
        XCTAssertEqual(t.weight(of: w(1)), 0.5, "weight moves with the window")
        XCTAssertEqual(frames(t)[w(1)], Rect(x: 250, y: 0, w: 500, h: 600))
        XCTAssertTrue(t.moveFocused(.left))
        XCTAssertEqual(order(t), [1, 2, 3])
        XCTAssertFalse(t.moveFocused(.left), "root edge")
        XCTAssertEqual(order(t), [1, 2, 3])
        assertConsistent(t)
    }

    func testMoveKeepsMruWithSwap() {
        var t = tree(1, 2)
        t.setFocus(w(1))
        t.moveFocused(.right)
        // H[2, 1], 1 focused. Remove 1: focus goes to 2.
        t.remove(w(1))
        XCTAssertEqual(t.focused, w(2))
    }

    func testMoveIntoSiblingContainerAtNearEdge() {
        var t = tree(1, 2)
        t.split(.vertical)
        t.insert(w(3))
        // H[1, V[2, 3]]
        t.setFocus(w(1))
        XCTAssertTrue(t.moveFocused(.right))
        XCTAssertEqual(order(t), [1, 2, 3])
        XCTAssertEqual(t.parentContainer(of: w(1))?.orientation, .vertical)
        XCTAssertEqual(t.focused, w(1))
        // Root keeps one child: V[1, 2, 3].
        XCTAssertEqual(t.container(t.root)?.children.count, 1)
        assertConsistent(t)
    }

    func testMoveIntoSiblingContainerFromRight() {
        var t = tree(1, 2)
        t.setFocus(w(1))
        t.split(.vertical)
        t.insert(w(3))
        // H[V[1, 3], 2]
        XCTAssertEqual(order(t), [1, 3, 2])
        t.setFocus(w(2))
        XCTAssertTrue(t.moveFocused(.left))
        XCTAssertEqual(order(t), [1, 3, 2], "2 enters V at the end")
        XCTAssertEqual(t.parentContainer(of: w(2))?.children.count, 3)
        assertConsistent(t)
    }

    func testMoveOutToGrandparent() {
        var t = nested()
        // H[1, V[2, 3], 4], move 2 left.
        t.setFocus(w(2))
        XCTAssertTrue(t.moveFocused(.left))
        XCTAssertEqual(order(t), [1, 2, 3, 4])
        XCTAssertEqual(t.container(t.root)?.children.count, 4, "V collapses")
        XCTAssertEqual(t.parents[t.leafID(of: w(3))!], t.root)
        XCTAssertEqual(t.focused, w(2))
        assertConsistent(t)
    }

    func testMoveOutToGrandparentForward() {
        var t = nested()
        // H[1, V[2, 3], 4], move 3 right.
        XCTAssertTrue(t.moveFocused(.right))
        XCTAssertEqual(order(t), [1, 2, 3, 4])
        XCTAssertEqual(t.container(t.root)?.children.count, 4)
        assertConsistent(t)
    }

    func testMoveOutOfDeepContainer() {
        var t = nested()
        // H[1, V[2, H[3, 5]], 4]
        t.split(.horizontal)
        t.insert(w(5))
        XCTAssertEqual(order(t), [1, 2, 3, 5, 4])
        // 5 sits at the right edge of the inner H. Climb past V to the root.
        XCTAssertTrue(t.moveFocused(.right))
        XCTAssertEqual(order(t), [1, 2, 3, 5, 4])
        XCTAssertEqual(t.parents[t.leafID(of: w(5))!], t.root)
        XCTAssertEqual(t.parentContainer(of: w(3))?.orientation, .vertical, "inner H collapses into V")
        assertConsistent(t)
    }

    func testMoveAtRootEdgeCreatesNewRootSplit() {
        var t = tree(1, 2, 3)
        XCTAssertTrue(t.moveFocused(.up))
        let rc = t.container(t.root)!
        XCTAssertEqual(rc.orientation, .vertical)
        XCTAssertEqual(rc.children.count, 2)
        XCTAssertEqual(rc.children[0], t.leafID(of: w(3)))
        XCTAssertEqual(t.container(rc.children[1])?.orientation, .horizontal)
        XCTAssertEqual(order(t), [3, 1, 2])
        XCTAssertEqual(t.focused, w(3))
        XCTAssertEqual(frames(t), [
            w(3): Rect(x: 0, y: 0, w: 1000, h: 300),
            w(1): Rect(x: 0, y: 300, w: 667, h: 300),
            w(2): Rect(x: 667, y: 300, w: 333, h: 300),
        ])
        XCTAssertFalse(t.moveFocused(.up), "already at the top edge")
        assertConsistent(t)
    }

    func testMoveAtRootWithTwoWindowsFlipsRoot() {
        var t = tree(1, 2)
        XCTAssertTrue(t.moveFocused(.down))
        XCTAssertEqual(t.container(t.root)?.orientation, .vertical)
        XCTAssertEqual(order(t), [1, 2])
        XCTAssertEqual(t.nodes.count, 3, "no extra container")
        XCTAssertEqual(frames(t)[w(2)], Rect(x: 0, y: 300, w: 1000, h: 300))
        XCTAssertFalse(t.moveFocused(.down))
        XCTAssertTrue(t.moveFocused(.left))
        XCTAssertEqual(t.container(t.root)?.orientation, .horizontal)
        XCTAssertEqual(order(t), [2, 1])
        assertConsistent(t)
    }

    func testMoveSingleWindowFails() {
        var t = tree(1)
        for d in Direction.allCases {
            XCTAssertFalse(t.moveFocused(d))
        }
        XCTAssertEqual(order(t), [1])
        XCTAssertEqual(t.container(t.root)?.orientation, .horizontal)
    }

    func testMoveInsideOneChildRootChainFailsAtEdge() {
        var t = tree(1, 2)
        t.split(.vertical)
        t.insert(w(3))
        t.remove(w(1))
        // H[V[2, 3]]: V acts as the root.
        t.setFocus(w(2))
        XCTAssertFalse(t.moveFocused(.up))
        XCTAssertEqual(order(t), [2, 3])
    }

    func testMoveClearsZoom() {
        var t = tree(1, 2)
        t.toggleZoom()
        XCTAssertEqual(t.zoomed, w(2))
        t.moveFocused(.left)
        XCTAssertNil(t.zoomed)
    }

    // MARK: Split

    func testToggleSplitThenInsertGoesVertical() {
        var t = tree(1, 2)
        t.toggleSplit()
        XCTAssertEqual(t.container(t.root)?.orientation, .vertical)
        t.insert(w(3))
        XCTAssertEqual(order(t), [1, 2, 3])
        XCTAssertEqual(frames(t), [
            w(1): Rect(x: 0, y: 0, w: 1000, h: 300),
            w(2): Rect(x: 0, y: 300, w: 1000, h: 150),
            w(3): Rect(x: 0, y: 450, w: 1000, h: 150),
        ])
        t.toggleSplit()
        XCTAssertEqual(t.container(t.root)?.orientation, .horizontal)
    }

    func testSplitWrapsFocusedLeaf() {
        var t = tree(1, 2)
        t.split(.vertical)
        XCTAssertEqual(frames(t)[w(2)], Rect(x: 500, y: 0, w: 500, h: 600), "wrapper keeps the slot")
        t.insert(w(3))
        XCTAssertEqual(frames(t), [
            w(1): Rect(x: 0, y: 0, w: 500, h: 600),
            w(2): Rect(x: 500, y: 0, w: 500, h: 300),
            w(3): Rect(x: 500, y: 300, w: 500, h: 300),
        ])
        assertConsistent(t)
    }

    func testSplitOnlyChildSetsOrientation() {
        var t = tree(1)
        t.split(.vertical)
        XCTAssertEqual(t.nodes.count, 2)
        XCTAssertEqual(t.container(t.root)?.orientation, .vertical)
    }

    // MARK: Zoom

    func testZoom() {
        var t = tree(1, 2)
        let gaps = Gaps(inner: 10, outer: 20)
        let normal = t.layout(in: area, gaps: gaps)
        t.toggleZoom()
        XCTAssertEqual(t.zoomed, w(2))
        let zoomed = t.layout(in: area, gaps: gaps)
        XCTAssertEqual(zoomed[w(2)], Rect(x: 20, y: 20, w: 960, h: 560))
        XCTAssertEqual(zoomed[w(1)], normal[w(1)], "other windows keep frames")
        t.toggleZoom()
        XCTAssertNil(t.zoomed)
        XCTAssertEqual(t.layout(in: area, gaps: gaps), normal)
    }

    func testZoomClearsOnFocusChangeAndRemove() {
        var t = tree(1, 2)
        t.toggleZoom()
        t.setFocus(w(2))
        XCTAssertEqual(t.zoomed, w(2), "same focus keeps zoom")
        t.setFocus(w(1))
        XCTAssertNil(t.zoomed)
        t.toggleZoom()
        XCTAssertEqual(t.zoomed, w(1))
        t.remove(w(1))
        XCTAssertNil(t.zoomed)
        XCTAssertEqual(t.focused, w(2))
    }

    // MARK: Balance and resize

    func testBalance() {
        var t = nested()
        t.balance()
        let f = frames(t)
        XCTAssertEqual(f[w(1)], Rect(x: 0, y: 0, w: 333, h: 600))
        XCTAssertEqual(f[w(2)], Rect(x: 333, y: 0, w: 334, h: 300))
        XCTAssertEqual(f[w(3)], Rect(x: 333, y: 300, w: 334, h: 300))
        XCTAssertEqual(f[w(4)], Rect(x: 667, y: 0, w: 333, h: 600))
    }

    func testResize() {
        var t = tree(1, 2)
        t.setFocus(w(1))
        t.resize(delta: 0.1)
        XCTAssertEqual(frames(t)[w(1)], Rect(x: 0, y: 0, w: 600, h: 600))
        XCTAssertEqual(frames(t)[w(2)], Rect(x: 600, y: 0, w: 400, h: 600))
        t.resize(delta: -1)
        XCTAssertEqual(frames(t)[w(1)]?.w, 50, "clamps at minimum weight")
        t.resize(delta: 5)
        XCTAssertEqual(frames(t)[w(1)]?.w, 950, "clamps at sibling minimum weight")
        assertConsistent(t)
    }

    func testResizeLastWindowUsesPreviousSibling() {
        var t = tree(1, 2, 3)
        t.balance()
        t.resize(delta: 0.1)
        let f = frames(t)
        XCTAssertEqual(f[w(1)]?.w, 333)
        XCTAssertEqual(f[w(3)]?.w, 433)
        XCTAssertEqual(f[w(2)]?.w, 234)
    }

    func testResizeSingleWindowDoesNothing() {
        var t = tree(1)
        let before = t
        t.resize(delta: 0.2)
        XCTAssertEqual(t, before)
    }
}

final class WMStateTests: XCTestCase {
    private let a = SpaceKey(display: DisplayID("D1"), space: SpaceID(1))
    private let b = SpaceKey(display: DisplayID("D1"), space: SpaceID(2))

    func testTransferMovesWindowBetweenTrees() {
        var s = WMState()
        s.update(a) { $0.insert(w(1)); $0.insert(w(2)) }
        s.update(b) { $0.insert(w(3)) }
        s.transfer(w(2), from: a, to: b)
        XCTAssertEqual(s.tree(for: a).windows, [w(1)])
        XCTAssertEqual(s.tree(for: a).focused, w(1))
        XCTAssertEqual(s.tree(for: b).windows, [w(3), w(2)])
        XCTAssertEqual(s.tree(for: b).focused, w(2))
        XCTAssertEqual(s.key(of: w(2)), b)
    }

    func testTransferCreatesDestinationTree() {
        var s = WMState(rootOrientation: .vertical)
        s.update(a) { $0.insert(w(1)) }
        s.transfer(w(1), from: a, to: b)
        XCTAssertTrue(s.tree(for: a).isEmpty)
        XCTAssertEqual(s.trees[b]?.windows, [w(1)])
        XCTAssertEqual(s.trees[b]?.container(s.trees[b]!.root)?.orientation, .vertical)
    }

    func testTransferIgnoresAbsentWindowAndSameKey() {
        var s = WMState()
        s.update(a) { $0.insert(w(1)) }
        let before = s
        s.transfer(w(9), from: a, to: b)
        s.transfer(w(1), from: a, to: a)
        s.transfer(w(1), from: b, to: a)
        XCTAssertEqual(s, before)
    }

    func testPruneKeepsLiveTrees() {
        var s = WMState()
        s.update(a) { $0.insert(w(1)) }
        s.update(b) { $0.insert(w(2)) }
        s.prune(live: [a])
        XCTAssertEqual(Array(s.trees.keys), [a])
        XCTAssertNil(s.key(of: w(2)))
    }
}
