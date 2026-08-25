import SwiftUI
import AppKit

// MARK: - NowPlayingView
// Soft surface card under the header when a wallpaper is active.

struct NowPlayingView: View {
    @EnvironmentObject var wallpaper: WallpaperManager
    @EnvironmentObject var settings:  AppSettings

    var body: some View {
        if let video = wallpaper.currentVideo {
            content(for: video)
        }
    }

    @ViewBuilder
    private func content(for video: VideoItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
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
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(video.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(VideoWallTheme.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(wallpaper.isPlaying
                                  ? VideoWallTheme.brandGradientHorizontal
                                  : LinearGradient(colors: [.gray], startPoint: .leading, endPoint: .trailing))
                            .frame(width: 5, height: 5)
                            .shadow(color: wallpaper.isPlaying ? VideoWallTheme.gradB.opacity(0.7) : .clear,
                                    radius: 3)

                        Text(wallpaper.isPlaying ? "Playing" : "Paused")
                            .font(.system(size: 10.5))
                            .foregroundColor(VideoWallTheme.textSecondary)

                        Text("·")
                            .foregroundColor(VideoWallTheme.textTertiary)

                        Text(video.durationString)
                            .font(.system(size: 10.5))
                            .foregroundColor(VideoWallTheme.textSecondary)
                    }
                }

                Spacer(minLength: 0)

                Button(action: wallpaper.togglePlayPause) {
                    Image(systemName: wallpaper.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(VideoWallTheme.surfaceRaised)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Button(action: wallpaper.toggleMute) {
                    Image(systemName: settings.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11))
                        .foregroundColor(VideoWallTheme.textSecondary)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)

                Slider(value: Binding(
                    get: { Double(settings.volume) },
                    set: { wallpaper.setVolume(Float($0)) }
                ), in: 0...1)
                .tint(settings.isMuted ? VideoWallTheme.gradA.opacity(0.45) : VideoWallTheme.gradA)

                Text("\(Int(settings.volume * 100))%")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundColor(VideoWallTheme.textTertiary)
                    .frame(width: 28, alignment: .trailing)
            }
            .padding(.top, 8)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(VideoWallTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(VideoWallTheme.hairline, lineWidth: 1)
                )
        )
    }
}
