# SimpleWM design

SimpleWM is a macOS menu-bar helper. It switches real macOS Spaces with
Option+1..9 and tiles windows on the current Space like i3. It keeps SIP on.
It uses Accessibility, Carbon hotkeys, and private SkyLight functions loaded
with `dlsym`.

## Package

- `swift-tools-version:5.10`, `.macOS(.v14)`, Swift language mode 5.
- `LayoutEngine`: Foundation only. Value types. Testable.
- `MacOSBridge`: SkyLight loader, Space manager, AX windows, observers, hotkeys.
- `SimpleWM`: executable. Config, controller, menu bar.
- `scripts/make-app.sh`: release build, `dist/SimpleWM.app`, codesign.

## Decisions

1. Spaces are native. The app never emulates workspaces.
2. `N` in `space N` counts only type-0 Spaces on the target display.
   Fullscreen Spaces (type 4) never count. The app never creates a Space.
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

## Space switching

Strategies run in order. The app caches the first strategy that verifies.
Verification polls `SLSManagedDisplayGetCurrentSpace` every 30 ms. The wait is
600 ms. `GestureSwitch` waits 300 ms plus 250 ms per step instead, at least
600 ms.

1. `GestureSwitch`: synthetic Dock swipe (yabai v7.1.19). Warp the cursor to
   the target display. Post one swipe per step over the full `Spaces[]`
   list. Verify. When the target is not reached, wait until the display
   stops (not animating, same Space for three polls 100 ms apart). Only then
   recompute steps and start round 2 (at most two rounds). A burst of swipes
   reports each hop as the current Space, so round 2 never reads a hop in the
   middle. Restore cursor. With `warpCursor` false, the event location points
   at the target display. The Dock can ignore it, so a round that moves
   nothing makes the next round warp the cursor.
2. `ControlKeySwitch`: post Ctrl+N. Runs only when "Switch to Desktop N" is
   enabled (`com.apple.symbolichotkeys` IDs 118..126). Verify.
3. Failure: log and show `WM!` in the menu bar.

## Move window to Space N

Target is the Nth type-0 Space of the window's display. The app refuses to
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
`floatingApps`, not our pid.

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
