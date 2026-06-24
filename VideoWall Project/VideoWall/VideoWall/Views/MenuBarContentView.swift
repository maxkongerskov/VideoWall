import SwiftUI
import AppKit

// MARK: - MenuBarContentView
// The full content of the menu-bar popover: header, now-playing, library, controls.

struct MenuBarContentView: View {
    @EnvironmentObject var wallpaper: WallpaperManager
    @EnvironmentObject var library:   VideoLibraryManager
    @EnvironmentObject var settings:  AppSettings

    @State private var selectedTab: Tab = .library

    private enum Tab: String, CaseIterable {
        case library  = "Library"
        case controls = "Controls"
    }

    /// Deep purple — classic 90s violet (#4B0082 / RGB ~102, 0, 153)
    private let deepPurple = Color(red: 0.40, green: 0.00, blue: 0.60)

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)

            VStack(spacing: 0) {

                // ── Header ──────────────────────────────────────────────────
                HStack(spacing: 8) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(colors: [deepPurple, Color(red: 0.60, green: 0.00, blue: 0.80)],
                                           startPoint: .topLeading,
                                           endPoint: .bottomTrailing)
                        )

                    Text("VideoWall")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    // Settings gear
                    Button {
                        AppDelegate.shared?.openSettings()
                    } label: {
                        Image(systemName: "gear")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help("Open Settings")

                    // Quit
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Image(systemName: "power")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.30))
                    }
                    .buttonStyle(.plain)
                    .help("Quit VideoWall")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                ThinDivider()

                // ── Now Playing ──────────────────────────────────────────────
                if wallpaper.currentVideo != nil {
                    NowPlayingView()
                    ThinDivider()
                }

                // ── Tab Picker ───────────────────────────────────────────────
                HStack(spacing: 0) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedTab = tab
                            }
                        } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                                .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.38))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(
                    GeometryReader { geo in
                        let w   = geo.size.width / CGFloat(Tab.allCases.count)
                        let idx = CGFloat(Tab.allCases.firstIndex(of: selectedTab) ?? 0)
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: w - 8, height: 22)
                            .offset(x: idx * w + 4,
                                    y: (geo.size.height - 22) / 2)
                            .animation(.spring(response: 0.25, dampingFraction: 0.75),
                                       value: selectedTab)
                    }
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 4)

                ThinDivider()

                // ── Tab Content ──────────────────────────────────────────────
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
        .frame(width: 380, height: 540)
        .preferredColorScheme(.dark)
    }
}

// MARK: - ControlsView
// Loop, trim — shown in the "Controls" tab.

struct ControlsView: View {
    @EnvironmentObject var wallpaper: WallpaperManager
    @EnvironmentObject var settings:  AppSettings

    /// Deep purple — classic 90s violet (#4B0082 / RGB ~102, 0, 153)
    private let deepPurple = Color(red: 0.40, green: 0.00, blue: 0.60)

    /// Clip duration in HH:MM:SS (or MM:SS when under an hour), live as sliders move.
    private var clipDurationString: String {
        let total   = wallpaper.currentVideo?.duration ?? 0
        let clipped = total * max(0, settings.trimEnd - settings.trimStart)
        return formatDuration(clipped)
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%02d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {

                // Playback mode — exactly one of Loop / Cycle is always active.
                controlSection(title: "Playback") {
                    VStack(spacing: 10) {
                        playbackModePicker()

                        // Blur intensity (only meaningful during cycle)
                        blurIntensityRow()
                    }
                }

                ThinDivider()

                // Trim — custom section with centred duration meter in the header
                VStack(alignment: .leading, spacing: 8) {
                    ZStack {
                        // Left: section label
                        HStack {
                            Text("Clip Trim")
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.8)
                                .foregroundColor(.white.opacity(0.30))
                                .textCase(.uppercase)
                            Spacer()
                        }

                        // Centre: live clip duration
                        Text(clipDurationString)
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundColor(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    // Clamped bindings: Start can't reach End, End can't drop to Start.
                    trimRow(label: "Start", value: Binding(
                        get: { settings.trimStart },
                        set: { settings.trimStart = min($0, settings.trimEnd - 0.05) }
                    ))
                    trimRow(label: "End", value: Binding(
                        get: { settings.trimEnd },
                        set: { settings.trimEnd = max($0, settings.trimStart + 0.05) }
                    ))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                ThinDivider()

                // All Spaces
                controlSection(title: "Display") {
                    HStack(spacing: 12) {
                        Text("Show on all Spaces")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.75))
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { settings.playOnAllSpaces },
                            set: { wallpaper.setPlayOnAllSpaces($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: deepPurple))
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    // MARK: Playback mode picker (Loop / Cycle — mutually exclusive)

    @ViewBuilder
    private func playbackModePicker() -> some View {
        let current = settings.playbackMode

        HStack(spacing: 0) {
            ForEach(PlaybackMode.allCases, id: \.self) { mode in
                let isSelected = current == mode
                Button {
                    wallpaper.setPlaybackMode(mode)
                } label: {
                    VStack(spacing: 2) {
                        Text(mode.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(isSelected ? .white : .white.opacity(0.50))
                        Text(mode.subtitle)
                            .font(.system(size: 9))
                            .foregroundColor(isSelected ? .white.opacity(0.70)
                                                        : .white.opacity(0.28))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected
                                  ? LinearGradient(
                                        colors: [deepPurple,
                                                 Color(red: 0.60, green: 0.00, blue: 0.80)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing)
                                  : LinearGradient(
                                        colors: [Color.clear, Color.clear],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.15), value: isSelected)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func controlSection<Content: View>(title: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(.white.opacity(0.30))
                .textCase(.uppercase)

            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func trimRow(label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.50))
                .frame(width: 36, alignment: .leading)

            Slider(value: value, in: 0...1)
                .tint(deepPurple)

            Text(String(format: "%.0f%%", value.wrappedValue * 100))
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.white.opacity(0.35))
                .frame(width: 32, alignment: .trailing)
        }
    }

    // MARK: Blur intensity slider

    /// Human-readable label for the current blur radius.
    private var blurValueLabel: String {
        let r = settings.cycleBlurRadius
        if r < 0.5             { return "Off" }
        if abs(r - 4.0) < 0.5  { return "Default" }
        return String(format: "%.0f", r)
    }

    @ViewBuilder
    private func blurIntensityRow() -> some View {
        let minBlur: Double  = 0
        let maxBlur: Double  = 32
        let defBlur: Double  = 4            // "recommended" position
        let isActive: Bool   = settings.cycleEnabled
        let valueLabel       = blurValueLabel

        VStack(alignment: .leading, spacing: 2) {
            // Header
            HStack {
                Text("Blur Intensity")
                    .font(.system(size: 12))
                    .foregroundColor(isActive ? .white.opacity(0.75) : .white.opacity(0.25))
                Spacer()
                Text(valueLabel)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(
                        abs(settings.cycleBlurRadius - defBlur) < 0.5
                            ? deepPurple.opacity(isActive ? 0.85 : 0.35)
                            : .white.opacity(isActive ? 0.40 : 0.18)
                    )
            }

            // Slider + recommended marker overlay
            ZStack(alignment: .topLeading) {
                Slider(value: $settings.cycleBlurRadius, in: minBlur...maxBlur)
                    .tint(isActive ? deepPurple : deepPurple.opacity(0.45))

                // Recommended marker — positioned at defBlur/maxBlur of the track
                GeometryReader { geo in
                    let thumbInset: CGFloat = 9          // empirical macOS slider inset
                    let trackW = geo.size.width - thumbInset * 2
                    let fraction = CGFloat((defBlur - minBlur) / (maxBlur - minBlur))
                    let markerX = thumbInset + trackW * fraction

                    VStack(spacing: 1) {
                        Rectangle()
                            .fill(Color.white.opacity(isActive ? 0.45 : 0.20))
                            .frame(width: 1.5, height: 10)
                        Text("Rec.")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundColor(.white.opacity(isActive ? 0.35 : 0.15))
                    }
                    // Sit just below the slider track centre (~10 pt from top)
                    .offset(x: markerX - 0.75, y: 12)
                }
                .frame(height: 38)
                .allowsHitTesting(false)
            }

            // Min / max edge labels
            HStack {
                Text("Off")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(isActive ? 0.22 : 0.10))
                Spacer()
                Text("Heavy")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(isActive ? 0.22 : 0.10))
            }
            .padding(.top, 14)   // push below the marker
        }
        .padding(.top, 6)
    }
}
