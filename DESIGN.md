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
   while a Space is hidden. `prune` drops trees of deleted Spaces.
6. Displays whose current Space is type 4 get no tiling. `space N` still works.
7. Hotkeys use Carbon `RegisterEventHotKey` with physical key codes. The
   Brazilian layout changes nothing.
8. Every private symbol is optional. A missing symbol disables one feature.
9. The app refuses to tile while AeroSpace (`bobko.aerospace`) runs.

## Space switching

Strategies run in order. The app caches the first strategy that verifies.
Verification polls `SLSManagedDisplayGetCurrentSpace` every 30 ms, 600 ms max.

1. `GestureSwitch`: synthetic Dock swipe (yabai v7.1.19). Warp the cursor to
   the target display. Post one swipe per step over the full `Spaces[]`
   list. Verify, recompute steps, repeat at most two rounds. Restore cursor.
2. `ControlKeySwitch`: post Ctrl+N. Runs only when "Switch to Desktop N" is
   enabled (`com.apple.symbolichotkeys` IDs 118..126). Verify.
3. Failure: log and show `WM!` in the menu bar.

## Move window to Space N

Target is the Nth type-0 Space of the window's display. Strategies in order,
each verified with `SLSCopySpacesForWindows` within 300 ms:

1. `BridgedMove`: `SLSBridgedMoveWindowsToManagedSpaceOperation` run by the
   file-local `SLSPerformAsynchronousBridgedWindowManagementOperation`
   (found by `LC_SYMTAB` walk).
2. `CompatIDMove`: `SLSSpaceSetCompatID(sid, 0x79616265)`,
   `SLSSetWindowListWorkspace`, `SLSSpaceSetCompatID(sid, 0)`.
3. `ManagedSpaceMove`: `SLSMoveWindowsToManagedSpace`.

On success the engine transfers the window between trees. With
`followOnMove` the app switches after the move.

## Tiling rules (i3)

- Insert: new leaf after the focused leaf, half its weight.
- Remove: a non-root container with one child collapses.
- Focus: climb to the nearest ancestor on the axis with a sibling on that
  side. Descend by most-recent-use. No wrap. No match: next display.
- Move: same climb. Swap with a sibling leaf. Enter a sibling container at
  the near edge. At the root edge: move to the next display.
- Fullscreen (`alt-f`): zoom inside the tree. Native fullscreen stays untouched.
- `toggle-split` flips the parent orientation. `balance` resets weights.

## Event flow

1. Sources: AX notifications (created, destroyed, miniaturized, moved,
   resized, focus), NSWorkspace app and Space events, screen changes,
   hotkeys, a 2 s timer.
2. `WMController.scheduleRefresh()` debounces 40 ms. It waits while the
   left mouse button is down.
3. `refresh()`: read displays, skip type-4 current Spaces, collect tileable
   windows, reconcile each tree, compute frames, write frames that differ by
   more than 2 pt (size, position, size).
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
- `screensHaveSeparateSpaces == false`: the app tiles the focused display
  only and logs a warning.
- Apps with minimum sizes can refuse frames. The app logs and keeps going.
- Carbon status `-9878` means another process owns the chord. The app logs it.
