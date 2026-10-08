# Notch

Notch is a quiet macOS menu-bar utility that groups open windows into useful categories and opens a compact panel below the notch. Search for a window, then click it to bring it forward. Notch never tiles, moves, resizes, or rearranges your windows.

## Build and install

Requirements: macOS 14 or newer and Swift 6.

```sh
swift build -c release -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
scripts/build-app.sh
scripts/build-app.sh --install
```

The build script creates an ad-hoc signed `build/Notch.app`. Because ad-hoc signatures change on rebuild, macOS may ask you to grant Accessibility permission again. Launch at login and Accessibility permissions are managed locally in System Settings.

## Usage

Open the panel with **⌃`** or by hovering over the notch. Click a window row to switch to it; click a group header to cycle through that group's windows. Drag a row onto another group, or right-click it and choose **Move to**, to save a permanent correction for that window. Choose **Always put <App> in…** to keep that app's windows in a category.

Search with the arrow keys to select a result and Return to switch to it. Press Esc to close the panel. Right-click the menu bar icon for **Settings…** and **Quit Notch**.

## Permissions

Notch uses Accessibility only to read window titles and raise the window you click. You can use the menu-bar panel without granting access, but title matching and switching will be limited. Notch asks for permission from the app itself and links directly to the Accessibility privacy pane.

## How it works

`NotchCore` is Foundation-only and separates window classification from the UI. A `Classifier` asynchronously accepts batches of window features and returns label probabilities (never generated prose). The pipeline checks exact user corrections, a local co-activity stage, and deterministic rules in that order. The grouper assigns every enumerated window once. Session-only moves override classification for the current window lifetime.

Default categories are Communication, Code, Browser, Media, School, System, and Other. Rules include common apps and title keywords scoped to browser windows. Corrections and settings are stored under `~/Library/Application Support/Notch/`; co-activity counts are local and are committed without background timers. Co-activity suggestions use bundle IDs in v1; window-level keys may be added later.

## Privacy

All processing and persistence are local. Notch makes no network requests and does not include analytics or a remote classifier backend.

## Known limitations

- Only on-screen windows in the current Space are enumerated.
- Without Accessibility permission, macOS often omits window titles; app name is used as a fallback.
- CG window IDs are matched to Accessibility windows with the private `_AXUIElementGetWindow` symbol and a frame-position/size fallback. This private API can change in a future macOS release.
- Ad-hoc signing can require re-granting Accessibility after rebuilding.
