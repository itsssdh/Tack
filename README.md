# Tack

A native macOS screenshot and screen recording utility (Swift, SwiftUI, AppKit, ScreenCaptureKit). macOS 14 or newer. No account. Your captures never leave your Mac.

## Install

1. Download `Tack-1.0.0.dmg` from the [latest release](https://github.com/itsssdh/Tack/releases/latest), open it and drag Tack into Applications.
2. Open Tack. Because it is not signed with a paid Apple certificate, macOS will warn on first launch: open System Settings > Privacy & Security, scroll down, click **Open Anyway** and confirm with your password or Touch ID. You only do this once.
3. Allow Screen Recording. In Tack's Settings > General, press **Allow…** next to Screen Recording. System Settings opens to the Screen Recording list: press the **+** button, choose Tack from Applications, turn it on and confirm with your password or Touch ID. Then quit and reopen Tack.

Tack is free and open source.

## Build and run

1. Install Apple's command line tools once: `xcode-select --install` (full Xcode is not needed).
2. In Terminal: `cd` into this folder, then `./build_app.sh` (use `UNIVERSAL=1 ./build_app.sh` to also support Intel Macs).
3. Drag `build/Tack.app` into Applications and open it. A viewfinder icon appears in the menu bar.

The first build creates a private signing certificate (its own keychain file) and reuses it, so macOS keeps your permissions across rebuilds. After the first signed build run `tccutil reset ScreenCapture com.itsssdh.tack` once and allow Tack again.

## Permissions (Settings > General shows the state of each, with a button to open System Settings)

| Permission | Needed for |
|---|---|
| Screen Recording | all screenshots and recordings |
| Microphone | “Record microphone” (macOS 15+) |

## Default shortcuts (all can be changed in Settings > Shortcuts)

| Action | Keys |
|---|---|
| Capture Area / Fullscreen / Window | ⇧⌘4 / ⇧⌘3 / ⇧⌘5 |
| Capture Previous Area | ⌃⇧P |
| Capture Text / QR (OCR) | ⌃⇧T |
| Capture and Pin to Screen | ⌃⇧K |
| Start / Stop Screen Recording | ⇧⌘6 |
| Open Annotation Editor | ⌃⇧E |
| Show Capture History | ⌃⇧H |
| Settings | ⌃⇧, |

## What it does

- **After a capture** a preview appears on the main display, in the corner you choose in Settings > Screenshots. Hover it for **Copy** (clipboard only) and **Save** (clipboard + folder), an **X**, a **pin** that keeps it on screen (pinned previews stack above new ones and fold into one group card when the screen is full) and a **pencil** that opens the editor. Clicking anywhere else on it also opens the editor. It stays until you choose.
- **Editor**: arrow, line, rectangle, filled rectangle, ellipse, pen, highlighter, text, numbered counters, blur, pixelate, redact, spotlight, crop (with aspect ratios), rotate, flip, resize, combine images, saved colors, backgrounds with padding / rounded corners / shadow, drag-out export, Export as PNG / JPEG / TIFF / HEIC. **Redact is a solid opaque black box**; blur and pixelate are marked “not secure”.
- **Pinned screenshots**: always on top, drag to move, scroll or pinch to resize, right-click for opacity, Lock Mode (clicks pass through; undo from the menu bar) and OCR.
- **OCR and QR** with Apple’s Vision framework, on a selected area, a preview, or a pin.
- **History**: everything you save, searchable by name and by text inside screenshots (menu bar > Capture History).
- **Screen recording** (⇧⌘6): pick an area, window or full screen, then a setup bar lets you switch computer sound, microphone, webcam bubble, cursor, click highlights and MP4 / GIF before pressing Record. A dashed frame shows the recorded area (it is not in the video). Pause/resume and stop from the floating bar, or press ⇧⌘6 again. Click highlights and the webcam bubble are not drawn when recording a single window.
- **Recordings** come back as a preview in the same corner, playing silently on a loop, with the same Copy / Save, pin, pencil and X buttons. The file is already saved when the recording ends. The pencil opens the video trimmer.
- **Video trimmer**: drag the handles on the timeline to set where the video starts and ends (the picture follows the handle), then export to MP4 or GIF. The result comes back as a preview.
- Files are never overwritten: a number is added if the name is taken.

## Self-test

Build with `TESTING=1 ./build_app.sh`, then `build/Tack.app/Contents/MacOS/Tack --selftest` checks redaction opacity, never-overwrite, rotate/flip, backgrounds, formats, OCR, QR, GIF export and video trim export, and prints PASS or FAIL for each.

## Optional cloud sharing

Not built. If added later it would go behind a single `Uploader` protocol that takes a file and returns a link; nothing in the app calls the network today.
