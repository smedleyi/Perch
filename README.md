# Perch

A lightweight native macOS window snapping utility. Hold a modifier key and drag any window from anywhere — no title bar required. Release the modifier mid-drag and push to a screen edge to snap. Or use customisable keyboard hotkeys with Windows-style chaining.

Pure Swift, ~1200 lines.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange)

---

## Features

- **Drag from anywhere** — hold a modifier key (default: Control) and click anywhere on a window to move it, not just the title bar
- **Zone snapping** — while dragging with the modifier held, move toward a screen edge or corner to see a snap preview; release the mouse to apply
- **Edge snapping** — release the modifier mid-drag and push the cursor to a screen edge to trigger native-feel snapping
- **Keyboard hotkeys** — snap the focused window with key combos; fully customisable in Preferences
- **Chaining** — press the same hotkey twice to cycle through related positions (e.g. Left Half → Bottom Left Quarter → Left Half)
- **Multi-monitor** — snaps to whichever screen the cursor is on
- **Menu bar only** — no Dock icon; hides completely to the background with an optional "Hide Menu Bar Icon" mode

## Snap zones

| Position | Default hotkey |
|---|---|
| Left Half | ⌥ ← |
| Right Half | ⌥ → |
| Maximize | ⌥ ↑ |
| Center (70%) | ⌥ ↓ |
| Top Left Quarter | ⌃⌥ U |
| Top Right Quarter | ⌃⌥ I |
| Bottom Left Quarter | ⌃⌥ J |
| Bottom Right Quarter | ⌃⌥ K |
| Top Half | ⌃⌥ T |
| Bottom Half | ⌃⌥ B |

All hotkeys are remappable from Preferences.

## Requirements

- macOS 13 Ventura or later
- Xcode command-line tools or a full Xcode install (for `swift build`)
- Accessibility permission (prompted on first launch)

## Installation

One-liner (clones to a temp dir, builds, installs, cleans up):

```bash
curl -fsSL https://raw.githubusercontent.com/smedleyi/Perch/main/install.sh | bash
```

Or clone and run locally:

```bash
git clone git@github.com:smedleyi/Perch.git
cd Perch
bash install.sh
```

Either way, `install.sh` builds a release binary, assembles `Perch.app` in `/Applications`, ad-hoc signs it, and launches it. Subsequent runs reinstall over the existing copy.

On first launch, macOS will prompt for Accessibility access. Grant it in **System Settings › Privacy & Security › Accessibility**, then relaunch.

## Running in the background

Select **Hide Menu Bar Icon** from the menu bar to remove the icon entirely. Perch continues running silently. To restore the icon or open Preferences, relaunch the app via Finder or Spotlight — `applicationShouldHandleReopen` surfaces the Preferences window automatically.

## Architecture

| File | Responsibility |
|---|---|
| `DragManager.swift` | Global mouse event tap; tracks modifier+drag, fires snap preview, applies on mouseUp |
| `HotkeyManager.swift` | Global keyboard event tap; matches hotkeys, suppresses arrow keys during drag |
| `WindowManager.swift` | AXUIElement reads/writes; snap chaining state machine |
| `SnapAction.swift` | Enum of snap positions; `targetFrame(in:)` for AppKit-coordinate output |
| `SnapPreviewWindow.swift` | Borderless overlay window showing the snap target |
| `Config.swift` | UserDefaults-backed settings: drag modifier, hotkey bindings |
| `PreferencesWindowController.swift` | Programmatic NSWindow with hotkey recorder and modifier picker |
| `AppDelegate.swift` | App lifecycle, menu bar item, accessibility prompt |

Coordinate system note: Quartz events use top-left origin; AppKit/AXUIElement position uses bottom-left origin. All conversions go through `NSScreen.screens.first?.frame.height` as the primary screen anchor.

## License

MIT
