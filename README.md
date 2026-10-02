# Yabaibye — macOS Tiling Window Manager

**A native macOS window manager for grid tiling, drag-to-split layouts, and keyboard control of Spaces — designed to keep System Integrity Protection (SIP) enabled.**

**English** | [简体中文](README.zh-CN.md)

[![macOS CI](https://github.com/kenxcomp/yabaibye/actions/workflows/ci.yml/badge.svg)](https://github.com/kenxcomp/yabaibye/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Looking for a **yabai alternative** with built-in hotkeys? Yabaibye combines a macOS menu bar app, multi-monitor Space navigation, and customizable window layouts in Swift and AppKit. It runs independently of yabai and skhd, without Dock injection or a scripting addition.

**Development preview.** Native Space operations use private macOS interfaces and Mission Control accessibility. Full-SIP, dual-display behavior has been tested on **macOS 27.2 (26B5091g)**; this does not establish compatibility with every macOS version. See the [validation record](docs/VALIDATION.md) before relying on a particular feature. The app UI is currently in Chinese; English UI contributions are welcome.

[Get started](#get-started) · [Default shortcuts](#default-shortcuts) · [How tiling works](#drag-to-split-or-swap) · [FAQ](#faq) · [Report an issue](https://github.com/kenxcomp/yabaibye/issues/new/choose)

## Features

| Feature | What you can do |
|---|---|
| **Automatic grid tiling** | Among tiled windows, arrange three in two columns, with two stacked on the left; four use a 2×2 grid, and larger groups use a near-square grid. |
| **Drag-to-split layouts** | Drop on a window edge to split its region, or drop in its center to swap positions. A muted red, diagonally hatched overlay previews the result. |
| **Native macOS Spaces** | Jump directly to numbered desktops, move the focused window between Spaces, and navigate desktops on either display. |
| **Customizable keyboard shortcuts** | Change the key and modifiers for all 28 actions, with duplicate and registration-conflict checks. |
| **Adjustable padding and gaps** | Set screen-edge padding and window spacing independently from 0–100 pt. |
| **Window zoom and floating** | Fill the current desktop's usable area and restore it, or toggle an individual window between tiled and floating. |
| **Layout persistence** | Keep tiled/floating membership and restore custom partitions for still-open windows across restarts within the same login session. |
| **Foreground-window protection** | Attempt to raise the active window above overlapping ordinary background windows, with up to four attempts and increasing delays per obstruction episode. Recheck both app and window focus before each attempt without changing app focus or window levels. |

## Drag to split or swap

Three tiled windows start in two equal-width columns: **A above B** on the left and **C** filling the right. Drag **A below B** to reorder the left column; then drag **A to the right of C** to create three equal columns:

```text
Default layout          A below B               A right of C
┌────────┬────────┐     ┌────────┬────────┐      ┌─────┬─────┬─────┐
│   A    │        │     │   B    │        │      │     │     │     │
├────────┤   C    │  →  ├────────┤   C    │  →   │  B  │  C  │  A  │
│   B    │        │     │   A    │        │      │     │     │     │
└────────┴────────┘     └────────┴────────┘      └─────┴─────┴─────┘
```

Drop in the **center** to swap, or at the **top, bottom, left, or right edge** to split. Press Escape during a drag to cancel. Drag partitioning operates within one Space. Four windows use a 2×2 grid by default, including on an ultrawide display. Saved automatic layouts follow the current default when refreshed; saved custom partitions retain their structure, including manually arranged three-column layouts.

## Get started

### Download and install

Download the [notarized 0.1.3 (4) DMG or ZIP](https://github.com/kenxcomp/yabaibye/releases/tag/v0.1.3%2B4). This optimized universal Release build for Apple Silicon and Intel is signed with Developer ID and notarized by Apple. Other releases may have different signing status: the GitHub Actions Release workflow currently produces explicitly labeled, non-notarized packages. Check each release's notes and `release.json`. Local runtime validation covers Apple Silicon; Intel and every supported macOS version have not been individually tested.

Drag `Yabaibye.app` into **Applications**, open it, grant Accessibility access and enable window management. The main window shows the actual version/build and **登录时启动** (Start at login). Enable it there; if macOS approval is required, the app opens Login Items settings and shows a pending status until approval. This starts the app after user login, not before login as a system daemon.

Release archives include `SHA256SUMS`. See [the packaging guide](docs/RELEASING.md) for automatic version increments, Developer ID signing and notarization.

### Build from source

The package declares **macOS 14+** and **Swift 5.9+**. Install Xcode or the Xcode Command Line Tools with a suitable Swift toolchain. The project has no third-party package dependencies.

```sh
git clone https://github.com/kenxcomp/yabaibye.git
cd yabaibye
swift test
./script/build_and_run.sh --verify
```

This builds and opens `dist/Yabaibye.app`. First launch starts with window management paused. This development command does not increment the version. The build script uses ad-hoc signing unless you configure your own stable signing identity. Rebuilding with a different identity can require Accessibility authorization again.

Every bundle build enables Hardened Runtime with default library validation and checks that no runtime exception entitlements were added. You can repeat this check with `./script/verify_security.sh dist/Yabaibye.app`; this verifies local signing protection, not Apple notarization.

### Enable window management

1. Open **Privacy & Security → Accessibility** in System Settings and allow **Yabaibye**. On the tested macOS 27.2 system, this permission page is labeled **Device Control and Data Access**.
2. Stop yabai and skhd before enabling Yabaibye. It checks for running instances to avoid competing window managers.
3. In **Desktop & Dock → Mission Control**, enable **Displays have separate Spaces**; log out if macOS requests it. Disable **Automatically rearrange Spaces based on most recent use** if you want stable desktop numbering.
4. Click **YB Ⅱ** in the menu bar, then **启用窗口管理** (Enable window management).
5. Use **快捷键设置…** (Keyboard shortcuts) and **平铺留白…** (Padding and gaps) to personalize the controls. Settings persist automatically after saving.

Keep SIP enabled. Yabaibye does not require an administrator daemon, kernel extension, or Dock injection.

## Which windows are tiled?

When Yabaibye first establishes a baseline in a login session, existing windows are enrolled for tiling, including those on other Spaces or currently minimized. Windows created afterward float by default: Yabaibye keeps their application-provided position and size and does not rearrange the tiled windows for them. Press **Option+T** to add the focused window to tiling or make it floating.

Membership persists within the same login session. Pausing, resuming, or restarting Yabaibye does not enroll floating windows, and temporarily hiding or minimizing a tiled window does not forget its membership. A new login session, including after restarting macOS, establishes a new baseline. The grid rules apply only to tiled windows. The pre-tiling size used when returning a window to floating is remembered only during the current Yabaibye run.

## Default shortcuts

`Option` is `⌥`; `Shift` is `⇧`. Numbered actions follow the physical ANSI home row:

```text
Key:       A  S  D  F  G  H  J  K  L
Space:     1  2  3  4  5  6  7  8  9
```

| Shortcut | Action |
|---|---|
| `Option + A S D F G H J K L` | Focus Space 1–9 respectively |
| `Option + Shift + A S D F G H J K L` | Move the focused window to Space 1–9 |
| `Option + T` | Toggle tiled / floating |
| `Option + Return` | Fill the current desktop's usable area / restore |
| `Option + [` / `Option + ]` | Previous / next Space on the current window's display |
| `Option + Shift + [` / `Option + Shift + ]` | Previous / next Space on the other display |
| `Option + Arrow keys` | Swap with the tiled window in that direction |

Numbering follows Mission Control display/desktop order across monitors and skips fullscreen Spaces. Relative navigation includes fullscreen Spaces and stops at either end. The current display follows the focused window, falling back to the system main screen when there is no focused window. With two displays, the other-display shortcut targets the non-current display; with three or more, it targets the next display in the Space display list, wrapping to the first. Other-display navigation selects the destination directly in Mission Control and restores the original window focus; it does not use the system Control-arrow shortcut. Numbered jumps select the target desktop directly in Mission Control; they do not step through every intermediate desktop, but the system animation remains visible.

All bindings are editable in **快捷键设置…**. Changing a focus shortcut does not automatically change its move-window counterpart; configure each action as needed. Saved custom bindings are retained across app restarts.

## Compatibility and limits

| Area | Current scope |
|---|---|
| macOS requirement | Package minimum: macOS 14; not a promise of runtime Space compatibility on every later version. |
| Live validation | macOS 27.2 (26B5091g), full SIP enabled, two displays. [Detailed evidence](docs/VALIDATION.md) (Chinese). |
| Native Spaces | Private SkyLight / WindowManager interfaces and Mission Control AX navigation; system updates may change behavior. |
| Managed windows | Resizable standard windows. Minimized windows, dialogs, native fullscreen windows, and windows assigned to all desktops are excluded. |
| App size constraints | Some applications enforce minimum dimensions; make such windows floating if they cannot fit a tile. |
| Persistence | Surviving windows in the same login session. Rebooting macOS or recreating application windows is outside the current restoration scope. |
| Foreground protection | Best effort for ordinary background windows. System panels and applications that actively steal focus are outside its scope. |

## FAQ

### Is Yabaibye a yabai replacement that works with SIP enabled?

Yabaibye is an independent alternative for the tiling, keyboard, and native-Space workflows listed above. The tested configuration keeps SIP fully enabled. It is **not a drop-in replacement** for yabai's command-line interface, rules, or configuration files, and it does not import `yabairc` or `skhdrc`.

### Do I need skhd or another hotkey daemon?

No. Global shortcuts are built into the app. You can edit each action's key and Option, Shift, Control, or Command modifiers in the settings window.

### Does it support multiple monitors and macOS Spaces?

Yes, within the tested configuration. Numbered Spaces are shared across displays. Separate shortcuts navigate the current display or the other display with other-display navigation retaining the original window focus. With more than two displays, “other” means the next display after the current one in the Space display list, wrapping at the end.

### Does Option+Return create a native fullscreen Space?

No. It enlarges the active window within the current desktop's usable area, keeping the menu bar and Dock available. Press it again to restore the previous layout or floating-window frame.

### Where can I download it or install it with Homebrew?

Download the [notarized 0.1.3 (4) release](https://github.com/kenxcomp/yabaibye/releases/tag/v0.1.3%2B4). There is no Homebrew formula/cask. GitHub Actions Release packages and [CI development artifacts](https://github.com/kenxcomp/yabaibye/actions/workflows/ci.yml) are currently not notarized; their labels distinguish them from notarized releases.

## Documentation and contributing

Maintained by [kenxcomp](https://github.com/kenxcomp). Issues and pull requests in **English or Chinese** are welcome. Compatibility reports from additional macOS versions and displays are especially useful.

- [中文完整使用说明](README.zh-CN.md) — detailed controls and behavior.
- [Contributing](CONTRIBUTING.md) — development, testing, and useful bug reports.
- [Architecture](docs/ARCHITECTURE.md) · [Acceptance checklist](docs/ACCEPTANCE.md) · [Validation history](docs/VALIDATION.md) — currently in Chinese.
- [Report a bug or request a feature](https://github.com/kenxcomp/yabaibye/issues/new/choose).

The menu offers **布局自检（不切换桌面）** (layout checks without changing Spaces) and **运行窗口与 Space 自检** (window and Space checks). Both use test windows; the full check changes desktops and restores the originals afterward. The full check leaves management paused. Results are available from **查看上次自检结果…** (View last test result). Passing CI does not replace these live checks.

## Acknowledgments and license

Compatibility research references [Hammerspoon's Spaces documentation](https://www.hammerspoon.org/docs/hs.spaces.html), [SkyLight declarations](https://github.com/Hammerspoon/hammerspoon/tree/master/extensions/spaces), [yabai's Space implementation](https://github.com/asmvik/yabai/blob/master/src/space_manager.c), and [DockDoor's bridge research](https://github.com/ejbills/DockDoor/blob/main/DockDoor/Utilities/PrivateApis.swift). Yabaibye is independently implemented and does not bundle these projects.

[MIT License](LICENSE) · Copyright © 2026 kenxcomp

### Migrating existing windows from yabai

Stopping or removing yabai does not necessarily restore the WindowServer **sublevel** it assigned to already-open windows. On the verified macOS 27.2 setup, an old tiled Claude window retained sublevel `-20` while ordinary new windows used `0`; activating or raising it could not overcome that difference. Save work and finish running tasks, then normally quit and reopen the affected app to recreate its windows. Yabaibye does not override system levels or reinstall yabai's scripting addition.

For read-only troubleshooting with known window IDs, run `dist/Yabaibye.app/Contents/MacOS/Yabaibye --diagnose-window-levels <window-id> ...`. This reports only numeric IDs and sublevels, never titles or contents. The private getter is best effort; an unavailable window or symbol reports `unknown`, and compatibility beyond the verified system is not guaranteed.
