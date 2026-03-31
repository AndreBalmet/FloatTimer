# FloatTimer

A minimal, always-on-top countdown and stopwatch widget for macOS.

![FloatTimer Preview](preview.png)

## Features

- **Countdown & Stopwatch** modes — switch with the ⇄ button
- **Floating window** — stays above all apps, draggable anywhere
- **Minimal UI** — controls appear on hover, disappear when idle
- **Custom time entry** — double-click the time to type a duration
- **Chime alert** — synthesized tone plays when countdown hits zero
- **Keyboard shortcuts** — Space to play/pause, Enter to confirm edits
- **No dependencies** — single Swift file, no packages, no frameworks beyond Cocoa

## Build & Run

Requires macOS 13+ and Xcode Command Line Tools.

```bash
./build.sh
open build/FloatTimer.app
```

To install:

```bash
cp -r build/FloatTimer.app /Applications/
```

## Usage

| Action | How |
|--------|-----|
| Play / Pause | Click ▶ or press Space |
| Reset | Click ↺ |
| Switch mode | Click ⇄ |
| Set custom time | Double-click the time display, type digits |
| Move window | Click and drag anywhere on the widget |
| Close | Click ✕ |

Time entry accepts digits as `MMSS` or `HHMMSS` (e.g. type `130` for 1 minute 30 seconds).

## License

MIT
