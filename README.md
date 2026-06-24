
# VideoWall
<div align="center">

A native macOS live video wallpaper, in your menu bar.
# ▶ VideoWall

**A native macOS live video wallpaper — in your menu bar.**

VideoWall plays a looping video behind your desktop icons. No Dock icon, no clutter — just a `▶` in the menu bar, your library of clips, and a wallpaper that moves.

Built in Swift, SwiftUI, and AVFoundation. Runs on macOS 15 (Sequoia) and later.
[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-AVFoundation-blue)](https://developer.apple.com/xcode/swiftui/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.1-brightgreen)](#)

## Features
</div>

- **Menu-bar agent** — no Dock presence, opens as a popover.
- **Any video AVFoundation can decode** — mp4, mov, m4v, avi, hevc/h.265, mkv, mpeg, 3gp, ts/mts and more.
- **Multi-display** — runs on every screen, follows you across Spaces (toggle in Settings).
- **Clip trim + loop** — set start/end points per video; loops cleanly with a crossfade.
- **Cycle mode** — automatically rotates through your library with a blurred crossfade transition.
- **Battery-aware** — pauses on battery, resumes on AC (optional).
- **Recording-aware** — pauses when the screen is being captured, so the wallpaper doesn't leak into screenshots or shares (optional).
- **Render-resolution control** — downscale the wallpaper to 720p/1080p/4K to save GPU on Retina displays.
---

## Install (from source)
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

## 📦 Install (from source)

```bash
brew install xcodegen
cd VideoWall
open VideoWall.xcodeproj
```

Press ⌘R. The `▶` icon appears in your menu bar — click it to open the library, import a video, and hit play.
Press **⌘R**. The `▶` icon appears in your menu bar — click it to open the library, import a video, and hit play.

Full build, signing, and distribution notes are in [SETUP.md](SETUP.md).
> **No paid Apple Developer account?** You can still build and run locally. Leave the signing Team blank and disable Hardened Runtime — VideoWall runs fine on your own Mac unsigned.

## Screenshots
Full build, signing, notarization, and distribution notes are in **[SETUP.md](SETUP.md)**.

---

## 🚀 Quick start

1. Click the `▶` icon in your menu bar.
2. In the **Library** tab, click **Import** (or drag a video file straight into the grid).
3. Hit the play button on any thumbnail to set it as your wallpaper.
4. Open **Settings** (⚙) to tune cycling, resolution, battery, and recording behavior.

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
VideoWall/
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

## 📸 Screenshots

_Coming soon._

## Status
---

Personal project, built on evenings and weekends.
## 📄 License

© 2026 Max Køngerskov
[MIT](LICENSE) © 2026 Max Køngerskov

<div align="center">
<sub>Made with ♥ on macOS.</sub>
</div>
Saved it to README.md. Here's the raw markdown to copy-paste directly into GitHub:

<div align="center">

# ▶ VideoWall

**A native macOS live video wallpaper — in your menu bar.**

VideoWall plays a looping video behind your desktop icons. No Dock icon, no clutter — just a `▶` in the menu bar, your library of clips, and a wallpaper that moves.

[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-AVFoundation-blue)](https://developer.apple.com/xcode/swiftui/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.0.1-brightgreen)](#)

</div>

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

## 📦 Install (from source)

```bash
brew install xcodegen
cd VideoWall
xcodegen generate
open VideoWall.xcodeproj
```

Press **⌘R**. The `▶` icon appears in your menu bar — click it to open the library, import a video, and hit play.

> **No paid Apple Developer account?** You can still build and run locally. Leave the signing Team blank and disable Hardened Runtime — VideoWall runs fine on your own Mac unsigned.

Full build, signing, notarization, and distribution notes are in **[SETUP.md](SETUP.md)**.

---

## 🚀 Quick start

1. Click the `▶` icon in your menu bar.
2. In the **Library** tab, click **Import** (or drag a video file straight into the grid).
3. Hit the play button on any thumbnail to set it as your wallpaper.
4. Open **Settings** (⚙) to tune cycling, resolution, battery, and recording behavior.

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
VideoWall/
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

## 📸 Screenshots

_Coming soon._

---

## 📄 License

[MIT](LICENSE) © 2026 Max Køngerskov

<div align="center">
<sub>Made with ♥ on macOS.</sub>
</div>
