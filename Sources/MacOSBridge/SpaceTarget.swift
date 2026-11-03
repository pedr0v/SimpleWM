import LayoutEngine

/// Target of `space N` and `move-to-space N` on one display.
public enum SpaceTarget: Equatable, Sendable {
    /// Space N exists. `index` is N - 1, an index into `Spaces[]`.
    case existing(index: Int)
    /// Space N does not exist. The command goes to the spare desktop at the
    /// end of the display. `SpaceTargetRules.spare(spaces:isEmpty:maxCount:)`
    /// picks it.
    case spare
    /// Space N does not exist and the command does nothing.
    case unavailable(SpaceTargetRefusal)
}

/// Reason for `SpaceTarget.unavailable`.
public enum SpaceTargetRefusal: Equatable, Sendable {
    /// N is less than 1.
    case invalidNumber
    /// `createMissingSpaces` is false.
    case creationOff
    /// N is greater than the cap (`SpaceManager.maxSpaceCount`).
    case aboveCap
}

/// How the display gets its spare desktop.
public enum SpareChoice: Equatable, Sendable {
    /// The last Space is an empty desktop. Use it. `index` is its index in `Spaces[]`.
    case reuse(index: Int)
    /// Append one new desktop at the end.
    case create
    /// The display has `maxCount` Spaces and the last one is not an empty desktop.
    case full
}

/// Pure rules for `space N`, `move-to-space N`, and the empty-Space cleanup.
///
/// The rules never create more than one Space for one command, and they
/// keep at most one empty spare desktop at the end of a display:
/// - When Space N exists, the command uses it.
/// - When Space N does not exist, the command uses the last Space if it is
///   an empty desktop. Else it appends one new desktop. N does not set the
///   count of new Spaces: `space 9` on a display with 3 Spaces gives 4 Spaces.
public enum SpaceTargetRules {
    /// Target of `space N` or `move-to-space N` on a display with `count`
    /// Spaces (fullscreen Spaces included).
    public static func target(n: Int, count: Int, createAllowed: Bool, maxCount: Int) -> SpaceTarget {
        guard n >= 1 else { return .unavailable(.invalidNumber) }
        if n <= count { return .existing(index: n - 1) }
        guard createAllowed else { return .unavailable(.creationOff) }
        guard n <= maxCount else { return .unavailable(.aboveCap) }
        return .spare
    }

    /// Spare desktop of a display with `spaces` (in `Spaces[]` order).
    ///
    /// The last Space is the spare when it is a desktop (type 0) and
    /// `isEmpty` is true for it. The current Space can be the spare. Else
    /// the display needs one new desktop, unless it has `maxCount` Spaces.
    public static func spare(spaces: [SpaceInfo], isEmpty: (SpaceID) -> Bool, maxCount: Int) -> SpareChoice {
        if let last = spaces.last, last.isUser, isEmpty(last.id) {
            return .reuse(index: spaces.count - 1)
        }
        return spaces.count < maxCount ? .create : .full
    }

    /// Empty desktops that the cleanup may remove from a display.
    ///
    /// Rules:
    /// - The first Space of the display stays.
    /// - The current Space stays.
    /// - A non-user Space (fullscreen app) stays.
    /// - The last Space of the display stays, so one spare desktop remains.
    /// - A Space with a window stays (`isEmpty` is false).
    public static func removableEmptySpaces(spaces: [SpaceInfo], current: SpaceID,
                                            isEmpty: (SpaceID) -> Bool) -> [SpaceInfo] {
        guard spaces.count > 2 else { return [] }
        return spaces.enumerated().compactMap { i, s in
            guard i > 0, i < spaces.count - 1, s.isUser, s.id != current, isEmpty(s.id) else { return nil }
            return s
        }
    }
}

/// Order of Space switch requests.
///
/// A request takes a ticket when the user presses the key. It does not take
/// the ticket after a slow step such as the creation of a desktop. A newer
/// ticket replaces every older ticket. So the last key press wins, and an
/// older request that ends later cannot switch the display.
public struct SwitchTickets: Equatable, Sendable {
    /// Newest ticket. Zero means that no request took a ticket.
    public private(set) var latest = 0

    public init() {}

    /// Gives a new ticket. It replaces all older tickets.
    public mutating func issue() -> Int {
        latest += 1
        return latest
    }

    /// True when no newer request took a ticket after `ticket`.
    public func isLatest(_ ticket: Int) -> Bool {
        ticket == latest
    }
}
