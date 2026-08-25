import SwiftUI
import AppKit

// MARK: - MenuBarContentView
// Menu-bar popover: header, now-playing, library / controls tabs.

struct MenuBarContentView: View {
    @EnvironmentObject var wallpaper: WallpaperManager
    @EnvironmentObject var library:   VideoLibraryManager
    @EnvironmentObject var settings:  AppSettings

    @State private var selectedTab: Tab = .library

    private enum Tab: String, CaseIterable {
        case library  = "Library"
        case controls = "Controls"
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)

            // Subtle brand wash at top (matches UX draft)
            VStack {
                LinearGradient(
                    colors: [VideoWallTheme.gradB.opacity(0.14), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 120)
                Spacer()
            }
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                header

                if wallpaper.currentVideo != nil {
                    NowPlayingView()
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }

                tabPicker
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)

                Group {
                    if selectedTab == .library {
                        LibraryView()
                    } else {
                        ControlsView()
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(width: VideoWallTheme.popoverWidth, height: VideoWallTheme.popoverHeight)
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(VideoWallTheme.brandGradient)

            Text("VideoWall")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(VideoWallTheme.textPrimary)

            Spacer()

            Button {
                AppDelegate.shared?.openSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Quit VideoWall")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: Segmented tabs

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                let on = selectedTab == tab
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 11, weight: on ? .semibold : .medium))
                        .foregroundColor(on ? VideoWallTheme.textPrimary : VideoWallTheme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(on ? VideoWallTheme.surfaceRaised : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - ControlsView

struct ControlsView: View {
    @EnvironmentObject var wallpaper: WallpaperManager
    @EnvironmentObject var settings:  AppSettings

    private var clipDurationString: String {
        let total   = wallpaper.currentVideo?.duration ?? 0
        let clipped = total * max(0, settings.trimEnd - settings.trimStart)
        if total > 0, abs(settings.trimEnd - settings.trimStart - 1) < 0.001 {
            return "Full clip"
        }
        return DurationFormatting.string(from: clipped, zeroPadMinutes: true)
    }

    var body: some View {
        // No ScrollView: popover height is sized so every control is visible
        // (including Cycle blur + now-playing chrome above).
        VStack(alignment: .leading, spacing: 0) {

            sectionLabel("Playback")
            playbackModePicker()
                .padding(.horizontal, 14)

            if settings.cycleEnabled {
                crossfadeBlurCard
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            sectionLabel("Clip trim")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Range")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.08)
                        .foregroundColor(VideoWallTheme.textTertiary)
                        .textCase(.uppercase)
                    Spacer()
                    Text(clipDurationString)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundColor(VideoWallTheme.textPrimary)
                }

                DualRangeSlider(
                    start: Binding(
                        get: { settings.trimStart },
                        set: { settings.trimStart = min($0, settings.trimEnd - 0.05) }
                    ),
                    end: Binding(
                        get: { settings.trimEnd },
                        set: { settings.trimEnd = max($0, settings.trimStart + 0.05) }
                    )
                )

                HStack {
                    Text(String(format: "%.0f%%", settings.trimStart * 100))
                    Spacer()
                    Text(String(format: "%.0f%%", settings.trimEnd * 100))
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(VideoWallTheme.textTertiary)
            }
            .padding(.horizontal, 14)

            sectionLabel("Display")

            HStack {
                Text("Show on all Spaces")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { settings.playOnAllSpaces },
                    set: { wallpaper.setPlayOnAllSpaces($0) }
                ))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: VideoWallTheme.gradA))
            }
            .padding(.horizontal, 14)

            Spacer(minLength: 8)
        }
        .animation(.easeInOut(duration: 0.18), value: settings.cycleEnabled)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.08)
            .foregroundColor(VideoWallTheme.textTertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }

    private func playbackModePicker() -> some View {
        let current = settings.playbackMode
        return HStack(spacing: 2) {
            ForEach(PlaybackMode.allCases, id: \.self) { mode in
                let on = current == mode
                Button {
                    wallpaper.setPlaybackMode(mode)
                } label: {
                    VStack(spacing: 2) {
                        Text(mode.label)
                            .font(.system(size: 12, weight: .semibold))
                        Text(mode.subtitle)
                            .font(.system(size: 9))
                            .opacity(on ? 0.85 : 0.55)
                    }
                    .foregroundColor(on ? .white : VideoWallTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(VideoWallTheme.brandGradient)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var blurValueLabel: String {
        let r = settings.cycleBlurRadius
        if r < 0.5 { return "Off" }
        if abs(r - 4.0) < 0.5 { return "Default" }
        return String(format: "%.0f", r)
    }

    private var crossfadeBlurCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Crossfade blur")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(blurValueLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(VideoWallTheme.gradB)
            }
            Slider(value: $settings.cycleBlurRadius, in: 0...32)
                .tint(VideoWallTheme.gradA)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(VideoWallTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(VideoWallTheme.hairline, lineWidth: 1)
                )
        )
    }
}
