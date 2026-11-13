# Changelog

## Unreleased

### Added
- When the bar is full, an app's windows share one button with the app's name and window count, like Windows' "Combine when taskbar is full". The app with the most windows is combined first, only as many as needed for every button to be at least 120 pt wide. Click to pick a window from a list; right-click for Close All Windows, the app's options and Quit. Combined buttons can be dragged like window buttons.
- A second launcher area at the left end of the bar, before the window buttons. Drag a launcher to the other end of the bar, or right-click it → **Move to Left Side** / **Move to Right Side**. The left area only shows while it has icons; each app's side is saved in WindowBar's preferences (`leftLaunchers`).
- Right-click an app → **Keep in Launchers**: the app only shows as a launcher on the right, also while it has windows; its windows get no window buttons. Works for pinned and unpinned apps, saved in WindowBar's preferences (`keptLaunchers`).

### Changed
- The launchers, the app icons on the right, can be dragged sideways to reorder them, running apps that aren't pinned too. The order is WindowBar's own, saved in its preferences (`launcherOrder`); the Dock keeps its order and isn't restarted.
- Pinned apps sit at the right end of the bar, window buttons start at the left.
- In light mode the active window's button has a lighter, paler accent background.
- Pinned app icons show a smaller Dock badge in their top-right corner, with counts above 9 as 9+, so it never covers the next icon.
- Pinned app icons fill the bar's height with a small gap between them.
- Window buttons keep their order across WindowBar restarts and logins. The order is saved in WindowBar's preferences (`windowOrder`).
- New windows appear in the order they were opened, also when WindowBar finds several at once, such as at startup.
- A window that disappears briefly (an app redrawing it, a hiccup in macOS Accessibility) gets its old place back if it returns within 60 seconds. Before, it moved to the end of the bar.
- A relaunched app's windows count as new windows. They don't take over the places of the previous run's windows.
- WindowBar uses about half as much CPU while idle: about 0.35 s per minute instead of 0.66 s.
  - WindowBar checks apps that rarely change less often, down to every 24 seconds. Apps that can't report their window changes are still checked every 3 seconds.
  - A window that changes its title or size, or is minimized or restored, is updated alone instead of its whole app being re-read.
  - The bar only redraws what changed.
  - The timers that check for stuck drags and retry hooking the green button only run while needed.
- Dock badges are read faster and stay visible if the Dock briefly doesn't answer.
- The log records why each window button was removed: closed, no longer a normal window, app quit, app relaunched, or Accessibility access revoked. View it with `/usr/bin/log show --predicate 'subsystem == "local.windowbar"'`.

### Fixed
- Closing Discord's window with its red close button left a dimmed window button, because Discord hides itself instead of closing the window. Now the window button goes away and Discord shows on the right as a running app, until it's shown again. The same applies to other apps that hide themselves when their window is closed.
- Windows of a busy app could stop being checked, because WindowBar kept retrying the same window.
- All window buttons could vanish for a moment when macOS didn't answer the window list request.
- A window that macOS read only partly could get wrong buttons or sizes.
- An app running in several copies could show more than one icon after the pins.
- WindowBar kept saved sizes and "maximized" marks for windows that no longer exist.
- Two Keep in Dock changes within 5 seconds could interfere with each other. Failures to save the Dock's list or restart the Dock are now logged.
- The README gave the green button's timeout as 0.2 s. It is 0.4 s.
