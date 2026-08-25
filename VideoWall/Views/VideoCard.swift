import SwiftUI

// MARK: - VideoCard
// Thumbnail card in the library grid.

struct VideoCard: View {
    let video: VideoItem
    let isSelected: Bool
    let onPlay:   () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var showDeleteConfirm = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let thumb = video.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .aspectRatio(16/9, contentMode: .fit)
                        .overlay(
                            Image(systemName: "film")
                                .font(.system(size: 24))
                                .foregroundColor(.white.opacity(0.2))
                        )
                }
            }
            .clipped()

            if isHovered {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(0.7), Color.clear],
                            startPoint: .bottom,
                            endPoint: .center
                        )
                    )
            }

            if isSelected {
                VStack {
                    HStack {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(VideoWallTheme.gradB)
                                .frame(width: 5, height: 5)
                                .shadow(color: VideoWallTheme.gradB.opacity(0.8), radius: 3)
                            Text("LIVE")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.06)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Spacer()
                    }
                    .padding(7)
                    Spacer()
                }
            }

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(video.durationString)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.55))
                }

                Spacer()

                if isHovered {
                    HStack(spacing: 6) {
                        Button { showDeleteConfirm = true } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.75))
                                .padding(5)
                                .background(Color.white.opacity(0.12))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Delete")

                        Button(action: onPlay) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
                                .padding(5)
                                .background(VideoWallTheme.brandGradient)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Set as wallpaper")
                    }
                }
            }
            .padding(8)
            .opacity(isHovered ? 1 : 0.85)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected
                        ? VideoWallTheme.brandGradient
                        : LinearGradient(colors: [Color.white.opacity(0.08)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onPlay)
        .confirmationDialog(
            "Delete \"\(video.name)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The video file will be removed from your VideoWall library.")
        }
    }
}
