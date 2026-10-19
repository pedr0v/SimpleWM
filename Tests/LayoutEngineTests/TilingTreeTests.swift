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

    func testMoveIntoSiblingContainerOnOtherAxisGoesAfterMruChild() {
        var t = tree(1, 2)
        t.split(.vertical)
        t.insert(w(3))
        // H[1, V[2, 3]], mru of V picks 3.
        t.setFocus(w(1))
        XCTAssertTrue(t.moveFocused(.right))
        XCTAssertEqual(order(t), [2, 3, 1])
        XCTAssertEqual(t.parentContainer(of: w(1))?.orientation, .vertical)
        XCTAssertEqual(t.focused, w(1))
        // Root keeps one child: V[2, 3, 1].
        XCTAssertEqual(t.container(t.root)?.children.count, 1)
        assertConsistent(t)

        var u = tree(1, 2)
        u.split(.vertical)
        u.insert(w(3))
        u.setFocus(w(2))
        u.setFocus(w(1))
        XCTAssertTrue(u.moveFocused(.right))
        XCTAssertEqual(order(u), [2, 1, 3], "mru picks 2")
        assertConsistent(u)
    }

    func testMoveIntoSiblingContainerOnOtherAxisIsSymmetric() {
        // The entry point does not depend on the direction. Both moves land
        // after the most recent child of the container.
        var right = tree(1, 2)
        right.split(.vertical)
        right.insert(w(3))
        right.setFocus(w(2))
        right.setFocus(w(1))
        XCTAssertTrue(right.moveFocused(.right))

        var left = tree(1, 2)
        left.setFocus(w(1))
        left.split(.vertical)
        left.insert(w(4))
        // H[V[1, 4], 2]
        left.setFocus(w(1))
        left.setFocus(w(2))
        XCTAssertTrue(left.moveFocused(.left))
        XCTAssertEqual(order(left), [1, 2, 4], "2 enters after the mru child 1")
        XCTAssertEqual(order(right), [2, 1, 3])
        assertConsistent(left)
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

    // MARK: Insert and remove are inverses

    func testRemoveUndoesInsertWeights() {
        var t = tree(1, 2)
        let before = frames(t)
        for _ in 0..<3 {
            t.insert(w(3))
            XCTAssertEqual(frames(t)[w(2)]?.w, 250)
            t.remove(w(3))
            XCTAssertEqual(frames(t), before, "window 2 gets its half back")
        }
        XCTAssertEqual(t.focused, w(2))
        assertConsistent(t)
    }

    func testRemoveGivesWeightToPreviousSiblingOrNextForFirst() {
        var t = tree(1, 2, 3)
        // Weights 0.5, 0.25, 0.25. Remove 2: window 1 takes 0.25.
        t.remove(w(2))
        XCTAssertEqual(t.weight(of: w(1)), 0.75)
        XCTAssertEqual(t.weight(of: w(3)), 0.25)
        // Remove 1 (first child): window 3 takes its weight.
        t.remove(w(1))
        XCTAssertEqual(t.weight(of: w(3)), 1.0)
        assertConsistent(t)
    }

    func testRemoveInsertChurnKeepsLayoutStable() {
        var t = tree(1, 2, 3)
        t.setFocus(w(2))
        let before = frames(t)
        for _ in 0..<5 {
            t.setFocus(w(2))
            t.insert(w(9))
            t.remove(w(9))
            t.setFocus(w(2))
        }
        XCTAssertEqual(frames(t), before)
    }

    // MARK: Bulk reconcile

    func testReconcileManyNewWindowsGetEqualShares() {
        var t = TilingTree(root: .horizontal)
        t.reconcile(present: (1...6).map { w(UInt32($0)) })
        XCTAssertEqual(order(t), [1, 2, 3, 4, 5, 6])
        let wide = Rect(x: 0, y: 0, w: 1512, h: 949)
        let f = t.layout(in: wide, gaps: Gaps(inner: 8, outer: 8))
        let widths = (1...6).map { f[w(UInt32($0))]!.w }
        // Free width is 1496 - 40 = 1456. Each window gets about 242.7 pt.
        XCTAssertTrue(widths.allSatisfy { abs($0 - 243) <= 1 }, "\(widths)")
        assertConsistent(t)
    }

    func testReconcileTwoNewWindowsMakeQuarters() {
        var t = tree(1, 2)
        t.reconcile(present: [w(1), w(2), w(3), w(4)])
        XCTAssertEqual(frames(t).values.map(\.w).sorted(), [250, 250, 250, 250])
        assertConsistent(t)
    }

    func testReconcileOneNewWindowKeepsHalfRule() {
        var t = tree(1, 2)
        t.reconcile(present: [w(1), w(2), w(3)])
        XCTAssertEqual(frames(t)[w(2)]?.w, 250)
        XCTAssertEqual(frames(t)[w(3)]?.w, 250)
        XCTAssertEqual(frames(t)[w(1)]?.w, 500)
    }

    func testReconcileIgnoresDuplicateIDsInList() {
        var t = TilingTree(root: .horizontal)
        t.reconcile(present: [w(1), w(1), w(2)])
        XCTAssertEqual(order(t), [1, 2])
        assertConsistent(t)
    }

    func testInsertEqualWeightKeepsFocusedWeight() {
        var t = tree(1, 2)
        t.setFocus(w(1))
        t.insert(w(3), equalWeight: true)
        XCTAssertEqual(order(t), [1, 3, 2])
        XCTAssertEqual(t.weight(of: w(1)), 0.5)
        XCTAssertEqual(t.weight(of: w(3)), 0.5)
        XCTAssertEqual(t.focused, w(3))
    }

    // MARK: Flatten

    /// Builds H[1, V[2, H[3, 4]]] with focus on 4.
    private func deepNested() -> TilingTree {
        var t = tree(1, 2)
        t.split(.vertical)
        t.insert(w(3))
        t.split(.horizontal)
        t.insert(w(4))
        return t
    }

    func testRemoveFlattensSameOrientationNesting() {
        var t = deepNested()
        XCTAssertEqual(order(t), [1, 2, 3, 4])
        t.remove(w(2))
        // H[1, H[3, 4]] becomes H[1, 3, 4].
        XCTAssertEqual(order(t), [1, 3, 4])
        XCTAssertEqual(t.container(t.root)?.children.count, 3)
        XCTAssertEqual(t.parents[t.leafID(of: w(3))!], t.root)
        XCTAssertEqual(t.parents[t.leafID(of: w(4))!], t.root)
        // The spliced windows keep the slot of the old container.
        XCTAssertEqual(t.weight(of: w(1)), 0.5)
        XCTAssertEqual((t.weight(of: w(3)) ?? 0) + (t.weight(of: w(4)) ?? 0), 0.5, accuracy: 1e-9)
        t.balance()
        let widths = [1, 3, 4].map { frames(t)[w(UInt32($0))]!.w }
        XCTAssertEqual(widths, [333, 334, 333], "thirds")
        assertConsistent(t)
    }

    func testMoveAfterFlattenNeedsOnePress() {
        var t = deepNested()
        t.remove(w(2))
        t.setFocus(w(3))
        XCTAssertTrue(t.moveFocused(.left))
        XCTAssertEqual(order(t), [3, 1, 4], "3 swaps with 1")
        assertConsistent(t)
    }

    func testFlattenKeepsMruOrder() {
        var t = deepNested()
        // Focus order: 3 last, then 1.
        t.setFocus(w(4))
        t.setFocus(w(3))
        t.setFocus(w(1))
        t.remove(w(2))
        // H[1, 3, 4]. Focus moves right: the engine enters 3 (mru of the old H).
        XCTAssertEqual(t.neighbor(.right), w(3))
        assertConsistent(t)
    }

    func testMoveAtRootDoesNotNestSameOrientation() {
        var t = tree(1, 2)
        t.split(.vertical)
        t.insert(w(3))
        // H[1, V[2, 3]]
        t.setFocus(w(1))
        XCTAssertTrue(t.moveFocused(.up))
        // V[1, 2, 3], not V[1, V[2, 3]].
        XCTAssertEqual(t.container(t.root)?.orientation, .vertical)
        XCTAssertEqual(t.container(t.root)?.children.count, 3)
        XCTAssertEqual(order(t), [1, 2, 3])
        XCTAssertEqual(t.focused, w(1))
        assertConsistent(t)
        // A later move down swaps with 2 and changes the picture.
        XCTAssertTrue(t.moveFocused(.down))
        XCTAssertEqual(order(t), [2, 1, 3])
        assertConsistent(t)
    }

    func testRemoveCollapsesRootWrapperOfOneLeaf() {
        var t = TilingTree(root: .horizontal)
        t.insert(w(2))
        t.insert(w(1))
        t.split(.vertical)
        // H[2, V[1]]
        t.remove(w(2))
        XCTAssertEqual(t.nodes.count, 2, "root and one leaf")
        XCTAssertEqual(t.container(t.root)?.orientation, .vertical, "root takes the wrapper orientation")
        XCTAssertEqual(order(t), [1])
        for d in Direction.allCases {
            XCTAssertFalse(t.moveFocused(d), "no move for a lone window: \(d)")
        }
        // The next window goes below, as the wrapper asked.
        t.insert(w(5))
        XCTAssertEqual(frames(t)[w(5)], Rect(x: 0, y: 300, w: 1000, h: 300))
        assertConsistent(t)
    }

    // MARK: Fuzz

    /// Checks that no container holds a child container with its own
    /// orientation. Only `toggleSplit` and `split` can make such nesting.
    private func assertNoSameOrientationNesting(_ t: TilingTree, _ context: String,
                                                file: StaticString = #filePath, line: UInt = #line) {
        for (id, node) in t.nodes {
            guard case .container(let c) = node else { continue }
            for child in c.children {
                if let cc = t.container(child) {
                    XCTAssertNotEqual(cc.orientation, c.orientation, "nested same orientation: \(context)",
                                      file: file, line: line)
                }
            }
            if id != t.root {
                XCTAssertGreaterThanOrEqual(c.children.count, 2, "one-child container: \(context)",
                                            file: file, line: line)
            }
        }
    }

    func testRandomInsertRemoveFocusMoveKeepsTreeFlat() {
        continueAfterFailure = false
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        for run in 0..<400 {
            var t = TilingTree(root: next(2) == 0 ? .horizontal : .vertical)
            var live: [UInt32] = []
            var nextWindow: UInt32 = 1
            var log: [String] = []
            for step in 0..<40 {
                switch next(6) {
                case 0, 1:
                    t.insert(w(nextWindow))
                    live.append(nextWindow)
                    log.append("insert \(nextWindow)")
                    nextWindow += 1
                case 2:
                    guard let victim = live.indices.randomElementIndex(next) else { break }
                    let id = live.remove(at: victim)
                    t.remove(w(id))
                    log.append("remove \(id)")
                case 3:
                    guard let pick = live.indices.randomElementIndex(next) else { break }
                    t.setFocus(w(live[pick]))
                    log.append("focus \(live[pick])")
                default:
                    let d = Direction.allCases[next(4)]
                    t.moveFocused(d)
                    log.append("move \(d)")
                }
                let context = "run \(run) step \(step): \(log.joined(separator: ", "))"
                assertNoSameOrientationNesting(t, context)
                XCTAssertEqual(Set(t.windows), Set(live.map { w($0) }), context)
            }
            assertConsistent(t)
        }
    }
}

private extension Range where Bound == Int {
    /// Returns a random index from the range, or nil when it is empty.
    func randomElementIndex(_ next: (Int) -> Int) -> Int? {
        isEmpty ? nil : lowerBound + next(count)
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

    func testTransferIgnoresSameKey() {
        var s = WMState()
        s.update(a) { $0.insert(w(1)) }
        let before = s
        s.transfer(w(1), from: a, to: a)
        XCTAssertEqual(s, before)
    }

    func testTransferWorksWhenRefreshAlreadyDroppedTheWindow() {
        // A refresh removed the window from `from` while the move ran.
        var s = WMState()
        s.update(a) { $0.insert(w(1)) }
        s.update(b) { $0.insert(w(3)) }
        s.transfer(w(2), from: a, to: b)
        XCTAssertEqual(s.tree(for: a).windows, [w(1)])
        XCTAssertEqual(s.tree(for: b).windows, [w(3), w(2)])
        XCTAssertEqual(s.tree(for: b).focused, w(2))
    }

    func testTransferRemovesWindowFromAnyOtherTree() {
        let c = SpaceKey(display: DisplayID("D1"), space: SpaceID(3))
        var s = WMState()
        s.update(c) { $0.insert(w(1)); $0.insert(w(2)) }
        // `from` is wrong. The window still leaves the tree that holds it.
        s.transfer(w(2), from: a, to: b)
        XCTAssertEqual(s.tree(for: c).windows, [w(1)])
        XCTAssertEqual(s.tree(for: b).windows, [w(2)])
        XCTAssertEqual(s.key(of: w(2)), b)
    }

    func testRekeyMovesTreeToTheDisplayThatNowHoldsItsSpace() {
        let d2 = DisplayID("D2")
        var s = WMState()
        s.update(a) { $0.insert(w(1)); $0.insert(w(2)) }
        s.update(b) { $0.insert(w(3)) }
        // Space 1 moved to display D2. Space 2 stays on D1.
        s.rekey(owners: [SpaceID(1): [d2], SpaceID(2): [DisplayID("D1")]])
        let moved = SpaceKey(display: d2, space: SpaceID(1))
        XCTAssertNil(s.trees[a])
        XCTAssertEqual(s.trees[moved]?.windows, [w(1), w(2)])
        XCTAssertEqual(s.trees[b]?.windows, [w(3)])
    }

    func testRekeyKeepsTreesWithShownOwnerOrUnknownSpace() {
        var s = WMState()
        s.update(a) { $0.insert(w(1)) }
        let before = s
        s.rekey(owners: [SpaceID(1): [DisplayID("D1"), DisplayID("D2")]])
        s.rekey(owners: [SpaceID(9): [DisplayID("D2")]])
        s.rekey(owners: [:])
        XCTAssertEqual(s, before)
    }

    func testRekeyKeepsNonEmptyDestinationTree() {
        let d2 = DisplayID("D2")
        var s = WMState()
        s.update(a) { $0.insert(w(1)) }
        let moved = SpaceKey(display: d2, space: SpaceID(1))
        s.update(moved) { $0.insert(w(5)) }
        s.rekey(owners: [SpaceID(1): [d2]])
        XCTAssertNil(s.trees[a])
        XCTAssertEqual(s.trees[moved]?.windows, [w(5)])
    }

    func testPruneLiveSpacesKeepsTreesByTheirSpaceID() {
        var s = WMState()
        s.update(a) { $0.insert(w(1)) }
        s.update(b) { $0.insert(w(2)) }
        s.prune(liveSpaces: [SpaceID(2)])
        XCTAssertEqual(Array(s.trees.keys), [b])
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
