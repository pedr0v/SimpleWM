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

    /// Moves `w` into the tree of `to`. The window becomes focused there.
    ///
    /// The function removes `w` from every tree that holds it. `from` is a
    /// hint: a refresh can drop `w` from `from` before the move ends, and the
    /// window must still reach `to`. Does nothing when `from == to`.
    public mutating func transfer(_ w: WindowID, from: SpaceKey, to: SpaceKey) {
        guard from != to else { return }
        for (key, var tree) in trees where key != to && tree.contains(w) {
            tree.remove(w)
            trees[key] = tree
        }
        update(to) { tree in
            tree.insert(w)
            tree.setFocus(w)
        }
    }

    /// Drops trees whose key is not in `live`.
    public mutating func prune(live: Set<SpaceKey>) {
        trees = trees.filter { live.contains($0.key) }
    }

    /// Drops trees whose Space is not in `liveSpaces`. A Space keeps its tree
    /// when the Space moves to another display, because Space IDs are global.
    /// Call `rekey(owners:)` first.
    public mutating func prune(liveSpaces: Set<SpaceID>) {
        trees = trees.filter { liveSpaces.contains($0.key.space) }
    }

    /// Moves each tree to the display that now holds its Space.
    ///
    /// `owners` maps a Space ID to the displays that list it (one display, or
    /// every screen with shared Spaces). A tree stays when its display is in
    /// the list. Otherwise the tree moves to the first listed display, sorted
    /// by UUID. An existing non-empty tree under the new key wins.
    /// Trees of Spaces missing from `owners` stay (see `prune(liveSpaces:)`).
    public mutating func rekey(owners: [SpaceID: Set<DisplayID>]) {
        for (key, tree) in trees {
            guard let displays = owners[key.space], !displays.isEmpty,
                  !displays.contains(key.display),
                  let target = displays.min(by: { $0.uuid < $1.uuid }) else { continue }
            let next = SpaceKey(display: target, space: key.space)
            if let existing = trees[next], !existing.isEmpty {
                trees[key] = nil
                continue
            }
            trees[next] = tree
            trees[key] = nil
        }
    }
}
