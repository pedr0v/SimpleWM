# SimpleWM

SimpleWM is a macOS menu-bar helper. It gives i3-style keys to the native
macOS Spaces.

- `Option+1..9` switches the focused display to its Nth native Space.
- `Option+Shift+1..9` moves the focused window to Space N of its display.
- The app tiles the windows of each normal Space in an i3-style split tree.

The app uses real Spaces. It does not emulate workspaces (AeroSpace does).
It keeps SIP on. It loads private SkyLight functions with `dlsym`. Each
private function is optional: a missing function disables one feature only.

Requirements: macOS 14 or later (tested on macOS 26.1), Xcode 16 or later.

## Install

1. Quit AeroSpace. SimpleWM does not tile while `bobko.aerospace` runs.
   Both apps also use the same `Option` chords.
2. Build the app bundle:

   ```sh
   scripts/make-app.sh
   ```

3. Open the app:

   ```sh
   open dist/SimpleWM.app
   ```

4. Grant Accessibility. Open System Settings > Privacy & Security >
   Accessibility. Turn on SimpleWM. The app checks the grant every 2 s and
   starts by itself.
5. Optional: open System Settings > Desktop & Dock. Turn on "Displays have
   separate Spaces". Without it, the app tiles only the focused display.

The default build uses an ad-hoc signature. Each rebuild changes the
signature, and macOS drops the Accessibility grant. To keep the grant, set
`SIMPLEWM_SIGN_IDENTITY` to a stable codesign identity:

```sh
SIMPLEWM_SIGN_IDENTITY="SimpleWM Dev" scripts/make-app.sh
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
| `sWM!` | Warning: no Accessibility grant, AeroSpace runs, or the last Space switch or move failed. |
| `sWM·` | Disabled. |

Menu items: Enabled (toggle), Open Config, Reload Config, Quit. When a
warning is active, the first menu row shows the reason.

## Default bindings

| Chord | Command | Action |
|-------|---------|--------|
| `alt-1` ... `alt-9` | `space N` | Switch to native Space N of the focused display. |
| `alt-shift-1` ... `alt-shift-9` | `move-to-space N` | Move the focused window to Space N. |
| `alt-h` / `alt-j` / `alt-k` / `alt-l` | `focus left/down/up/right` | Move focus. At the edge, focus goes to the next display. |
| `alt-shift-h/j/k/l` | `move left/down/up/right` | Move the window in the tree. At the edge, the window goes to the next display. |
| `alt-f` | `fullscreen` | Zoom the window inside the tree. Native fullscreen is not used. |
| `alt-e` | `toggle-split` | Flip the split orientation of the parent container. |
| `alt-r` | `balance` | Give equal sizes to all windows. |
| `alt-shift-minus` | `resize -0.05` | Make the window smaller. |
| `alt-shift-equal` | `resize 0.05` | Make the window larger. |
| `alt-shift-space` | `toggle-float` | Toggle the focused window between tiled and floating. |

`N` follows the Mission Control order of the focused display. A fullscreen
app counts as one Space. `move-to-space N` only targets a normal desktop.
The app never creates a Space. If Space N does not exist, the key does
nothing.

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
    `resize X`, `toggle-float`.
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
- Spaces are native. The app does not create, delete, or reorder Spaces.
  Make Spaces in Mission Control.
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
  - "Last Space switch or move failed": read the log. Turn on "Switch to
    Desktop N" shortcuts to enable the `Ctrl+N` fallback.
- **Windows do not tile after a rebuild.** The ad-hoc signature changed.
  Reset the grant with `tccutil` (see Install).
