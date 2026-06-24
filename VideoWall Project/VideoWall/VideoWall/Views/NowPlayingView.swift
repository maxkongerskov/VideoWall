import SwiftUI
import AppKit

// MARK: - NowPlayingView
// Compact card shown at the top of the popover when a video is active.

struct NowPlayingView: View {
    @EnvironmentObject var wallpaper: WallpaperManager
    @EnvironmentObject var settings:  AppSettings

    /// Deep purple — classic 90s violet (#4B0082 / RGB ~102, 0, 153)
    private let deepPurple = Color(red: 0.40, green: 0.00, blue: 0.60)

    var body: some View {
        if let video = wallpaper.currentVideo {
            content(for: video)
        } else {
            EmptyView()
        }
    }


    @ViewBuilder
    private func content(for video: VideoItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Thumbnail
                ZStack {
                    if let thumb = video.thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(16/9, contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                            .overlay(
                                Image(systemName: "play.rectangle")
                                    .foregroundColor(.white.opacity(0.3))
                            )
                    }
                }
                .frame(width: 72, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

                // Info
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(wallpaper.isPlaying
                                  ? LinearGradient(colors: [deepPurple, Color(red: 0.60, green: 0.00, blue: 0.80)], startPoint: .leading, endPoint: .trailing)
                                  : LinearGradient(colors: [Color.gray], startPoint: .leading, endPoint: .trailing))
                            .frame(width: 5, height: 5)

                        Text(wallpaper.isPlaying ? "Playing" : "Paused")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.45))

                        Text("·")
                            .foregroundColor(.white.opacity(0.25))

                        Text(video.durationString)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.45))
                    }
                }

                Spacer()

                // Play / Pause toggle
                Button(action: wallpaper.togglePlayPause) {
                    Image(systemName: wallpaper.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.10))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            ThinDivider()

            // Volume row
            HStack(spacing: 10) {
                Button(action: wallpaper.toggleMute) {
                    Image(systemName: settings.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 18)
                }
                .buttonStyle(.plain)

                Slider(value: Binding(
                    get: { Double(settings.volume) },
                    set: { wallpaper.setVolume(Float($0)) }
                ), in: 0...1)
                .tint(!settings.isMuted ? deepPurple : deepPurple.opacity(0.45))

                Text("\(Int(settings.volume * 100))%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.40))
                    .frame(width: 28, alignment: .trailing)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}
