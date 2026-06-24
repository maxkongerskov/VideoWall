# VideoWall

A native macOS live video wallpaper, in your menu bar.

VideoWall plays a looping video behind your desktop icons. No Dock icon, no clutter — just a `▶` in the menu bar, your library of clips, and a wallpaper that moves.

Built in Swift, SwiftUI, and AVFoundation. Runs on macOS 15 (Sequoia) and later.

## Features

- **Menu-bar agent** — no Dock presence, opens as a popover.
- **Any video AVFoundation can decode** — mp4, mov, m4v, avi, hevc/h.265, mkv, mpeg, 3gp, ts/mts and more.
- **Multi-display** — runs on every screen, follows you across Spaces (toggle in Settings).
- **Clip trim + loop** — set start/end points per video; loops cleanly with a crossfade.
- **Cycle mode** — automatically rotates through your library with a blurred crossfade transition.
- **Battery-aware** — pauses on battery, resumes on AC (optional).
- **Recording-aware** — pauses when the screen is being captured, so the wallpaper doesn't leak into screenshots or shares (optional).
- **Render-resolution control** — downscale the wallpaper to 720p/1080p/4K to save GPU on Retina displays.

## Install (from source)

```bash
brew install xcodegen
cd VideoWall
xcodegen generate
open VideoWall.xcodeproj
```

Press ⌘R. The `▶` icon appears in your menu bar — click it to open the library, import a video, and hit play.

Full build, signing, and distribution notes are in [SETUP.md](SETUP.md).

## Screenshots

_Coming soon._

## Status

Personal project, built on evenings and weekends.

© 2026 Max Køngerskov
