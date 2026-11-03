import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LayoutEngine
import os

/// Process that holds the Mission Control Accessibility tree.
///
/// The host changed in macOS 27. The app probes both hosts and does not
/// read the OS version.
public enum MissionControlHost: String, CaseIterable, Sendable {
    /// `com.apple.WindowManager`: macOS 27 and later.
    case windowManager = "com.apple.WindowManager"
    /// `com.apple.dock`: macOS 26 and earlier.
    case dock = "com.apple.dock"

    var bundleID: String { rawValue }
}

/// A node of an Accessibility tree.
///
/// The matching rules in `MissionControlTree` use this protocol. Tests give
/// fake trees. The app gives `LiveAXNode`.
protocol AXTreeNode {
    var identifier: String? { get }
    var children: [Self] { get }
    /// `AXDisplayID` of a `mc.display` group, or nil.
    var displayID: UInt32? { get }
    var actionNames: [String] { get }
}

/// Matching rules for the Mission Control Accessibility tree.
///
/// Two layouts exist:
/// - Dock (macOS 26 and earlier): application, then group `mc`, then one
///   group `mc.display` for each display.
/// - WindowManager (macOS 27): application, then one group `mc.display`
///   for each display. The group `mc` does not exist.
///
/// Both layouts have the same content below a `mc.display` group:
/// - The attribute `AXDisplayID` holds the `CGDirectDisplayID`.
/// - The group `mc.spaces` holds the list `mc.spaces.list` and the button
///   `mc.spaces.add` ("Add Desktop").
/// - Each child of the list is one Space thumbnail, in `Spaces[]` order.
///   A thumbnail has the action `AXRemoveDesktop` when Mission Control
///   allows its removal.
///
/// Every rule matches identifiers. Descriptions and titles depend on the
/// language.
enum MissionControlTree {
    static let groupID = "mc"
    static let displayGroupID = "mc.display"
    static let spacesListID = "mc.spaces.list"
    static let addButtonID = "mc.spaces.add"
    static let removeAction = "AXRemoveDesktop"
    /// Search depth below a `mc.display` group.
    static let searchDepth = 4

    /// Root of the open Mission Control tree in one host application, or nil.
    ///
    /// The root is the group `mc` (Dock layout), or the application itself
    /// when it has a `mc.display` child (WindowManager layout). The
    /// `mc.display` groups are children of the root in both layouts.
    static func root<N: AXTreeNode>(inApplication app: N) -> N? {
        let children = app.children
        if let group = children.first(where: { $0.identifier == groupID }) { return group }
        if children.contains(where: { $0.identifier == displayGroupID }) { return app }
        return nil
    }

    /// The `mc.display` groups for `cgID`.
    ///
    /// With shared Spaces ("Displays have separate Spaces" off), a display
    /// can lack its own group. Then every display group is a candidate.
    static func displayGroups<N: AXTreeNode>(in root: N, cgID: UInt32, sharedSpaces: Bool) -> [N] {
        let displays = root.children.filter { $0.identifier == displayGroupID }
        let exact = displays.filter { $0.displayID == cgID }
        return exact.isEmpty && sharedSpaces ? displays : exact
    }

    /// Breadth-first search for the first descendant with `identifier`.
    /// The search goes at most `maxDepth` levels down.
    static func find<N: AXTreeNode>(identifier: String, in root: N, maxDepth: Int) -> N? {
        var level = root.children
        var depth = 1
        while !level.isEmpty, depth <= maxDepth {
            if let hit = level.first(where: { $0.identifier == identifier }) { return hit }
            level = level.flatMap(\.children)
            depth += 1
        }
        return nil
    }

    /// Button `mc.spaces.add` of the display `cgID`, or nil.
    static func addButton<N: AXTreeNode>(in root: N, cgID: UInt32, sharedSpaces: Bool) -> N? {
        for display in displayGroups(in: root, cgID: cgID, sharedSpaces: sharedSpaces) {
            if let button = find(identifier: addButtonID, in: display, maxDepth: searchDepth) {
                return button
            }
        }
        return nil
    }

    /// List `mc.spaces.list` of the display `cgID`, or nil.
    static func spacesList<N: AXTreeNode>(in root: N, cgID: UInt32, sharedSpaces: Bool) -> N? {
        for display in displayGroups(in: root, cgID: cgID, sharedSpaces: sharedSpaces) {
            if let list = find(identifier: spacesListID, in: display, maxDepth: searchDepth) {
                return list
            }
        }
        return nil
    }

    /// Result of `thumbnail(in:index:spaceCount:)`.
    enum ThumbnailLookup<N> {
        case found(N)
        /// The list and SkyLight do not agree on the count of Spaces. An
        /// index is then not safe.
        case countMismatch(listCount: Int)
        /// The thumbnail has no `AXRemoveDesktop` action.
        case noRemoveAction(N)
    }

    /// Thumbnail of the Space at `index` in a list of `spaceCount` Spaces.
    /// The list must have exactly `spaceCount` children.
    static func thumbnail<N: AXTreeNode>(in list: N, index: Int, spaceCount: Int) -> ThumbnailLookup<N> {
        let children = list.children
        guard children.count == spaceCount, index >= 0, index < children.count else {
            return .countMismatch(listCount: children.count)
        }
        let thumbnail = children[index]
        guard thumbnail.actionNames.contains(removeAction) else { return .noRemoveAction(thumbnail) }
        return .found(thumbnail)
    }
}

/// `AXTreeNode` over a live `AXUIElement`. Each property reads the element again.
struct LiveAXNode: AXTreeNode {
    let element: AXUIElement

    var identifier: String? { AXTree.string(element, "AXIdentifier") }
    var children: [LiveAXNode] { AXTree.children(element).map(LiveAXNode.init) }
    var displayID: UInt32? { (AXTree.attribute(element, "AXDisplayID") as? NSNumber)?.uint32Value }
    var actionNames: [String] { AXTree.actions(element) }
}

/// Shared access to Mission Control through its Accessibility tree.
///
/// `SpaceCreator` and `SpaceRemover` use these functions. Only Mission
/// Control can add or remove a desktop. So both classes press tree elements
/// while Mission Control is open. `MissionControlSession` opens and closes it.
@MainActor
public enum MissionControl {
    /// Poll interval for the Accessibility tree: 10 ms.
    static let axPollMs = 10
    /// Poll interval for SkyLight: 50 ms.
    static let skyLightPollMs = 50
    /// Cap for one wait on the tree or on SkyLight.
    static let waitCapMs = 2000
    /// Cap for the close wait. Escape is the fallback.
    static let closeCapMs = 1000
    /// Pause after a close without a visible tree. The animation ends in this time.
    static let blindCloseMs = 500
    /// Cap for the start of `Mission Control.app`.
    static let toggleCapMs = 2000
    /// Pause after the close, so the animation ends before a Space switch.
    static let settleMs = 300
    /// Timeout of one Accessibility request to a host, in seconds. The main
    /// thread waits at most this long for one request.
    static let axMessagingTimeout: Float = 0.5

    static let appURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
    /// Virtual key code of Escape.
    static let escapeKeyCode: CGKeyCode = 53

    static let log = Logger(subsystem: "com.simplewm.app", category: "spaces")

    /// Host that showed the tree last. The probe asks it first.
    private static var lastHost: MissionControlHost?

    /// True when Mission Control shows its tree now.
    public static func isOpen() -> Bool {
        root() != nil
    }

    /// True when at least one host process runs.
    public static func hostRuns() -> Bool {
        MissionControlHost.allCases.contains {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
        }
    }

    /// Process IDs of the running hosts. Their windows are not user windows.
    public static func hostPIDs() -> Set<pid_t> {
        Set(MissionControlHost.allCases.compactMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).first?.processIdentifier
        })
    }

    /// Root of the open Mission Control tree and its host, or nil.
    ///
    /// The function probes each running host. The host of the last match
    /// goes first.
    static func root() -> (root: LiveAXNode, host: MissionControlHost)? {
        for (host, app) in hostApplications() {
            if let root = MissionControlTree.root(inApplication: app) {
                lastHost = host
                return (root, host)
            }
        }
        return nil
    }

    /// Application elements of the running hosts, last match first.
    private static func hostApplications() -> [(MissionControlHost, LiveAXNode)] {
        var order = MissionControlHost.allCases
        if let lastHost, let i = order.firstIndex(of: lastHost) {
            order.remove(at: i)
            order.insert(lastHost, at: 0)
        }
        return order.compactMap { host in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: host.bundleID).first
            else { return nil }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
            return (host, LiveAXNode(element: element))
        }
    }

    /// One line per host with the identifiers of its top-level children.
    /// For diagnostics.
    static func hostSummary() -> String {
        hostApplications().map { host, app in
            let ids = app.children.map { $0.identifier ?? "-" }
            return "\(host.bundleID): [\(ids.joined(separator: ","))]"
        }.joined(separator: " ")
    }

    /// Toggles Mission Control with `Mission Control.app`. It does not depend
    /// on the keyboard shortcut. `activates` is false, so the focus stays.
    ///
    /// Returns false when the app did not start. Then Mission Control did
    /// not change. The wait for the start has a cap of `toggleCapMs`. After
    /// the cap the function returns true: the launch is slow, but it runs.
    static func toggle() async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let log = self.log
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error {
                    log.error("Mission Control did not start: \(String(describing: error), privacy: .public)")
                }
                once.resume(error == nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(toggleCapMs)) {
                if once.resume(true) {
                    log.warning("Mission Control.app did not report its start after \(toggleCapMs, privacy: .public) ms.")
                }
            }
        }
    }

    /// Resumes a continuation once. Later calls do nothing.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        /// Returns true when this call resumed the continuation.
        @discardableResult
        func resume(_ value: Bool) -> Bool {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
            return pending != nil
        }
    }

    /// Posts Escape. Mission Control closes on Escape.
    static func postEscape() {
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: escapeKeyCode, keyDown: down)?
                .post(tap: .cghidEventTap)
        }
    }

    /// Waits until the close animation ends: a fixed pause, then until
    /// SkyLight reports that the display does not animate.
    static func settle(display: DisplayID) async {
        try? await Task.sleep(nanoseconds: UInt64(settleMs) * 1_000_000)
        await SpaceReader.waitWhileAnimating(display, timeoutMs: 600)
    }

    // MARK: - Waiting

    /// End of a time budget.
    struct Deadline {
        let end: Date
        init(ms: Int) { end = Date().addingTimeInterval(Double(ms) / 1000) }
        var remaining: TimeInterval { end.timeIntervalSinceNow }
    }

    /// Calls `body` now and then every `everyMs` until it returns a value.
    /// Stops after `capMs` or when `budget` ends. Returns nil on a timeout.
    static func poll<T>(everyMs: Int, capMs: Int, budget: Deadline,
                        _ body: () -> T?) async -> T? {
        let stop = min(Date().addingTimeInterval(Double(capMs) / 1000), budget.end)
        while true {
            if let value = body() { return value }
            if Date() >= stop { return nil }
            try? await Task.sleep(nanoseconds: UInt64(everyMs) * 1_000_000)
        }
    }
}

/// One use of Mission Control by `SpaceCreator` or `SpaceRemover`.
///
/// `open(budget:)` reuses an open Mission Control, or toggles it open and
/// waits for the tree. `close()` closes Mission Control when this session
/// opened it. Every path of the caller must call `close()`.
///
/// Rules of `close()`:
/// - The session did not open Mission Control: do nothing.
/// - The tree is visible: toggle, then wait until the tree is gone. When
///   it stays, post Escape and wait again.
/// - The tree was visible and is gone now (the user closed Mission
///   Control): do nothing.
/// - The tree never appeared, but the toggle started: Mission Control is
///   open in an unknown layout, or it opened late. Toggle once more. Each
///   toggle flips the state, so two toggles restore the state before `open`.
@MainActor
final class MissionControlSession {
    private let what: String
    private let log = MissionControl.log
    /// Mission Control was open before `open(budget:)`.
    private(set) var wasOpen = false
    /// This session toggled Mission Control open.
    private(set) var toggled = false
    /// The tree was visible at least once in this session.
    private(set) var treeSeen = false

    /// `what` names the caller in log lines, for example "Create Space".
    init(what: String) {
        self.what = what
    }

    /// Opens Mission Control, or reuses an open one. Returns the tree root,
    /// or nil when the tree does not appear before `budget` ends.
    func open(budget: MissionControl.Deadline) async -> LiveAXNode? {
        if let found = MissionControl.root() {
            wasOpen = true
            treeSeen = true
            log.info("\(self.what, privacy: .public): Mission Control is already open (\(found.host.bundleID, privacy: .public)). The session leaves it open.")
            return found.root
        }
        toggled = await MissionControl.toggle()
        guard toggled else { return nil }
        let found = await MissionControl.poll(everyMs: MissionControl.axPollMs,
                                              capMs: MissionControl.waitCapMs, budget: budget) {
            MissionControl.root()
        }
        guard let found else {
            log.error("\(self.what, privacy: .public): the Mission Control tree did not appear. Hosts: \(MissionControl.hostSummary(), privacy: .public)")
            return nil
        }
        treeSeen = true
        log.debug("\(self.what, privacy: .public): Mission Control tree in \(found.host.bundleID, privacy: .public).")
        return found.root
    }

    /// Step of `close()`.
    enum CloseAction: Equatable {
        /// Leave Mission Control as it is.
        case none
        /// Toggle, then wait until the tree is gone. Escape is the fallback.
        case toggleAndWait
        /// Toggle once more without a visible tree, then pause.
        case blindToggle
    }

    /// Step of `close()` for the state of a session. See the type
    /// documentation for the rules.
    ///
    /// - Parameters:
    ///   - toggled: the session toggled Mission Control open.
    ///   - treeSeen: the tree was visible at least once in the session.
    ///   - treeVisible: the tree is visible now.
    nonisolated static func closeAction(toggled: Bool, treeSeen: Bool, treeVisible: Bool) -> CloseAction {
        guard toggled else { return .none }
        if treeVisible { return .toggleAndWait }
        return treeSeen ? .none : .blindToggle
    }

    /// Closes Mission Control when this session opened it. See the type
    /// documentation for the rules.
    func close() async {
        let action = Self.closeAction(toggled: toggled, treeSeen: treeSeen,
                                      treeVisible: MissionControl.root() != nil)
        toggled = false
        switch action {
        case .none:
            return
        case .blindToggle:
            log.warning("\(self.what, privacy: .public): no visible Mission Control tree. Toggling once more to close Mission Control.")
            _ = await MissionControl.toggle()
            try? await Task.sleep(nanoseconds: UInt64(MissionControl.blindCloseMs) * 1_000_000)
        case .toggleAndWait:
            guard await MissionControl.toggle() else {
                await escape()
                return
            }
            if await waitUntilClosed(capMs: MissionControl.closeCapMs) { return }
            log.warning("\(self.what, privacy: .public): Mission Control stays open after the toggle. Posting Escape.")
            await escape()
        }
    }

    private func escape() async {
        MissionControl.postEscape()
        if await !waitUntilClosed(capMs: 500) {
            log.error("\(self.what, privacy: .public): Mission Control stays open. The user must close it.")
        }
    }

    private func waitUntilClosed(capMs: Int) async -> Bool {
        let gone: Bool? = await MissionControl.poll(everyMs: MissionControl.axPollMs, capMs: capMs,
                                                    budget: MissionControl.Deadline(ms: capMs)) {
            MissionControl.root() == nil ? true : nil
        }
        return gone == true
    }
}

/// Small Accessibility reads. Each function returns nil or an empty value on an AX error.
enum AXTree {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
    }

    /// Action names of `element`, or an empty list on an AX error.
    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    /// Text dump of `root` and its descendants, one line per element:
    /// identifier, role, subrole, description, actions. For diagnostics.
    static func dump(_ root: AXUIElement, maxDepth: Int, depth: Int = 0) -> String {
        let pad = String(repeating: "  ", count: depth)
        let fields = [
            string(root, "AXIdentifier").map { "id=\($0)" },
            string(root, kAXRoleAttribute as String).map { "role=\($0)" },
            string(root, kAXSubroleAttribute as String).map { "subrole=\($0)" },
            string(root, kAXDescriptionAttribute as String).map { "desc=\($0)" },
            string(root, kAXTitleAttribute as String).map { "title=\($0)" },
        ].compactMap { $0 }
        var line = pad + fields.joined(separator: " ") + " actions=" + actions(root).joined(separator: ",")
        if depth < maxDepth {
            for child in children(root) {
                line += "\n" + dump(child, maxDepth: maxDepth, depth: depth + 1)
            }
        }
        return line
    }
}
