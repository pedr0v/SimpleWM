import Foundation

/// Identifier of a node inside one `TilingTree`. Values are unique per tree.
public struct NodeID: Hashable, Sendable, Codable {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
}

/// One node of the split tree.
///
/// A leaf holds one window. A container holds an ordered list of children
/// along one orientation. Each child has a weight; the container divides its
/// rectangle in proportion to the weights. Weights are positive.
public enum LayoutNode: Equatable, Sendable {
    case window(WindowID)
    case container(Container)
}

/// Split container. `children` and `weights` have the same count.
/// `mru` lists child indices, most recently focused first. The engine
/// descends into the first entry of `mru` when focus enters this container
/// from a sibling.
public struct Container: Equatable, Sendable {
    public var orientation: Orientation
    public var children: [NodeID]
    public var weights: [Double]
    public var mru: [Int]

    public init(orientation: Orientation, children: [NodeID] = [], weights: [Double] = [], mru: [Int] = []) {
        self.orientation = orientation
        self.children = children
        self.weights = weights
        self.mru = mru
    }
}

/// Tiling tree for one `SpaceKey`. It follows i3 rules.
///
/// Rules:
/// - The root is a container. It never collapses. `init(root:)` sets its orientation.
/// - Insert: the new leaf goes right after the focused leaf, in the same
///   container. It takes half the weight of the focused leaf. With no focused
///   leaf, the new leaf goes at the end of the root.
/// - Remove: the leaf leaves its container. Its weight goes to the previous
///   sibling (the next sibling for the first child). So remove undoes insert.
///   A non-root container with one child collapses: the child takes the
///   container slot and weight. When the child is a container with the
///   orientation of the grandparent, its children join the grandparent
///   (i3 flatten). A root with one wrapper of one leaf takes the wrapper
///   orientation and holds the leaf.
/// - Reconcile: one new window follows the insert rule. Two or more new
///   windows in one call get the mean weight of their container. The result
///   is equal sizes, not a halving cascade.
/// - Focus(d): climb to the nearest ancestor whose orientation equals
///   `d.orientation` and that has a sibling on side `d`. Descend into that
///   sibling by `mru`. No match returns nil (the app then tries the next display).
///   Focus never wraps.
/// - Move(d): same climb. At the leaf parent, a sibling leaf swaps places
///   and a sibling container receives the leaf. A container with orientation
///   `d.orientation` takes the leaf at its near edge. A container with the
///   other orientation takes the leaf after its most recent child (i3).
///   At a higher ancestor, the leaf goes next to its old branch, on side `d`.
///   A move that changes nothing does not count. When no ancestor matches,
///   the root takes orientation `d.orientation`, the old root children go
///   into a new container, and the leaf goes on side `d`. At the root edge
///   the move fails and returns false (the app then tries the next display).
/// - toggleSplit: flips the orientation of the parent of the focused leaf.
/// - split(o): wraps the focused leaf in a new container with orientation `o`.
///   The new container takes the leaf's slot and weight.
/// - toggleZoom: marks the focused leaf as zoomed. A zoomed leaf takes the
///   whole work area minus outer gaps. Other leaves keep their frames but
///   stay below it. Any focus or move command clears zoom.
/// - balance: every container gets equal weights.
/// - resize(delta): adds `delta` (fraction of the parent) to the focused leaf
///   weight and removes it from the next sibling. Weights stay >= 0.05.
/// - layout: splits rectangles by weights. Inner gap lies between siblings.
///   Outer gap lies between the root and the work area. Frames are rounded
///   to whole points.
public struct TilingTree: Equatable, Sendable {
    public private(set) var nodes: [NodeID: LayoutNode]
    public private(set) var parents: [NodeID: NodeID]
    public private(set) var root: NodeID
    public private(set) var focused: WindowID?
    public private(set) var zoomed: WindowID?
    private var nextID: Int

    /// Creates an empty tree with one root container.
    public init(root orientation: Orientation) {
        let rootID = NodeID(0)
        self.root = rootID
        self.nodes = [rootID: .container(Container(orientation: orientation))]
        self.parents = [:]
        self.focused = nil
        self.zoomed = nil
        self.nextID = 1
    }

    /// All windows, in tree order (depth-first, left to right).
    public var windows: [WindowID] {
        var out: [WindowID] = []
        collectWindows(root, into: &out)
        return out
    }

    /// True when the tree holds no window.
    public var isEmpty: Bool { windows.isEmpty }

    /// Returns true when `w` is in the tree.
    public func contains(_ w: WindowID) -> Bool {
        leafID(of: w) != nil
    }

    /// Inserts `w` after the focused leaf. See type rules. Does nothing when
    /// `w` is already present. The new window becomes focused.
    public mutating func insert(_ w: WindowID) {
        insert(w, equalWeight: false)
    }

    /// Inserts `w` after the focused leaf, like `insert(_:)`. With
    /// `equalWeight` true, the new leaf gets the mean weight of its container
    /// and no weight changes on the focused leaf. Use it for windows that
    /// arrive together.
    public mutating func insert(_ w: WindowID, equalWeight: Bool) {
        guard !contains(w) else { return }
        let id = makeID()
        nodes[id] = .window(w)
        if let f = focused, let leaf = leafID(of: f), let p = parents[leaf],
           let c = container(p), let i = c.children.firstIndex(of: leaf) {
            if equalWeight {
                attach(id, to: p, at: i + 1, weight: Self.equalShare(c.weights))
            } else {
                let half = c.weights[i] / 2
                modifyContainer(p) { $0.weights[i] = half }
                attach(id, to: p, at: i + 1, weight: half)
            }
        } else {
            let c = container(root) ?? Container(orientation: .horizontal)
            attach(id, to: root, at: c.children.count, weight: Self.equalShare(c.weights))
        }
        setFocus(w)
    }

    /// Removes `w` and collapses its parent when needed. Does nothing when
    /// `w` is absent. When `w` was focused, focus moves to the mru sibling.
    public mutating func remove(_ w: WindowID) {
        guard let leaf = leafID(of: w) else { return }
        let wasFocused = focused == w
        let next = wasFocused ? focusCandidate(replacing: leaf) : nil
        if zoomed == w { zoomed = nil }
        giveWeightToSibling(of: leaf)
        guard let info = detach(leaf) else { return }
        nodes[leaf] = nil
        normalize(info.parent)
        collapseRootWrapper()
        if wasFocused {
            focused = nil
            if let next { setFocus(next) }
        }
    }

    /// Makes the tree match `present`: removes missing windows, inserts new
    /// windows (in list order, each after the focused leaf). Keeps the order
    /// of windows that stay.
    ///
    /// One new window follows the insert rule (half the weight of the focused
    /// leaf). Two or more new windows get the mean weight of their container,
    /// so they do not shrink each other.
    public mutating func reconcile(present: [WindowID]) {
        let keep = Set(present)
        for w in windows where !keep.contains(w) {
            remove(w)
        }
        var seen = Set<WindowID>()
        let added = present.filter { !contains($0) && seen.insert($0).inserted }
        let together = added.count > 1
        for w in added {
            insert(w, equalWeight: together)
        }
    }

    /// Sets focus and updates `mru` on every ancestor. Clears zoom when the
    /// focused window changes. Does nothing when `w` is absent.
    public mutating func setFocus(_ w: WindowID) {
        guard let leaf = leafID(of: w) else { return }
        if focused != w { zoomed = nil }
        focused = w
        var child = leaf
        while let p = parents[child] {
            modifyContainer(p) { c in
                guard let i = c.children.firstIndex(of: child) else { return }
                c.mru.removeAll { $0 == i }
                c.mru.insert(i, at: 0)
            }
            child = p
        }
    }

    /// Returns the window that focus(d) selects from the focused leaf, or nil.
    public func neighbor(_ d: Direction) -> WindowID? {
        guard let f = focused, var child = leafID(of: f) else { return nil }
        while let p = parents[child], let c = container(p) {
            if c.orientation == d.orientation, let i = c.children.firstIndex(of: child) {
                let j = d.isForward ? i + 1 : i - 1
                if c.children.indices.contains(j) {
                    return descend(c.children[j], forward: d.isForward)
                }
            }
            child = p
        }
        return nil
    }

    /// Moves the focused leaf in direction `d`. Returns false when the leaf
    /// sits at the root edge in that direction.
    ///
    /// The engine climbs from the leaf to the nearest ancestor whose
    /// orientation equals `d.orientation`:
    /// - At the leaf parent, a sibling leaf on side `d` swaps places with the
    ///   leaf. A sibling container on side `d` receives the leaf: at its near
    ///   edge when it has orientation `d.orientation`, else after its most
    ///   recent child.
    /// - At a higher ancestor, the leaf goes next to the child that held it,
    ///   on side `d`. A move that changes nothing is skipped.
    /// - With no match, the root takes orientation `d.orientation`. The old
    ///   root children go into a new container. The leaf goes on side `d`.
    ///   When the root has one child, the root only flips.
    /// The leaf stays focused. Zoom clears.
    @discardableResult
    public mutating func moveFocused(_ d: Direction) -> Bool {
        guard let f = focused, let leaf = leafID(of: f) else { return false }
        zoomed = nil
        var child = leaf
        while let p = parents[child], let c = container(p) {
            if c.orientation == d.orientation, let i = c.children.firstIndex(of: child) {
                if child == leaf {
                    let j = d.isForward ? i + 1 : i - 1
                    if c.children.indices.contains(j) {
                        let sibling = c.children[j]
                        if let sc = container(sibling) {
                            let at: Int
                            if sc.orientation == d.orientation {
                                at = d.isForward ? 0 : sc.children.count
                            } else {
                                // A near edge means nothing on the other axis.
                                // Enter after the most recent child (i3).
                                at = min((sc.mru.first ?? 0) + 1, sc.children.count)
                            }
                            _ = detach(leaf)
                            attach(leaf, to: sibling, at: at, weight: Self.equalShare(sc.weights))
                            normalize(p)
                        } else {
                            swapChildren(in: p, i, j)
                        }
                        setFocus(f)
                        return true
                    }
                } else if !(c.children.count == 1 && holdsOnly(leaf, below: child)) {
                    guard let old = detach(leaf) else { return false }
                    guard let k = container(p)?.children.firstIndex(of: child) else { return false }
                    let pc = container(p) ?? c
                    attach(leaf, to: p, at: d.isForward ? k + 1 : k, weight: Self.equalShare(pc.weights))
                    normalize(old.parent)
                    setFocus(f)
                    return true
                }
                // Else the move changes nothing. Keep climbing.
            }
            child = p
        }
        return moveAtRoot(leaf: leaf, window: f, d)
    }

    /// Flips the orientation of the parent of the focused leaf.
    public mutating func toggleSplit() {
        guard let f = focused, let leaf = leafID(of: f), let p = parents[leaf] else { return }
        modifyContainer(p) { $0.orientation = $0.orientation.flipped }
    }

    /// Wraps the focused leaf in a new container with orientation `o`.
    ///
    /// When the leaf is the only child of its parent, the parent only takes
    /// orientation `o`. This prevents chains of one-child containers.
    public mutating func split(_ o: Orientation) {
        guard let f = focused, let leaf = leafID(of: f), let p = parents[leaf],
              let c = container(p), let i = c.children.firstIndex(of: leaf) else { return }
        if c.children.count == 1 {
            modifyContainer(p) { $0.orientation = o }
            return
        }
        let wrapper = makeID()
        nodes[wrapper] = .container(Container(orientation: o, children: [leaf], weights: [1], mru: [0]))
        modifyContainer(p) { $0.children[i] = wrapper }
        parents[wrapper] = p
        parents[leaf] = wrapper
    }

    /// Toggles zoom of the focused leaf.
    public mutating func toggleZoom() {
        if zoomed != nil && zoomed == focused {
            zoomed = nil
        } else {
            zoomed = focused
        }
    }

    /// Sets equal weights in every container.
    public mutating func balance() {
        for (id, node) in nodes {
            guard case .container(var c) = node else { continue }
            c.weights = Array(repeating: 1, count: c.children.count)
            nodes[id] = .container(c)
        }
    }

    /// Changes the weight of the focused leaf by `delta`. See type rules.
    ///
    /// The weights of the parent are normalized to a sum of 1 first. The next
    /// sibling gives or takes the change. When the leaf is the last child, the
    /// previous sibling does. The change stops at the minimum weight.
    public mutating func resize(delta: Double) {
        guard let f = focused, let leaf = leafID(of: f), let p = parents[leaf],
              let c = container(p), c.children.count >= 2,
              let i = c.children.firstIndex(of: leaf) else { return }
        let j = i + 1 < c.children.count ? i + 1 : i - 1
        let total = c.weights.reduce(0, +)
        var ws = total > 0
            ? c.weights.map { $0 / total }
            : Array(repeating: 1 / Double(c.children.count), count: c.children.count)
        var change = delta
        if change > 0 {
            change = max(0, min(change, ws[j] - Self.minWeight))
        } else {
            change = min(0, max(change, Self.minWeight - ws[i]))
        }
        ws[i] += change
        ws[j] -= change
        modifyContainer(p) { $0.weights = ws }
    }

    /// Computes a frame for every window inside `area`.
    /// `area` is the display work area in AX coordinates.
    public func layout(in area: Rect, gaps: Gaps) -> [WindowID: Rect] {
        let work = area.inset(by: gaps.outer)
        var out: [WindowID: Rect] = [:]
        place(root, in: work, inner: gaps.inner, into: &out)
        if let z = zoomed, out[z] != nil {
            out[z] = work
        }
        return out.mapValues(Self.rounded)
    }
}

// MARK: - Internal helpers

extension TilingTree {
    /// Smallest normalized weight that `resize` leaves on a child.
    static let minWeight = 0.05

    /// Returns the mean of `weights`, or 1 when `weights` is empty.
    static func equalShare(_ weights: [Double]) -> Double {
        weights.isEmpty ? 1 : weights.reduce(0, +) / Double(weights.count)
    }

    /// Rounds each edge to a whole point. Adjacent frames keep a shared edge.
    static func rounded(_ r: Rect) -> Rect {
        let x0 = r.minX.rounded(), y0 = r.minY.rounded()
        let x1 = r.maxX.rounded(), y1 = r.maxY.rounded()
        return Rect(x: x0, y: y0, w: max(0, x1 - x0), h: max(0, y1 - y0))
    }

    /// Returns the node of the leaf that holds `w`, or nil.
    func leafID(of w: WindowID) -> NodeID? {
        nodes.first { $0.value == .window(w) }?.key
    }

    /// Returns the container stored at `id`, or nil for a leaf or a missing node.
    func container(_ id: NodeID) -> Container? {
        if case .container(let c)? = nodes[id] { return c }
        return nil
    }

    /// Returns the parent container of the leaf that holds `w`, or nil.
    func parentContainer(of w: WindowID) -> Container? {
        leafID(of: w).flatMap { parents[$0] }.flatMap { container($0) }
    }

    /// Returns the weight of the leaf that holds `w` inside its parent, or nil.
    func weight(of w: WindowID) -> Double? {
        guard let leaf = leafID(of: w), let p = parents[leaf], let c = container(p),
              let i = c.children.firstIndex(of: leaf) else { return nil }
        return c.weights[i]
    }

    private func collectWindows(_ id: NodeID, into out: inout [WindowID]) {
        switch nodes[id] {
        case .window(let w)?:
            out.append(w)
        case .container(let c)?:
            for child in c.children { collectWindows(child, into: &out) }
        case nil:
            break
        }
    }

    private mutating func makeID() -> NodeID {
        let id = NodeID(nextID)
        nextID += 1
        return id
    }

    private mutating func modifyContainer(_ id: NodeID, _ body: (inout Container) -> Void) {
        guard case .container(var c)? = nodes[id] else { return }
        body(&c)
        nodes[id] = .container(c)
    }

    /// Adds `child` to `parent` at `index` with `weight`. The new child goes
    /// last in `mru`.
    private mutating func attach(_ child: NodeID, to parent: NodeID, at index: Int, weight: Double) {
        modifyContainer(parent) { c in
            let i = min(max(0, index), c.children.count)
            c.children.insert(child, at: i)
            c.weights.insert(weight, at: i)
            c.mru = c.mru.map { $0 >= i ? $0 + 1 : $0 }
            c.mru.append(i)
        }
        parents[child] = parent
    }

    /// Takes `child` out of its parent. The node stays in `nodes`. The parent
    /// does not collapse; call `normalize` for that.
    private mutating func detach(_ child: NodeID) -> (parent: NodeID, index: Int, weight: Double)? {
        guard let p = parents[child], var c = container(p),
              let i = c.children.firstIndex(of: child) else { return nil }
        let weight = c.weights[i]
        c.children.remove(at: i)
        c.weights.remove(at: i)
        c.mru = c.mru.filter { $0 != i }.map { $0 > i ? $0 - 1 : $0 }
        nodes[p] = .container(c)
        parents[child] = nil
        return (p, i, weight)
    }

    /// Applies the collapse rules to container `id` after it lost a child.
    /// An empty non-root container disappears. A non-root container with one
    /// child gives its slot and weight to that child. When that child is a
    /// container with the orientation of the grandparent, its children join
    /// the grandparent (i3 flatten).
    private mutating func normalize(_ id: NodeID) {
        guard id != root, let c = container(id), let gp = parents[id] else { return }
        if c.children.isEmpty {
            _ = detach(id)
            nodes[id] = nil
            normalize(gp)
        } else if c.children.count == 1 {
            let only = c.children[0]
            guard let gc = container(gp), let gi = gc.children.firstIndex(of: id) else { return }
            modifyContainer(gp) { $0.children[gi] = only }
            parents[only] = gp
            parents[id] = nil
            nodes[id] = nil
            if let oc = container(only), oc.orientation == gc.orientation {
                splice(only, in: gp)
            }
        }
    }

    /// Replaces container `id` by its children inside `parent`. The children
    /// share the slot weight of `id`. The `mru` order of both containers stays.
    private mutating func splice(_ id: NodeID, in parent: NodeID) {
        guard let inner = container(id), let pc = container(parent),
              let gi = pc.children.firstIndex(of: id), !inner.children.isEmpty else { return }
        let k = inner.children.count
        let slot = pc.weights[gi]
        let total = inner.weights.reduce(0, +)
        let shares = total > 0
            ? inner.weights.map { $0 * slot / total }
            : Array(repeating: slot / Double(k), count: k)
        modifyContainer(parent) { c in
            c.children.replaceSubrange(gi...gi, with: inner.children)
            c.weights.replaceSubrange(gi...gi, with: shares)
            var ranks: [Int] = []
            for m in c.mru {
                if m == gi {
                    ranks.append(contentsOf: inner.mru.map { $0 + gi })
                } else if m > gi {
                    ranks.append(m + k - 1)
                } else {
                    ranks.append(m)
                }
            }
            c.mru = ranks
        }
        for child in inner.children { parents[child] = parent }
        parents[id] = nil
        nodes[id] = nil
    }

    /// Adds the weight of `child` to its previous sibling, or to its next
    /// sibling when `child` comes first. This undoes the weight split of
    /// `insert`. Call it before `detach`.
    private mutating func giveWeightToSibling(of child: NodeID) {
        guard let p = parents[child], let c = container(p), c.children.count >= 2,
              let i = c.children.firstIndex(of: child) else { return }
        let j = i > 0 ? i - 1 : i + 1
        modifyContainer(p) { $0.weights[j] += $0.weights[i] }
    }

    /// A root with one child, where that child is a container with one leaf,
    /// has no use. The root takes the orientation of the wrapper and holds the
    /// leaf. This keeps `moveFocused` from reporting a move that does nothing.
    private mutating func collapseRootWrapper() {
        while let rc = container(root), rc.children.count == 1,
              let inner = container(rc.children[0]), inner.children.count == 1 {
            let wrapper = rc.children[0]
            let only = inner.children[0]
            modifyContainer(root) { c in
                c.children[0] = only
                c.orientation = inner.orientation
            }
            parents[only] = root
            parents[wrapper] = nil
            nodes[wrapper] = nil
        }
    }

    /// True when the subtree at `id` holds only the leaf `leaf`, through a
    /// chain of containers with one child each.
    private func holdsOnly(_ leaf: NodeID, below id: NodeID) -> Bool {
        var current = id
        while current != leaf {
            guard let c = container(current), c.children.count == 1 else { return false }
            current = c.children[0]
        }
        return true
    }

    /// Swaps two children of `parent`. Weights and `mru` ranks move with the nodes.
    private mutating func swapChildren(in parent: NodeID, _ i: Int, _ j: Int) {
        modifyContainer(parent) { c in
            c.children.swapAt(i, j)
            c.weights.swapAt(i, j)
            c.mru = c.mru.map { $0 == i ? j : ($0 == j ? i : $0) }
        }
    }

    /// Returns the leaf window inside `id` that `mru` selects. An empty
    /// `mru` selects the near edge for direction `forward`.
    private func descend(_ id: NodeID, forward: Bool) -> WindowID? {
        var current = id
        while true {
            switch nodes[current] {
            case .window(let w)?:
                return w
            case .container(let c)?:
                guard !c.children.isEmpty else { return nil }
                let j = c.mru.first ?? (forward ? 0 : c.children.count - 1)
                current = c.children[j]
            case nil:
                return nil
            }
        }
    }

    /// Returns the window that gets focus when `leaf` disappears: the most
    /// recent sibling, else the most recent node of the nearest ancestor.
    private func focusCandidate(replacing leaf: NodeID) -> WindowID? {
        var child = leaf
        while let p = parents[child], let c = container(p) {
            let i = c.children.firstIndex(of: child)
            if let j = c.mru.first(where: { $0 != i }) {
                return descend(c.children[j], forward: true)
            }
            child = p
        }
        return nil
    }

    /// Handles `moveFocused` when no ancestor matches. See `moveFocused`.
    private mutating func moveAtRoot(leaf: NodeID, window w: WindowID, _ d: Direction) -> Bool {
        // A chain of one-child containers acts as the root for this check.
        var top = root
        while let c = container(top), c.children.count == 1 {
            top = c.children[0]
        }
        guard let topC = container(top), topC.orientation != d.orientation else { return false }
        guard let old = detach(leaf) else { return false }
        normalize(old.parent)
        guard let rc = container(root) else { return false }
        if rc.children.count >= 2 {
            let wrapper = makeID()
            nodes[wrapper] = .container(rc)
            for child in rc.children { parents[child] = wrapper }
            nodes[root] = .container(Container(orientation: d.orientation))
            attach(wrapper, to: root, at: 0, weight: 1)
        } else {
            modifyContainer(root) { $0.orientation = d.orientation }
            // The one child can be a container with the new root orientation.
            // Splice it, so the root does not hold a same-orientation child.
            if let only = container(root)?.children.first, let oc = container(only),
               oc.orientation == d.orientation {
                splice(only, in: root)
            }
        }
        let now = container(root) ?? rc
        attach(leaf, to: root, at: d.isForward ? now.children.count : 0, weight: Self.equalShare(now.weights))
        setFocus(w)
        return true
    }

    /// Places the subtree `id` inside `rect`. Children of a container share
    /// the length along its orientation by weight, minus `inner` between them.
    private func place(_ id: NodeID, in rect: Rect, inner: Double, into out: inout [WindowID: Rect]) {
        switch nodes[id] {
        case .window(let w)?:
            out[w] = rect
        case .container(let c)?:
            let n = c.children.count
            guard n > 0 else { return }
            let horizontal = c.orientation == .horizontal
            let length = horizontal ? rect.w : rect.h
            let free = max(0, length - inner * Double(n - 1))
            let positive = c.weights.map { max(0, $0) }
            let total = positive.reduce(0, +)
            let shares = total > 0 ? positive.map { $0 / total } : Array(repeating: 1 / Double(n), count: n)
            var cursor = horizontal ? rect.x : rect.y
            for (k, child) in c.children.enumerated() {
                let size = free * shares[k]
                let r = horizontal
                    ? Rect(x: cursor, y: rect.y, w: size, h: rect.h)
                    : Rect(x: rect.x, y: cursor, w: rect.w, h: size)
                place(child, in: r, inner: inner, into: &out)
                cursor += size + inner
            }
        case nil:
            break
        }
    }
}
