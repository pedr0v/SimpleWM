# SimpleWM

SimpleWM is a macOS menu-bar helper. It gives i3-style keys to the native
macOS Spaces.

- `Option+1..9` switches the focused display to its Nth native Space.
- `Option+Shift+1..9` moves the focused window to Space N of its display.
- When Space N does not exist, the app creates desktops until it does.
- An empty desktop goes away on its own, as an empty i3 workspace does.
  One spare empty desktop stays at the end of each display.
- The app tiles the windows of each normal Space in an i3-style split tree.
- Floating windows stay floating. Settings panels, dialogs, and windows
  without a zoom button keep their own size and position.

The app uses real Spaces. It does not emulate workspaces (AeroSpace does).
It keeps SIP on. It loads private SkyLight functions with `dlsym`. Each
private function is optional: a missing function disables one feature only.

Requirements: macOS 14 or later (tested on macOS 26.1). To build from source: Xcode 16 or later.

## Install

### From a release (no build)

1. Download `SimpleWM-<version>.zip` from the
   [Releases page](https://github.com/pedr0v/SimpleWM/releases).
2. Unzip it and move `SimpleWM.app` to `/Applications`.
3. Quit AeroSpace. SimpleWM does not tile while `bobko.aerospace` runs. Both
   apps use the same `Option` chords.
4. Open SimpleWM. macOS asks for Accessibility. Click "Open System
   Settings" and turn on SimpleWM. The app checks the grant every 2 s and
   starts itself.
5. Optional: open System Settings > Desktop & Dock. Turn on "Displays have
   separate Spaces". Without it, the app tiles only the focused display.

The release is signed with a Developer ID and notarized. The Accessibility
grant survives updates.

### Updates

The app uses [Sparkle](https://sparkle-project.org) 2. It never installs an
update without your permission.

- The app reads the appcast of the latest GitHub release 10 s after it
  starts and then every 24 h. This check shows no window and downloads no
  release.
- When a newer version exists, the menu item "Check for Updates"
  changes to "Update (vX.Y.Z)".
- Click the item. The Sparkle window shows the new version. Click "Install
  Update" to download and install it. Sparkle then relaunches the app.
- "Check for Updates" checks now and shows the result in a window.
- "Skip This Version" hides that version until you check by hand.

Sparkle checks the EdDSA signature of each update before it installs it.

### From source

```sh
scripts/make-app.sh
open dist/SimpleWM.app
```

The script signs with the first "Developer ID Application" identity in your
keychain. Without one it uses an ad-hoc signature. An ad-hoc signature
changes on each build, so macOS drops the Accessibility grant. To use
another identity:

```sh
SIMPLEWM_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/make-app.sh
```

If the grant stops working after a rebuild, reset it and add the app again:

```sh
tccutil reset Accessibility com.simplewm.app
```

## Menu bar

The status item shows a split icon and a short title:

| Title | Meaning |
|-------|---------|
| `sWM`  | Enabled. Tiling runs. |
| `sWM!` | Warning: no Accessibility grant, AeroSpace runs, or the last Space switch, creation, or move failed. |
| `sWM·` | Disabled. |

Menu items: Enabled (toggle), Open Config, Reload Config, Start at Login,
the update item, Quit. When a warning is active, the first menu row shows the reason.

"Start at Login" is on by default. The app registers itself at the first
start from `/Applications`. macOS can ask for approval in System Settings >
General > Login Items. Use the menu item to turn it off.

The update item shows "Check for Updates", or "Update (vX.Y.Z)" when
a newer release exists (see Updates). A build that runs outside the app
bundle (`.build/debug/SimpleWM`) has no update item.

## Default bindings

| Chord | Command | Action |
|-------|---------|--------|
| `alt-1` ... `alt-9` | `space N` | Switch to native Space N of the focused display. |
| `alt-shift-1` ... `alt-shift-9` | `move-to-space N` | Move the focused window to Space N. |
| `alt-tab` | `back-and-forth` | Switch to the previous Space of the focused display, as in i3. |
| `alt-h` / `alt-j` / `alt-k` / `alt-l` | `focus left/down/up/right` | Move focus. At the edge, focus goes to the next display. |
| `alt-shift-h/j/k/l` | `move left/down/up/right` | Move the window in the tree. At the edge, the window goes to the next display. |
| `alt-f` | `fullscreen` | Zoom the window inside the tree. Native fullscreen is not used. |
| `alt-e` | `toggle-split` | Flip the split orientation of the parent container. |
| `alt-r` | `balance` | Give equal sizes to all windows. |
| `alt-shift-minus` | `resize -0.05` | Make the window smaller. |
| `alt-shift-equal` | `resize 0.05` | Make the window larger. |
| `alt-shift-space` | `toggle-float` | Toggle the focused window between tiled and floating. |
| `alt-comma` / `alt-period` | `focus-monitor left/right` | Move focus to the display on that side. |
| `alt-shift-comma` / `alt-shift-period` | `move-to-monitor left/right` | Move the window to the display on that side. |

Drag the edge of a tiled window with the mouse to resize its split, as in
i3. The new size stays after the mouse up. `alt-shift-minus` and
`alt-shift-equal` do the same from the keyboard.

`N` follows the Mission Control order of the focused display. A fullscreen
app counts as one Space. `move-to-space N` only targets a normal desktop.

If Space N does not exist, the app creates desktops up to N on that display
and then switches to Space N (`space N`) or moves the window there
(`move-to-space N`). A workspace appears on demand, as in i3. The app
creates at most 9 Spaces on a display. Set `createMissingSpaces` to `false`
to turn this off. Then a key for a missing Space does nothing.

When a desktop has no window, the app removes it about 1.5 s later. The
first desktop, the current desktop, a fullscreen app, and the last desktop
of a display always stay. So one empty desktop remains at the end, as in
Mission Control. A window on "All Desktops" keeps no desktop. Set
`removeEmptySpaces` to `false` to turn this off.

Key codes are physical. The keyboard layout (for example ABNT2) does not
change the bindings.

## Config

The config file is `~/.config/simplewm/config.json`. The app writes the
default file on the first start. Use "Open Config" to edit it and "Reload
Config" to apply it.

```json
{
  "bindings" : {
    "alt-1" : "space 1",
    "alt-shift-1" : "move-to-space 1",
    "alt-h" : "focus left",
    "alt-shift-h" : "move left",
    "alt-f" : "fullscreen",
    "alt-e" : "toggle-split",
    "alt-r" : "balance",
    "alt-v" : "split vertical",
    "alt-shift-minus" : "resize -0.05",
    "alt-shift-equal" : "resize 0.05"
  },
  "createMissingSpaces" : true,
  "removeEmptySpaces" : true,
  "floatingApps" : [
    "com.apple.systempreferences"
  ],
  "floatWindowsWithoutZoom" : true,
  "followOnMove" : false,
  "gaps" : {
    "inner" : 0,
    "outer" : 0
  },
  "rootOrientation" : "auto",
  "spaceSwitch" : {
    "strategy" : "auto",
    "warpCursor" : true
  }
}
```

Keys:

- `bindings`: chord text to command text. A `bindings` object replaces all
  default bindings. Set a command to `none` to skip a chord.
  - Modifiers: `alt` (or `opt`), `shift`, `ctrl`, `cmd`.
  - Keys: `a`-`z`, `0`-`9`, `minus`, `equal`, `left`, `right`, `up`, `down`,
    `space`, `return`, `tab`, `escape`.
  - Commands: `focus D`, `move D`, `space N`, `move-to-space N`,
    `fullscreen`, `toggle-split`, `split horizontal|vertical`, `balance`,
    `resize X`, `toggle-float`, `focus-monitor D`, `move-to-monitor D`,
    `back-and-forth` (alias `space back`).
- `createMissingSpaces`: when `true` (default), `space N` and
  `move-to-space N` create desktops on the focused display until it has N
  Spaces. When `false`, a key for a missing Space does nothing.
- `removeEmptySpaces`: when `true` (default), the app removes an empty
  desktop that is not the first, the current, or the last one of its
  display. Removal opens Mission Control for a moment.
- `floatingApps`: bundle IDs that the app never tiles.
- `floatWindowsWithoutZoom`: when `true` (default), a window without an
  enabled zoom button floats. System Settings and most utility panels have
  no zoom button, so they keep their own size and position.
- `followOnMove`: when `true`, `move-to-space N` also switches to Space N.
- `gaps.inner`: points between windows. `gaps.outer`: points at the screen edge.
- `rootOrientation`: `auto` (longer side of the screen), `horizontal`, or `vertical`.
- `spaceSwitch.strategy`: `auto`, `gesture`, or `ctrl-n`. A change applies
  after an app restart.
- `spaceSwitch.warpCursor`: when `true`, the gesture switch moves the
  pointer to the target display for the switch, then moves it back.

A missing key keeps its default value. A file with an error keeps the last
good config, and the app logs the error. A bad binding is logged and skipped.

## Known limitations

- The app uses private SkyLight functions. A macOS update can remove or
  change them. The app logs each missing function and disables only that
  feature.
- Spaces are native. The app does not reorder Spaces. It removes only
  empty desktops (see `removeEmptySpaces`). Reorder Spaces in Mission Control.
- Removing a desktop opens Mission Control for a moment, like creation. The
  app runs the Accessibility action `AXRemoveDesktop` on the thumbnail. When
  a desktop in the middle goes away, the desktops after it shift down by
  one number.
- Creating a Space opens Mission Control for a moment (about half a second
  for each Space). macOS has no public API for this. The app presses the
  "+" button of Mission Control through Accessibility. It needs the
  Accessibility grant. The new Space goes at the end of the list. The
  current Space and the focus stay. A macOS update can change the Mission
  Control layout. Then creation fails, the log shows the reason, and the
  menu bar shows `sWM!`.
- The app does not touch native fullscreen windows or their Spaces. A
  display that shows a fullscreen Space gets no tiling. `space N` still works.
- macOS lists windows only on visible Spaces. The app updates a tree only
  while its Space is visible.
- A window set to "All Desktops" floats. The app does not tile it.

## Floating windows

A floating window keeps its own frame. The app never resizes or moves it.
A window floats when one of these holds:

- Its app is in `floatingApps`.
- Its subrole is not `AXStandardWindow` (dialogs, sheets, panels).
- AX cannot set its position or size.
- It has no enabled zoom button and `floatWindowsWithoutZoom` is `true`.
- You pressed `alt-shift-space` on it. Press again to tile it.

The toggle is per window and lasts until the window closes.
- `move-to-space N` does nothing for a native fullscreen window.
- After a screen change (plug, unplug, wake), the app waits 1 s before it
  tiles again. macOS moves windows in that time.
- Some apps have a minimum size or snap to a grid. They can refuse a frame.
  The app logs this and continues.
- `space N` posts a synthetic Dock swipe. When that fails, it posts `Ctrl+N`.
  The `Ctrl+N` method needs "Switch to Desktop N" in System Settings >
  Keyboard > Keyboard Shortcuts > Mission Control.

## Troubleshooting

Show the app log:

```sh
log stream --predicate 'subsystem == "com.simplewm.app"' --level debug
```

At startup the app logs the displays, their UUIDs, the current Space of
each display, the user-Space count, and the Accessibility grant.

Run a dry run to read these logs without tiling. The app registers the
hotkeys but does not change window frames:

```sh
SIMPLEWM_DRY_RUN=1 .build/debug/SimpleWM
```

- **A key does nothing, log shows status `-9878`.** Another process owns
  the chord (`eventHotKeyExistsErr`). Quit AeroSpace, Rectangle, Raycast, or
  the other app that uses the chord, then choose Reload Config. You can also
  change the chord in the config.
- **Log shows a missing symbol.** This macOS version does not have that
  SkyLight function. The related feature is off. Other features still work.
- **Title shows `sWM!`.** Open the menu. The first row shows the reason.
  - "Accessibility not granted": grant it (see Install, step 4).
  - "AeroSpace is running": quit AeroSpace. Tiling starts again in 2 s.
  - "Last Space switch, creation, or move failed": read the log. Turn on "Switch to
    Desktop N" shortcuts to enable the `Ctrl+N` fallback.
- **`space N` does not create a Space.** Check that `createMissingSpaces` is
  not `false`, that Accessibility is granted, and that N is at most 9. Read
  the log of the `spaces` category: it names the step that failed (Mission
  Control did not open, no add button, no new Space).
- **Windows do not tile after a rebuild.** The ad-hoc signature changed.
  Reset the grant with `tccutil` (see Install).
