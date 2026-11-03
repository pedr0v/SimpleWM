# SimpleWM design

SimpleWM is a macOS menu-bar helper. It switches real macOS Spaces with
Option+1..9 and tiles windows on the current Space like i3. It keeps SIP on.
It uses Accessibility, Carbon hotkeys, and private SkyLight functions loaded
with `dlsym`.

## Package

- `swift-tools-version:5.10`, `.macOS(.v14)`, Swift language mode 5.
- `LayoutEngine`: Foundation only. Value types. Testable.
- `MacOSBridge`: SkyLight loader, Space manager, AX windows, observers, hotkeys.
- `SimpleWM`: executable. Config, controller, menu bar, updater.
- Dependency: Sparkle 2 (exact version in `Package.swift`), for the updater.
- `scripts/make-app.sh`: release build, `dist/SimpleWM.app`, embedded
  `Sparkle.framework`, codesign.

## Decisions

1. Spaces are native. The app never emulates workspaces.
2. `N` in `space N` indexes all Spaces of the target display in `Spaces[]`
   order, which is the Mission Control order. A fullscreen Space counts.
   `move-to-space N` only accepts a type-0 target. When Space N does not
   exist, the command goes to the spare desktop at the end of the display
   (decision 10).
3. The app never calls `SLSManagedDisplaySetCurrentSpace`. Yabai calls it
   only inside the Dock.
4. Target display for `space N`: display of the focused window, then the
   active menu bar display, then the display under the mouse.
5. One `TilingTree` per `SpaceKey` (display UUID + Space ID). Trees survive
   while a Space is hidden. Space IDs are global. `rekey` moves a tree when
   macOS moves its Space to another display. `prune` drops a tree only after
   SkyLight misses its Space ID in two refreshes in a row. The check reads the
   raw SkyLight list, not the snapshots that have screen geometry.
6. Displays whose current Space is type 4 get no tiling. `space N` still works.
7. Hotkeys use Carbon `RegisterEventHotKey` with physical key codes. The
   Brazilian layout changes nothing.
8. Every private symbol is optional. A missing symbol disables one feature.
   This includes `_AXUIElementGetWindow`: the app loads it with `dlsym`.
9. The app refuses to tile while AeroSpace (`bobko.aerospace`) runs.
10. `space N` and `move-to-space N` with a missing Space N go to the spare
    desktop when `createMissingSpaces` is true (default). The spare is the
    last Space when it is an empty desktop. Else the app creates one desktop
    at the end. One command creates at most one Space. The app presses the
    "+" button of Mission Control through Accessibility. It does not call
    `SLSSpaceCreate`: a process other than the Dock gets a Space that no
    display owns. The creator is `SpaceCreator`. See "Missing Space N".
11. The app installs an update only after the user agrees. See "Updates".
12. The app finds the Mission Control tree by a probe of two processes, the
    Dock and WindowManager. It does not read the OS version. macOS 27 moved
    the tree from the Dock to WindowManager. See "Mission Control tree".
13. `removeEmptySpaces` is true by default on macOS 27 and later, and
    false before. The Dock of macOS 26 has no `AXRemoveDesktop`. The
    cleanup keeps one empty spare desktop at the end of each display. See
    "Remove empty Spaces".

## Updates

`Updater` wraps a Sparkle `SPUUpdater` with the standard user driver.

- `Info.plist` sets `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`, and
  `SUAllowsAutomaticUpdates` to false. Sparkle never schedules a check and
  never opens a window on its own. The update window has no "install
  automatically" option.
- A timer calls `checkForUpdateInformation` 10 s after the start and then
  every 24 h. This probe reads the appcast only. The delegate reports the
  result: `didFindValidUpdate` sets the menu item to "Update (vX.Y.Z)",
  `updaterDidNotFindUpdate` sets it to "Check for Updates".
- A click on the menu item calls `checkForUpdates`. The Sparkle window opens.
  The download and the install start only after "Install Update".
- "Skip This Version" resets the menu item. Probes do not report a skipped
  version.
- The updater starts only inside an app bundle with `SUFeedURL`. A start
  error only logs. The menu then has no update item.
- The feed is `releases/latest/download/appcast.xml` on GitHub. The release
  workflow signs each archive with the EdDSA key in `SPARKLE_PRIVATE_KEY`.
- The app is not sandboxed, so `make-app.sh` removes the Sparkle XPC
  services. It signs `Autoupdate`, `Updater.app`, the framework, and the app
  in that order, with the hardened runtime and a timestamp.

## Space switching

Strategies run in order. The app caches the first strategy that verifies.
Verification polls `SLSManagedDisplayGetCurrentSpace` every 30 ms. The wait is
600 ms. `GestureSwitch` waits 300 ms plus 250 ms per step instead, at least
600 ms.

1. `GestureSwitch`: synthetic Dock swipe. Warp the cursor to the target
   display. Post one swipe per step over the full `Spaces[]` list. The swipe
   has two forms:
   - macOS 27 and later (`DockSwipeEvent`): macOS 27 ignores a swipe that has
     only the classic CGEvent fields. Each event also carries a serialized
     IOHID payload in the private CGEvent field 4205. One step is three
     events: began, changed, ended. Each event sets progress `s * 0.1`. Only
     the ended event sets velocity `s * 9999` and a velocity record in the
     payload. The sign `s` of a forward move (higher index in `Spaces[]`) is
     -1 with Natural scrolling and +1 without it. A backward move uses the
     opposite sign. The strategy reads Natural scrolling on each request.
     The strategy builds all events of the request first. When one event
     fails, it posts nothing: a truncated sequence leaves the Dock in the
     middle of a swipe. The gate reads the major version from
     `kern.osproductversion`. `SIMPLEWM_SWIPE_PAYLOAD=1` or `0` forces the
     form on or off.
   - macOS 26 and earlier (yabai v7.1.19): one began and one ended event per
     step. Progress is `s` and velocity is `s * 9999` on both events. A
     forward move has the sign +1.

   The posted sign is the base sign of the form times `directionFactor`. The
   strategy flips `directionFactor` when a round moves the wrong way. On
   macOS 27, a Dock restart or a change of Natural scrolling resets
   `directionFactor` to 1. The macOS 27 form keeps the real cursor location
   in the events.

   Verify. When the target is not reached, wait until the display stops (not
   animating, same Space for three polls 100 ms apart). Only then recompute
   steps and start round 2 (at most two rounds). A burst of swipes reports
   each hop as the current Space, so round 2 never reads a hop in the middle.
   Restore cursor. With `warpCursor` false, the legacy form points the event
   location at the target display. The Dock can ignore it, so a round that
   moves nothing makes the next round warp the cursor.
2. `ControlKeySwitch`: post Ctrl+N. Runs only when "Switch to Desktop N" is
   enabled (`com.apple.symbolichotkeys` IDs 118..126). Verify.
3. Failure: log and show `sWM!` in the menu bar.

## Missing Space N

`space N` and `move-to-space N` read the target display. The count includes
fullscreen Spaces (decision 2). `SpaceTargetRules.target(n:count:createAllowed:maxCount:)`
gives the target:

- N is at most the count: Space N.
- N is greater than the count, `createMissingSpaces` is true, and N is at
  most 9 (`SpaceManager.maxSpaceCount`): the spare desktop.
- Else nothing. The log tells the reason (`createMissingSpaces` is off, or N
  is above 9).

`SpaceManager.spareSpace(on:creator:)` gives the spare desktop. It holds the
switch lock and reads the display again. Then
`SpaceTargetRules.spare(spaces:isEmpty:maxCount:)` decides:

- The last Space is a desktop (type 0) with no window: use it. It can be
  the current Space. Then `space N` does nothing.
- Else: create one desktop at the end with `SpaceCreator`.
- The display has 9 Spaces and the last one has a window: nothing.

N does not set the count of new Spaces. Examples on a display with 3 Spaces,
each with a window:

- `space 9` creates Space 4 and switches to it. The display has 4 Spaces.
- `space 8` right after that switches to Space 4 (or stays on it). It
  creates no Space, because Space 4 is an empty last desktop.
- `move-to-space 9` with a focused window moves the window to the empty
  Space 4. A second `move-to-space 9` then creates Space 5, because Space 4
  now has a window.

A second request that waits for the lock reads the display after the first
request. It sees the new Space as the empty last desktop and reuses it. So
two fast presses create one Space.

Rules of the controller:

- It logs `space N: created Space S at position P` or `space N: uses the
  empty last Space S at position P`. A success does not set the menu bar
  warning. Only a failed creation, switch, or move does.
- A failed creation stops the command. The window stays where it is.
- `switchTo(userSpace:on:)` and `move(_:toUserSpace:on:)` never create a
  Space. The controller calls them with the position of the spare.
- The last key press wins. Each `space N`, `back-and-forth`, and `move-to-space N`
  with `followOnMove` takes a ticket from `SpaceManager.reserveSwitch()` when
  the user presses the key. The ticket goes to `switchTo(userSpace:on:ticket:)`.
  A request with an old ticket does not switch. Example: `alt-9` creates
  Space 4, and the user presses `alt-2` during the creation. The `alt-9`
  request ends later, sees an old ticket, and does not switch to Space 4. The
  display ends on Space 2. `SwitchTickets` holds the rule.
- A press for the current Space during a creation or switch still goes to
  the manager. The snapshot of the controller is old in that moment. The
  manager reads the display again and keeps the display on that Space.

## Mission Control tree

Only Mission Control can add or remove a desktop. The app reads its
Accessibility tree while it is open. Live dump on macOS 27.2, Mission
Control open, two displays:

```
WindowManager (com.apple.WindowManager), AXApplication
  AXGroup id=mc.display AXDisplayID=1
    AXButton id=<bundle id>.space.<n>          (one per window, AXPress)
    AXGroup id=mc.spaces title="Spaces Bar"
      AXList id=mc.spaces.list
        AXButton title="Desktop 1" (AXPress, AXRemoveDesktop)
        ...
      AXButton id=mc.spaces.add desc="Add Desktop" (AXPress)
  AXGroup id=mc.display AXDisplayID=4
    ...
```

- macOS 27: the `mc.display` groups are children of the WindowManager
  application. The Dock has only its item list. With Mission Control
  closed, WindowManager has no `mc.display` child.
- macOS 26 and earlier: the Dock application has a group `mc`. The
  `mc.display` groups are its children.
- Below `mc.display` both layouts are the same. Each list child is one
  Space thumbnail in `Spaces[]` order. The only desktop of a display has
  no `AXRemoveDesktop` action.

`MissionControlTree` holds the matching rules as pure functions over the
`AXTreeNode` protocol. Every rule matches identifiers, not text: titles and
descriptions depend on the language. `MissionControl.root()` probes
WindowManager and the Dock and asks the last host that matched first. The
root is the group `mc`, or the application when it has a `mc.display`
child. Mission Control is open when a root exists.

While Mission Control is open, WindowManager puts layer-0 overlay windows
("Material Label Window", "Window Highlight Overlay") on the Spaces.
`SpaceManager.usedSpaces()` ignores windows of the Dock and WindowManager,
so an empty Space stays empty.

## Mission Control session

`MissionControlSession` opens and closes Mission Control for the creator
and the remover. Every path calls `close()`, the failure paths too.

- `open(budget:)`: when the tree is visible, reuse it. Else toggle Mission
  Control with `Mission Control.app` (`NSWorkspace`, `activates = false`)
  and poll the root every 10 ms (2 s cap). The toggle does not depend on
  the F3 shortcut. The wait for the app start has a cap of 2 s.
- `close()` uses `closeAction(toggled:treeSeen:treeVisible:)`:
  - The session did not toggle (Mission Control was open, or the toggle
    failed): do nothing.
  - The tree is visible: toggle, then poll until the tree is gone (1 s
    cap). When it stays, post Escape and poll again (500 ms).
  - The tree was visible and is gone (the user closed Mission Control): do
    nothing.
  - The tree never appeared: toggle once more and pause 500 ms. Each toggle
    flips Mission Control, so two toggles restore the state before `open`.
    This path closes Mission Control in an unknown tree layout.
- After `close()`, wait 300 ms and until the display does not animate, so
  a Space switch does not start inside the close animation.

The Accessibility timeout for one request to a host is 0.5 s.

## Create Space

Steps of `SpaceCreator.createSpace(on:)`. Waits 3 to 6 share a budget of 3 s.

1. Check Accessibility trust and read the Space list of the display.
2. Open a `MissionControlSession`.
3. Wait for the root. On macOS 27.2 it appears 60 to 90 ms after the toggle.
4. In the `mc.display` group whose `AXDisplayID` equals the `CGDirectDisplayID`
   of the display, find the button `mc.spaces.add`. With shared Spaces, any
   display group works.
5. Send `AXPress` to the button.
6. Poll `SLSCopyManagedDisplaySpaces` every 50 ms (2 s cap) until the display
   lists a new type-0 Space. On macOS 27.2 it appears about 60 ms after the
   press, at the end of `Spaces[]`.
7. Close the session.

The current Space of the display and the frontmost window do not change.
One creation takes about 450 to 550 ms on macOS 27.2. A timeout or an AX
error returns nil and logs the reason in the `spaces` category.

## Remove empty Spaces

`removeEmptySpaces` is true by default on macOS 27 and later
(`SpaceRemover.systemSupportsRemoval`). The controller schedules a pass
1.5 s after the last refresh. The pass waits while a mouse button is down,
while a Space transition runs, while the remover runs, and while Mission
Control is open.

`SpaceTargetRules.removableEmptySpaces(spaces:current:isEmpty:)` picks the
candidates of a display. The first Space, the current Space, the last
Space, a fullscreen Space, and a Space with a window stay. So at most one
empty spare desktop stays at the end of each display.

Steps of `SpaceRemover.removeSpaces(_:on:isEmpty:)` (budget 4 s):

1. Open a `MissionControlSession` and find `mc.spaces.list` of the display.
2. For each candidate, highest index first: check the rules again (the
   window check too), wait until the list has as many thumbnails as
   SkyLight has Spaces, run `AXRemoveDesktop` on the thumbnail at the
   index, and poll SkyLight until the Space is gone.
3. Close the session.

A skipped candidate (it got a window or became current) is not a failure.
A failure (no tree, no list, count mismatch, AX error, timeout) blocks the
same candidate set. After 3 failures the cleanup stops until a restart. One
pass handles one display. On macOS 27.2 one pass with two removals takes
about 600 ms.

## Move window to Space N

Target is the Nth Space of the window's display in Mission Control order.
It must be a type-0 Space. The app refuses to
move a native fullscreen window, and it refuses when the display shows a
fullscreen Space. Strategies in order, each verified with
`SLSCopySpacesForWindows` (800 ms for `BridgedMove`, 500 ms for the others):

1. `BridgedMove`: `SLSBridgedMoveWindowsToManagedSpaceOperation` run by the
   file-local `SLSPerformAsynchronousBridgedWindowManagementOperation`
   (found by `LC_SYMTAB` walk).
2. `CompatIDMove`: `SLSSpaceSetCompatID(sid, 0x79616265)`,
   `SLSSetWindowListWorkspace`, `SLSSpaceSetCompatID(sid, 0)`. When the first
   call fails, the strategy stops and leaves the window where it is. When no
   Space lists the window after the move, the strategy moves it back.
3. `ManagedSpaceMove`: `SLSMoveWindowsToManagedSpace`.

A bridged move only queues its operation. After the last strategy fails, the
manager checks once more after 300 ms. A late landing counts as success.

On success the engine transfers the window between trees. The transfer
removes the window from every tree that holds it, so a refresh during the move
does not break it. With `followOnMove` the app switches after the move.

## Tiling rules (i3)

- Insert: new leaf after the focused leaf, half its weight.
- Remove: the leaf weight goes to the previous sibling (the next sibling for
  the first child), so remove undoes insert. A non-root container with one
  child collapses. When the child is a container with the orientation of the
  grandparent, its children join the grandparent (i3 flatten). A root with
  one wrapper of one leaf takes the wrapper orientation and holds the leaf.
- Reconcile: one new window follows the insert rule. Two or more new windows
  in one pass get equal shares, not a halving cascade.
- Focus: climb to the nearest ancestor on the axis with a sibling on that
  side. Descend by most-recent-use. No wrap. No match: next display.
- Move: same climb. Swap with a sibling leaf. Enter a sibling container at
  the near edge when it has the axis of the move. Enter a container with the
  other axis after its most recent child (i3). A move that changes nothing
  does not count. At the root edge: move to the next display.
- Next display: when the next display shows a fullscreen Space, or holds no
  tiled window, focus goes to the front window of that display.
- Fullscreen (`alt-f`): zoom inside the tree. Native fullscreen stays untouched.
- `toggle-split` flips the parent orientation. `balance` resets weights.

## Event flow

1. Sources: AX notifications (created, destroyed, miniaturized, moved,
   resized, focus), NSWorkspace app and Space events, screen changes,
   hotkeys, a 2 s timer.
2. `WMController.scheduleRefresh()` debounces 40 ms. It waits while the
   left mouse button is down, while a Space switch or a Space animation runs
   (3 s at most), and for 1 s after a screen change (macOS moves windows then).
3. `refresh()`: read displays, move and prune trees (see decision 5), skip
   type-4 current Spaces, collect tileable windows, reconcile each tree,
   compute frames, write frames that differ by more than 2 pt (size,
   position, size).
   - A window joins the tree of a Space only when `SLSCopySpacesForWindows`
     lists that Space as its only Space. A window on all desktops floats. A
     window of the old Space, still on screen during a switch, stays out.
   - The frame center decides the display of a window. The SkyLight display is
     the fallback, because SkyLight answers late after a move.
   - A window that AX cannot judge (an app that hangs) stays in its tree for
     10 s while it stays on screen.
   - The app does not write a frame again while the window still shows the
     result of the last refused write for that target. Move and resize events
     of our own writes (250 ms) start no refresh.
4. Commands mutate the tree, then apply the layout.
5. Focus: `kAXMain`, `kAXRaise`, `NSRunningApplication.activate`, fallback
   `_SLPSSetFrontProcessWithOptions`.

Tileable: subrole `AXStandardWindow`, not minimized, `AXFullScreen` false,
position and size settable, on screen at layer 0, bundle ID not in
`floatingApps`, not our pid, has an enabled zoom button (when
`floatWindowsWithoutZoom` is true), not in the `toggle-float` set.
The `toggle-float` command (`alt-shift-space`) adds or removes the focused
window from that set and removes it from its tree. The set drops a window
on `windowDestroyed`.

## Bindings (default)

| Chord            | Command            |
|------------------|--------------------|
| alt-1..9         | space N            |
| alt-shift-1..9   | move-to-space N    |
| alt-h/j/k/l      | focus left/down/up/right |
| alt-shift-h/j/k/l| move left/down/up/right  |
| alt-f            | fullscreen (zoom)  |
| alt-e            | toggle-split       |
| alt-r            | balance            |
| alt-shift-minus  | resize -0.05       |
| alt-shift-equal  | resize 0.05        |

Config lives at `~/.config/simplewm/config.json`. A bad file keeps the last
good config. A bad binding is logged and skipped.

## Fallbacks and limits

- AX lists only windows on visible Spaces. The app reconciles a tree only
  while its Space is current.
- Ad-hoc codesign changes the cdhash on each build. Set
  `SIMPLEWM_SIGN_IDENTITY` to a stable identity to keep the Accessibility grant.
- `screensHaveSeparateSpaces == false`: SkyLight lists one display, `Main`.
  The manager builds one snapshot per physical screen with the shared Space
  list. Each screen has its own tree. The app tiles the focused screen only
  and logs a warning.
- Apps with minimum sizes can refuse frames. The app logs and keeps going.
- Carbon status `-9878` means another process owns the chord. The app logs it.
