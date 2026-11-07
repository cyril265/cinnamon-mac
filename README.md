# WindowBar

A Windows-style taskbar for macOS. One bar per screen, one button per window on that screen's current desktop.

## Install

Requires macOS 14 or later, Apple silicon or Intel, the Dock at the bottom of the screen and visible.

1. Install the Xcode Command Line Tools, if you don't have them: `xcode-select --install`
2. Unzip the project, open Terminal in its folder, run `bash build.sh`
   - The first run creates a local signing certificate in its own keychain. Nothing is sent anywhere.
   - WindowBar is installed to `~/Applications` and starts at every login.
3. Click the warning on the bar, then turn on **WindowBar** under System Settings → Privacy & Security → **Accessibility**. WindowBar picks the permission up within a few seconds.

To update, replace the folder with a newer copy and run `bash build.sh` again. The permission stays.

WindowBar needs Accessibility access to see and control windows, and uses undocumented macOS functions (see "Private APIs" below), which a macOS update can break. It has no network access and stores no window contents.

## Use

- **Left:** exactly the Dock's pinned apps, Finder first. Click to open. A pinned app is hidden on every bar while it has a window button on any of them; its window buttons take over. When its last window closes, the pin returns.
  - A dot under an icon means the app is running, as in the Dock.
  - A red badge on an icon (a count or a dot) is the app's Dock badge, such as unread messages. Window buttons show their app's badge too.
  - Right-click: Open (New Window), Keep in Dock, Show in Finder, and Quit while it's running. Window buttons have Keep in Dock and Show in Finder too.
  - Keep in Dock changes the Dock's own pin list (`com.apple.dock` `persistent-apps`) and restarts the Dock, like `dockutil`. The previous list is saved to `~/Library/Application Support/WindowBar/dock-persistent-apps-backup.plist`. A second change within 5 seconds waits, because the Dock rewrites its list right after a restart.
  - Running apps that aren't pinned and have no window button (no window, or only on other desktops) appear after the pins with a dot. Clicking one opens a window or switches to its desktop, like clicking it in the Dock.
- **Right:** one button per window on that screen's current desktop, in the order they were opened.
  - Click: bring that window to the front. Click the active window: minimize it.
  - Minimizing the active window, from the bar or with its own yellow button, activates the window right under it, as on Windows. Quick repeated clicks alternate between minimize and restore.
  - Drag sideways: reorder. Escape or releasing outside the bar cancels. The order survives desktop switches, not a restart of WindowBar.
  - Right-click: Minimize/Restore, Close Window, Quit app.
  - Dimmed: minimized, or its app is hidden.
  - Too many windows: the rest are behind the **+N** button at the end.
- **Green button:** maximizes the window, as on Windows, instead of entering full screen: full width, from the menu bar down to the bar. Click it again to restore the previous size and position. Option-click enters full screen. Windows in full screen, and windows whose green button only zooms, keep the macOS behavior. Hovering still shows the macOS tiling menu.
- Right-click an empty part of the bar: Copy Diagnostics, Quit WindowBar. It starts again at the next login.

Unplugging a display: macOS moves that display's desktops to the remaining screen as extra desktops. Switch to them (Ctrl ←/→, Mission Control) and their windows appear on the bar, in their previous order.

## Build

```
./build.sh        # tests, build, sign, install to ~/Applications, restart (first run: creates the signing keychain)
./build.sh test   # model tests only
```

The install is atomic: the previous version is kept and restored if the new one fails to start. Requires the Xcode Command Line Tools; no Xcode project.

## Code

| File | Contents |
|---|---|
| `Sources/Model.swift` | Pure logic, unit tested: display assignment, resize rule, window order, overflow layout |
| `Sources/Private.swift` | Undocumented macOS functions, looked up at runtime |
| `Sources/WindowWorker.swift` | All Accessibility work on its own thread: observers, window records, focus, resizing, maximizing |
| `Sources/GreenButton.swift` | Mouse event tap that turns green-button clicks into maximize |
| `Sources/Badges.swift` | Reads the Dock's app badges |
| `Sources/Bar.swift` | The bar views, drag and drop, overflow |
| `Sources/main.swift` | Displays, running apps, pinned apps, permissions, menus, diagnostics |
| `Tests/ModelTests.swift` | Tests for `Model.swift` |
| `build.sh`, `setup-signing.sh`, `uninstall.sh` | Install, signing, removal |

## How it works

- **Window list.** Each window is identified by its window-server ID plus its app's session, so a failed or slow read never makes it disappear. A window that leaves the current desktop is kept, with its order, until the window server reports it closed or its app quits.
- **Updates.** Accessibility notifications per app and window (created, closed, moved, resized, renamed, minimized, focus), coalesced, plus a full reconcile every 3 seconds. All Accessibility calls run on a dedicated thread with a 0.4 s timeout, and busy apps are retried with backoff, so a hung app can't freeze the bar.
- **Screens and desktops.** A window belongs to the display that owns its desktop (Space), as reported by SkyLight. That keeps assignment correct while macOS moves desktops after a display disconnects. Without separate Spaces per display, the largest overlap decides.
- **Focus.** Brings exactly that window forward (`_SLPSSetFrontProcessWithOptions`), makes it the app's active window, raises it, and checks the result once. The app's other windows stay where they are, on every display.
- **Space for the bar.** Every bar is as tall as the Dock. On the Dock's screen the bar covers the Dock, and macOS keeps that area free. macOS has no API to reserve space anywhere else, so WindowBar shortens windows that macOS sized down to the bottom edge (Fill, the green button, tiling). It verifies each change, never retries a window that refused (that one keeps its bottom edge under the bar), waits while windows are moving or a mouse button is held, and gives windows their height back when it quits. Keep the Dock at the bottom and visible.
- **Green button.** A mouse event tap on its own thread. Only a click near the top-left corner of the frontmost normal window under the mouse is checked with Accessibility (subrole `AXFullScreenButton`, 0.4 s timeout); that click and its mouse-up don't reach the app. The window is sized, moved and sized again, then checked; the frame before is kept for restoring until the window closes. A window already filling the area (Fill, tiling) counts as maximized and is restored to a centered frame.
- **Badges.** Read from the Dock's own icons through Accessibility (`AXStatusLabel`), once a second on their own thread with a 0.5 s timeout. The Dock posts no notification when a badge changes, so a new badge can take up to a second to appear.
- **Private APIs.** `SLSCopyManagedDisplaySpaces`, `SLSCopySpacesForWindows`, `_AXUIElementGetWindow`, `_SLPSSetFrontProcessWithOptions`, as used by AltTab and yabai. If a macOS update removes one, WindowBar falls back to public APIs. Check with Copy Diagnostics ("private APIs").

## Diagnostics

Right-click the bar → Copy Diagnostics, or `pkill -USR1 -x WindowBar` to write `~/Library/Logs/WindowBar/diagnostics.txt`. Window titles and app names are left out. Live log: `log stream --predicate 'subsystem == "local.windowbar"' --level debug`.

## Signing

The Accessibility permission is tied to the app's code signature. `setup-signing.sh` creates a self-signed certificate, **WindowBar Local Signing**, in its own keychain (`~/Library/Keychains/windowbar-signing.keychain-db`). That keychain's password is stored in the login keychain as `windowbar-signing-keychain`. `build.sh` checks that the signature names this certificate, so rebuilds keep the permission.

## Limits

- Only windows on each screen's current desktop.
- Native tabs: only the selected tab of a tab group gets a button.
- Custom order is not saved across restarts of WindowBar.
- An app that refuses to be resized keeps its bottom edge under the bar.
- No window previews.
- Maximized windows don't follow later changes of the bar height or the menu bar.

## Uninstall

`bash uninstall.sh` quits WindowBar, which gives shortened windows their height back, and removes the app, its autostart, its Accessibility permission, logs and signing keychain. If WindowBar is still listed under System Settings → Privacy & Security → Accessibility, remove it there.
