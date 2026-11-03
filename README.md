# Swoop

Windows-style Alt+Tab for macOS: switches between individual windows, with previews, across Spaces and including minimized windows. Lives in the menu bar. Everything below can be changed in Settings.

## Shortcuts

Up to 9, each with its own modifiers, key and rules for which windows it shows (apps, Spaces, screens, minimized, hidden, full screen, windowless apps, tabs, order, grouping) and what releasing it does (switch, stay open or search). The defaults are `⌘ Tab` and `⌥ Tab`, showing all windows. Adding `⇧` goes backward.

While the switcher is open:

| Key | Action |
|---|---|
| Arrow keys, or `H` `J` `K` `L` if turned on | Move the highlight |
| `Return`, or click a tile | Switch now |
| `Esc` | Cancel |
| `W` | Close the window |
| `M` | Minimize or restore the window |
| `F` | Toggle full screen |
| `Q` | Quit the app |
| `H` | Hide or show the app |
| `S` | Search |

The selected or hovered tile also has an X in its corner, which closes that window and leaves the switcher open. Settings > Appearance can turn it off, and can add minimize and full screen buttons that show on hover.

All of these can be rebound or unassigned, and a separate key for going backward can be added. Three- and four-finger trackpad swipes can open the switcher too.

## Appearance

Thumbnails, app icons or titles; four sizes; light, dark or system theme; which screen it appears on; what titles show and where they're shortened; a full-size preview of the selected window; and whether tiles show buttons, status icons and Space numbers.

## Full Screen

Settings > Full Screen can show the red, yellow and green window buttons in the menu bar while the front window is in full screen. Yellow leaves full screen first, because macOS can't minimize a full screen window.

## Exceptions

Per app, by bundle ID: hide it from the switcher (always, when it has no windows, or by title), or let it keep the shortcuts (always, or when full screen, which is the default for remote desktops and VMs).

## Install

```sh
bash install.sh
```

Grant Accessibility when asked. Screen Recording is optional: without it, tiles show app icons instead of previews. Native `⌘ Tab` stays in place until Accessibility is granted, and whenever no shortcut uses it.

Installs are ad-hoc signed, so each reinstall invalidates the permissions. Reset them with:

```sh
tccutil reset Accessibility com.isaac.swoop
tccutil reset ScreenCapture com.isaac.swoop
```

## Checks

```sh
swift run SwoopCoreCheck      # switcher logic
.build/debug/Swoop --check    # private APIs, permissions and window discovery on this Mac
```

## Native ⌘Tab

Swoop turns off the macOS switcher only for key combinations a shortcut uses. That setting outlives the app, so `SwoopWatchdog`, a small separate process, turns it back on when Swoop ends, including after a crash or force quit.

## Icon

`AppIcon.icns` is generated from `GenerateIcon.swift`. Re-run with `swift GenerateIcon.swift && iconutil -c icns AppIcon.iconset -o AppIcon.icns` to tweak it.

## How it works

Swoop relies on private macOS APIs, because there's no public way to do this. A macOS update could break them, and `--check` shows which.

The approach comes from reading [AltTab](https://github.com/lwouis/alt-tab-macos) (GPL-3.0), including its notes on what breaks focus and input methods. The code here is written separately, but check the licensing implications before distributing it.
