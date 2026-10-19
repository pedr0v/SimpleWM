import Foundation

/// All tiling trees, one per native Space on each display.
///
/// Trees survive while a Space is hidden. The app calls `prune` after it
/// reads the Space list, so trees of deleted Spaces disappear.
public struct WMState: Equatable, Sendable {
    public var trees: [SpaceKey: TilingTree]
    public var rootOrientation: Orientation

    public init(rootOrientation: Orientation = .horizontal) {
        self.trees = [:]
        self.rootOrientation = rootOrientation
    }

    /// Returns the tree for `key`, or an empty tree when none exists.
    public func tree(for key: SpaceKey) -> TilingTree {
        trees[key] ?? TilingTree(root: rootOrientation)
    }

    /// Mutates the tree for `key`. Creates it when needed.
    public mutating func update(_ key: SpaceKey, _ body: (inout TilingTree) -> Void) {
        var t = tree(for: key)
        body(&t)
        trees[key] = t
    }

    /// Returns the key of the tree that holds `w`, or nil.
    public func key(of w: WindowID) -> SpaceKey? {
        trees.first { $0.value.contains(w) }?.key
    }

    /// Moves `w` from one tree to another. The window becomes focused in the
    /// destination. Does nothing when `w` is absent from `from`.
    public mutating func transfer(_ w: WindowID, from: SpaceKey, to: SpaceKey) {
        guard from != to, var source = trees[from], source.contains(w) else { return }
        source.remove(w)
        trees[from] = source
        update(to) { tree in
            tree.insert(w)
            tree.setFocus(w)
        }
    }

    /// Drops trees whose key is not in `live`.
    public mutating func prune(live: Set<SpaceKey>) {
        trees = trees.filter { live.contains($0.key) }
    }
}
