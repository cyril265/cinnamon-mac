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

- **Left:** one button per window on that screen's current desktop, in the order they were opened.
  - Click: bring that window to the front. Click the active window: minimize it.
  - Minimizing the active window, from the bar or with its own yellow button, activates the window right under it, as on Windows. Quick repeated clicks alternate between minimize and restore.
  - Drag sideways: reorder. Escape or releasing outside the bar cancels. The order survives desktop switches and restarts of WindowBar.
  - Right-click: Minimize/Restore, Close Window, Quit app.
  - Dimmed: minimized, or its app is hidden.
  - Apps that hide themselves when you click a window's red close button, like Discord, lose that window's button: the app moves to the right as a running app until it's shown again.
  - A red badge (a count or a dot) is the app's Dock badge, such as unread messages.
  - Bar full: as Windows' "Combine when taskbar is full", an app's windows share one button showing the app's name and its window count, the app with the most windows first, until every button is at least 120 pt wide. Click it to pick a window, right-click for Close All Windows and the app's options. If the bar is still full, the rest are behind the **+N** button at the end.
- **Right (and left), the launchers:** the Dock's pinned apps, Finder first, followed by running apps without a window button and apps set to Keep in Launchers. Click to open. Drag sideways to reorder, as with window buttons; the order is WindowBar's own and survives restarts, the Dock keeps its order. An app keeps its place while its icon is hidden; newly pinned apps go at the end. A pinned app is hidden on every bar while it has a window button on any of them; its window buttons take over. When its last window closes, the pin returns. Right-click → **Keep in Launchers** moves an app to the launchers for good: its windows get no window buttons and its launcher stays: always if it's pinned, while it runs if not. Click the launcher to bring the app forward.
  - Two launcher areas: one at the right end of the bar, where every app starts, and one at the left end, before the window buttons. Drag an icon to the other end of the bar to move it there, or right-click → **Move to Left Side** / **Move to Right Side**. The left area only shows while it has icons. An app keeps its side while its icon is hidden; WindowBar saves it in its preferences (`leftLaunchers`).
  - A dot under an icon means the app is running, as in the Dock.
  - A small red badge in an icon's corner is the app's Dock badge. Counts above 9 show as 9+.
  - Right-click: Open (New Window), Keep in Dock, Show in Finder, and Quit while it's running. Window buttons have Keep in Dock and Show in Finder too.
  - Keep in Dock changes the Dock's own pin list (`com.apple.dock` `persistent-apps`) and restarts the Dock, like `dockutil`. The previous list is saved to `~/Library/Application Support/WindowBar/dock-persistent-apps-backup.plist`. A second change within 5 seconds waits, because the Dock rewrites its list right after a restart.
  - Running apps that aren't pinned and have no window button (no window, or only on other desktops) appear after the pins with a dot. Clicking one opens a window or switches to its desktop, like clicking it in the Dock.
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
| `Sources/Model.swift` | Pure logic, unit tested: display assignment, resize rule, window order, overflow layout, combining an app's windows |
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
- An app that hides itself on ⌘W instead of the red close button keeps a dimmed window button.
- No window previews.
- Maximized windows don't follow later changes of the bar height or the menu bar.

## Uninstall

`bash uninstall.sh` quits WindowBar, which gives shortened windows their height back, and removes the app, its autostart, its Accessibility permission, logs and signing keychain. If WindowBar is still listed under System Settings → Privacy & Security → Accessibility, remove it there.
