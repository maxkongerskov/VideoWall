# VideoWall — Setup Guide

A native Swift + SwiftUI macOS video wallpaper app. Lives in your menu bar, no Dock icon.

---

## Prerequisites

| Tool | Install |
|------|---------|
| Xcode 16+ | App Store or [developer.apple.com](https://developer.apple.com/xcode/) |
| xcodegen | `brew install xcodegen` |
| (Optional) Apple Developer account | Required only for notarization / GitHub distribution |

---

## 1 · Generate the Xcode project

```bash
cd VideoWall
xcodegen generate
```

This reads `project.yml` and produces `VideoWall.xcodeproj`. Re-run any time you add or remove Swift files.

---

## 2 · Open in Xcode

```bash
open VideoWall.xcodeproj
```

---

## 3 · Set your Team ID

1. Open `project.yml` and paste your Apple Team ID into the `DEVELOPMENT_TEAM` field.
2. Re-run `xcodegen generate`.  
   — or —  
   Set it directly in Xcode: **VideoWall target → Signing & Capabilities → Team**.

> **No paid developer account?**  
> You can still build and run locally. Just leave Team blank, disable Hardened Runtime, and delete the entitlements file path in the target settings. The app will run on your own Mac without code-signing.

---

## 4 · Build & Run

Press **⌘R** (or Product → Run).

The app will appear in your menu bar as a `▶` icon. Click it to open the popover.

---

## 5 · Import your first video

1. Click the menu bar icon.
2. In the Library tab, click **Import** (or drag a video file directly into the grid).
3. Click the play button on any video thumbnail to set it as your wallpaper.

**Supported formats:** mp4, mov, m4v, avi, hevc/h.265, mpeg, mkv (container), 3gp, ts, mts, and more — anything AVFoundation can decode natively.

---

## 6 · Settings

Click the ⚙ gear in the top-right of the popover to open Settings:

| Setting | What it does |
|---------|-------------|
| Launch at Login | Registers the app with SMAppService (macOS 13+) |
| Play on All Spaces | Video follows you across Mission Control spaces |
| Pause on Battery | Stops playback when on battery to save power |
| Pause During Screen Recording | Prevents the wallpaper from appearing in recordings |
| Resolution | Downscales render output via AVVideoComposition (saves GPU) |

---

## Project structure

```
VideoWall/
├── project.yml                    ← XcodeGen spec
├── VideoWall.entitlements         ← Main app (sandbox OFF for GitHub distro)
├── SETUP.md                       ← this file
│
└── VideoWall/                     ← Main app sources
    ├── VideoWallApp.swift         ← @main entry point
    ├── AppDelegate.swift          ← Menu bar, windows, orchestration
    ├── Info.plist
    │
    ├── Models/
    │   ├── VideoItem.swift        ← Video metadata + VideoResolution enum
    │   └── AppSettings.swift      ← UserDefaults-backed settings + PlaybackMode
    │
    ├── Managers/
    │   ├── WallpaperManager.swift ← AVPlayer, looping, cycle, multi-display
    │   └── VideoLibraryManager.swift ← Import, thumbnail, delete
    │
    ├── Windows/
    │   └── WallpaperWindow.swift  ← Desktop-level NSWindow
    │
    ├── Views/
    │   ├── SplashScreenView.swift ← Animated intro
    │   ├── MenuBarContentView.swift ← Popover (Library + Controls tabs)
    │   ├── LibraryView.swift      ← Video grid with drag-and-drop
    │   ├── VideoCard.swift        ← Individual video thumbnail card
    │   ├── NowPlayingView.swift   ← Active playback strip + volume
    │   ├── SettingsView.swift     ← Settings panel (General / About)
    │   └── AboutView.swift        ← About Dev section
    │
    └── Components/
        ├── VisualEffectView.swift ← NSVisualEffectView bridge + GlassCard
        └── ParticleView.swift     ← Particle animation (splash background)
```

---

## Distributing on GitHub

1. **Code sign**: In Xcode, set your Team and select "Automatically manage signing."
2. **Notarize**: Product → Archive → Distribute App → Direct Distribution → Notarize.
3. **Package**: Create a `.dmg` with [create-dmg](https://github.com/create-dmg/create-dmg):
   ```bash
   brew install create-dmg
   create-dmg \
     --volname "VideoWall" \
     --background "assets/dmg-background.png" \
     --window-size 660 400 \
     --icon-size 128 \
     --app-drop-link 480 160 \
     "VideoWall.dmg" \
     "build/VideoWall.app"
   ```
4. Upload `VideoWall.dmg` as a GitHub Release asset.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| App doesn't appear in menu bar | Make sure `LSUIElement = YES` is in Info.plist |
| Video doesn't show behind icons | Some macOS versions require Accessibility permission — grant in System Settings → Privacy |
| Sandboxing crash on import | Check that `NSDocumentsFolderUsageDescription` key is in Info.plist |
| `SMAppService` crash | Requires macOS 13+; the guard in AppDelegate.applyLaunchAtLogin handles older versions |
| "Pause During Screen Recording" not working | macOS only exposes the recording indicator to apps with **Screen Recording** permission. Settings shows a "Grant Access…" prompt when it's missing; you may need to quit and reopen VideoWall after granting. |

---

Made with ♥ and vibes by Max Køngerskov on Claude.AI
