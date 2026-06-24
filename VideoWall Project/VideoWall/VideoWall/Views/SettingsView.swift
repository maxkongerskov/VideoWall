import SwiftUI
import ServiceManagement
import AppKit

// MARK: - SettingsView
// Full settings panel opened as a floating NSWindow.

struct SettingsView: View {
    @EnvironmentObject var wallpaper: WallpaperManager
    @EnvironmentObject var library:   VideoLibraryManager
    @EnvironmentObject var settings:  AppSettings

    @State private var selectedSection: Section = .general

    enum Section: String, CaseIterable {
        case general = "General"
        case about   = "About"

        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .about:   return "person.fill"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // ── Sidebar ───────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundColor(.white.opacity(0.25))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)

                ForEach(Section.allCases, id: \.self) { section in
                    sidebarItem(section)
                }

                Spacer()
            }
            .padding(.top, 20)
            .frame(width: 150)
            .background(Color.white.opacity(0.03))

            Divider()

            // ── Content area ──────────────────────────────────────────────
            Group {
                switch selectedSection {
                case .general: GeneralSettingsView()
                case .about:   AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 480)
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func sidebarItem(_ section: Section) -> some View {
        let isSelected = selectedSection == section
        Button {
            withAnimation(.easeInOut(duration: 0.12)) { selectedSection = section }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .frame(width: 16)
                    .foregroundColor(isSelected ? .white : .white.opacity(0.45))

                Text(section.rawValue)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? Color.white.opacity(0.10) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}

// MARK: - GeneralSettingsView

struct GeneralSettingsView: View {
    @EnvironmentObject var settings:  AppSettings
    @EnvironmentObject var wallpaper: WallpaperManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                settingsTitle("Startup")

                settingsRow("Launch at Login",
                            icon: "arrow.up.circle.fill",
                            tint: .green) {
                    Toggle("", isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.launchAtLogin = $0
                            AppDelegate.shared?.applyLaunchAtLogin()
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle(tint: .purple))
                }

                divider()
                settingsTitle("Playback")

                settingsRow("Play on All Spaces",
                            icon: "rectangle.3.group.fill",
                            tint: .purple) {
                    Toggle("", isOn: Binding(
                        get: { settings.playOnAllSpaces },
                        set: { wallpaper.setPlayOnAllSpaces($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle(tint: .purple))
                }

                settingsRow("Pause on Battery",
                            icon: "battery.50",
                            tint: .orange) {
                    Toggle("", isOn: $settings.pauseOnBattery)
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: .purple))
                }

                settingsRow("Pause During Screen Recording",
                            icon: "record.circle",
                            tint: .red) {
                    Toggle("", isOn: $settings.pauseOnScreenRecording)
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: .purple))
                }

                if wallpaper.needsScreenRecordingPermission {
                    screenRecordingPermissionNote
                }

                divider()
                settingsTitle("Performance")

                settingsRow("Render Resolution",
                            icon: "rectangle.compress.vertical",
                            tint: .blue) {
                    Picker("", selection: Binding(
                        get: { settings.resolution },
                        set: { wallpaper.setResolution($0) }
                    )) {
                        ForEach(VideoResolution.allCases, id: \.self) { res in
                            Text(res.label).tag(res)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)
                }

                divider()
                settingsTitle("Debug")

                Button {
                    AppDelegate.shared?.showSplash()
                } label: {
                    Label("Replay Intro Animation", systemImage: "sparkles")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.65))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.top, 10)

                Spacer()
            }
            .padding(.vertical, 20)
        }
    }

    /// Shown when "Pause During Screen Recording" is on but the app lacks the
    /// Screen Recording permission required to detect captures.
    @ViewBuilder
    private var screenRecordingPermissionNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 6) {
                Text("Detecting screen recording needs Screen Recording permission — without it the wallpaper can't pause during captures.")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Grant Access…") {
                        wallpaper.requestScreenRecordingPermission()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.6))
                    .clipShape(Capsule())

                    Button("Open Settings") {
                        wallpaper.openScreenRecordingSettings()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.55))
                }
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func settingsTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundColor(.white.opacity(0.28))
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
            .padding(.top, 14)
    }

    @ViewBuilder
    private func settingsRow<T: View>(_ label: String,
                                       icon: String,
                                       tint: Color,
                                       @ViewBuilder control: () -> T) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.18))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(tint)
            }

            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.80))

            Spacer()

            control()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private func divider() -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.05))
            .frame(height: 1)
            .padding(.horizontal, 20)
            .padding(.top, 8)
    }
}

