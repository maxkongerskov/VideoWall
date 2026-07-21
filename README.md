<div align="center">

# ▶ VideoWall

**A native macOS live video wallpaper — in your menu bar.**

VideoWall plays a looping video behind your desktop icons. No Dock icon, no clutter — just a `▶` in the menu bar, your library of clips, and a wallpaper that moves.

[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-AVFoundation-blue)](https://developer.apple.com/xcode/swiftui/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.1-brightgreen)](https://github.com/maxkongerskov/VideoWall/releases/tag/v1.0.1)
[![Download](https://img.shields.io/github/v/release/maxkongerskov/VideoWall?label=download&color=blue)](https://github.com/maxkongerskov/VideoWall/releases/latest)

</div>

---

## Download (ready to use)

Grab the notarized installer from the latest release:

**→ [Download VideoWall 1.0.1 (.dmg)](https://github.com/maxkongerskov/VideoWall/releases/latest/download/VideoWall-1.0.1.dmg)**

Or open the [Releases](https://github.com/maxkongerskov/VideoWall/releases) page.

### Install

1. Open the `.dmg`
2. Drag **VideoWall** into **Applications**
3. Launch from Applications or Spotlight
4. Click the `▶` icon in the menu bar to import a video and play

The app is **Developer ID signed and notarized** by Apple (universal: Apple Silicon + Intel). The DMG is also signed, notarized, and stapled. macOS 15+.

---

## ✨ Features

- **🪶 Menu-bar agent** — no Dock presence, opens as a popover.
- **🎞 Any video AVFoundation can decode** — mp4, mov, m4v, avi, hevc/h.265, mkv, mpeg, 3gp, ts/mts and more.
- **🖥 Multi-display** — runs on every screen, and can follow you across Spaces.
- **✂️ Clip trim + loop** — set start/end points per video; loops cleanly with a crossfade.
- **🔄 Cycle mode** — automatically rotates through your library with a blurred crossfade transition.
- **🔋 Battery-aware** — pauses on battery, resumes on AC (optional).
- **🎥 Recording-aware** — pauses when the screen is being captured, so the wallpaper doesn't leak into screenshots or shares (optional).
- **⚙️ Render-resolution control** — downscale the wallpaper to 720p / 1080p / 4K to save GPU on Retina displays.
- **🚀 Launch at login** — registers with `SMAppService`, ready when you are.

---

## 🚀 Quick start

1. Click the `▶` icon in your menu bar.
2. In the **Library** tab, click **Import** (or drag a video file straight into the grid).
3. Hit the play button on any thumbnail to set it as your wallpaper.
4. Open **Settings** (⚙) to tune cycling, resolution, battery, and recording behavior.

---

## 📦 Build from source

```bash
brew install xcodegen
cd "VideoWall Project/VideoWall"
xcodegen generate
open VideoWall.xcodeproj
```

Press **⌘R**. The `▶` icon appears in your menu bar — click it to open the library, import a video, and hit play.

> **No paid Apple Developer account?** You can still build and run locally. Leave the signing Team blank and disable Hardened Runtime — VideoWall runs fine on your own Mac unsigned.

Full build, signing, notarization, and distribution notes are in **[SETUP.md](VideoWall%20Project/VideoWall/SETUP.md)**.

---

## 🛠 Built with

| | |
|---|---|
| **Language** | Swift 6.0 |
| **UI** | SwiftUI + AppKit bridges |
| **Media** | AVFoundation / AVPlayer |
| **System** | ServiceManagement, IOKit |
| **Tooling** | [XcodeGen](https://github.com/yonaskolb/XcodeGen) |
| **Minimum OS** | macOS 15 (Sequoia) |

---

## 📂 Project structure

```
VideoWall Project/VideoWall/
├── project.yml                       ← XcodeGen spec
├── VideoWall.entitlements
├── SETUP.md                          ← full build & distribution guide
│
└── VideoWall/
    ├── VideoWallApp.swift            ← @main entry point
    ├── AppDelegate.swift             ← Menu bar, windows, orchestration
    │
    ├── Models/                       ← VideoItem, AppSettings, enums
    ├── Managers/                     ← Wallpaper playback + video library
    ├── Windows/                      ← Desktop-level NSWindow
    ├── Views/                        ← Library, NowPlaying, Settings, About…
    └── Components/                   ← VisualEffectView, ParticleView
```

---

## 📄 License

[MIT](LICENSE) © 2026 Max Køngerskov

<div align="center">
<sub>Made with ♥ on macOS.</sub>
</div>
