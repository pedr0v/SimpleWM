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
   `move-to-space N` only accepts a type-0 target. When the display has fewer
   than N Spaces, the app creates desktops first (decision 10).
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
10. `space N` and `move-to-space N` create the missing Spaces when
    `createMissingSpaces` is true (default). The app presses the "+" button of
    Mission Control through Accessibility. It does not call `SLSSpaceCreate`:
    a process other than the Dock gets a Space that no display owns. The
    creator is `SpaceCreator`. The sequence is in "Create Space".
11. The app installs an update only after the user agrees. See "Updates".

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
3. Failure: log and show `sWM!` in the menu bar.

## Create Space

`space N` and `move-to-space N` need N Spaces on the target display. The
count includes fullscreen Spaces (decision 2). When the display has fewer
than N Spaces, the controller calls `SpaceManager.ensureSpaces(count:on:creator:)`
inside its existing `Task`. Then it continues with the fresh snapshot.
`switchTo(userSpace:on:)` and `move(_:toUserSpace:on:)` stay as they are:
they never create a Space.

Rules of the controller:

- It creates Spaces only when `createMissingSpaces` is true and N is at most 9.
- It logs `space N: created K Space(s)` after a success. A success does not
  set the menu bar warning. Only a failed creation, switch, or move does.
- A failed creation stops the command. The window stays where it is.

Rules of `ensureSpaces`:

- It caps N at 9. It creates at most 9 minus the current count of Spaces.
- It creates one Space at a time and reads the display again after each one.
- It holds the switch lock. A Space switch and a tiling refresh wait for it.
- It returns the fresh snapshot, or nil when a creation fails.

Steps of `SpaceCreator.createSpace(on:)`. Waits 3 to 6 share a budget of 3 s.

1. Check Accessibility trust and read the Space list of the display.
2. Open Mission Control with `Mission Control.app` (`NSWorkspace`,
   `activates = false`). The focus stays. It does not depend on the F3
   shortcut. When the Dock already shows Mission Control, reuse it and leave
   it open.
3. Poll every 10 ms (2 s cap) for the Dock AX child with `AXIdentifier` `mc`.
   It appears after 75 to 120 ms.
4. In the `mc.display` child whose `AXDisplayID` equals the `CGDirectDisplayID`
   of the display, find the button `mc.spaces.add`. Match on the identifier.
   The description text depends on the language ("add desktop",
   "adicionar mesa"). With shared Spaces, any display group works.
5. Send `AXPress` to the button. It returns in 7 to 26 ms.
6. Poll `SLSCopyManagedDisplaySpaces` every 50 ms (2 s cap) until the display
   lists a new type-0 Space. It appears 9 to 27 ms after the press. The Dock
   appends it at the end of `Spaces[]`.
7. Close Mission Control with the same toggle, only when this call opened it.
   Poll until the `mc` group is gone (1 s cap). When it stays, post Escape.
   Then wait 300 ms and until the display does not animate, so a Space switch
   does not start inside the close animation.

The current Space of the display and the frontmost window do not change. One
creation takes about 450 to 600 ms. A timeout or an AX error returns nil and
logs the reason in the `spaces` category.

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
