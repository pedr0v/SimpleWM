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
/// - Remove: the leaf leaves its container. A non-root container with one
///   child collapses: the child takes the container slot and weight. No other
///   auto-flatten happens.
/// - Focus(d): climb to the nearest ancestor whose orientation equals
///   `d.orientation` and that has a sibling on side `d`. Descend into that
///   sibling by `mru`. No match returns nil (the app then tries the next display).
///   Focus never wraps.
/// - Move(d): same climb. A sibling leaf swaps places. A sibling container
///   receives the leaf at its near edge. When no ancestor matches, the root
///   flips orientation when it has only one child; else the leaf moves out
///   of its parent into the grandparent, next to its old parent. At the root
///   edge the move fails and returns false (the app then tries the next display).
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
        fatalError("TODO")
    }

    /// True when the tree holds no window.
    public var isEmpty: Bool { windows.isEmpty }

    /// Returns true when `w` is in the tree.
    public func contains(_ w: WindowID) -> Bool {
        windows.contains(w)
    }

    /// Inserts `w` after the focused leaf. See type rules. Does nothing when
    /// `w` is already present. The new window becomes focused.
    public mutating func insert(_ w: WindowID) {
        fatalError("TODO")
    }

    /// Removes `w` and collapses its parent when needed. Does nothing when
    /// `w` is absent. When `w` was focused, focus moves to the mru sibling.
    public mutating func remove(_ w: WindowID) {
        fatalError("TODO")
    }

    /// Makes the tree match `present`: removes missing windows, inserts new
    /// windows (in list order, each after the focused leaf). Keeps the order
    /// of windows that stay.
    public mutating func reconcile(present: [WindowID]) {
        fatalError("TODO")
    }

    /// Sets focus and updates `mru` on every ancestor. Clears zoom when the
    /// focused window changes. Does nothing when `w` is absent.
    public mutating func setFocus(_ w: WindowID) {
        fatalError("TODO")
    }

    /// Returns the window that focus(d) selects from the focused leaf, or nil.
    public func neighbor(_ d: Direction) -> WindowID? {
        fatalError("TODO")
    }

    /// Moves the focused leaf in direction `d`. Returns false when the leaf
    /// sits at the root edge in that direction.
    @discardableResult
    public mutating func moveFocused(_ d: Direction) -> Bool {
        fatalError("TODO")
    }

    /// Flips the orientation of the parent of the focused leaf.
    public mutating func toggleSplit() {
        fatalError("TODO")
    }

    /// Wraps the focused leaf in a new container with orientation `o`.
    public mutating func split(_ o: Orientation) {
        fatalError("TODO")
    }

    /// Toggles zoom of the focused leaf.
    public mutating func toggleZoom() {
        fatalError("TODO")
    }

    /// Sets equal weights in every container.
    public mutating func balance() {
        fatalError("TODO")
    }

    /// Changes the weight of the focused leaf by `delta`. See type rules.
    public mutating func resize(delta: Double) {
        fatalError("TODO")
    }

    /// Computes a frame for every window inside `area`.
    /// `area` is the display work area in AX coordinates.
    public func layout(in area: Rect, gaps: Gaps) -> [WindowID: Rect] {
        fatalError("TODO")
    }
}
