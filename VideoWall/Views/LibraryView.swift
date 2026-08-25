import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - LibraryView
//
// Three ways to add videos:
// 1. **Folder** — opens VideoWall’s on-disk library directory in Finder
//    (drop files there; the directory watcher imports them).
// 2. **Import** — system file picker (Finder open panel).
// 3. **Drag & drop** — drop video files onto this Library tab / popover area.

struct LibraryView: View {
    @EnvironmentObject var wallpaper: WallpaperManager
    @EnvironmentObject var library: VideoLibraryManager
    @EnvironmentObject var settings: AppSettings

    @State private var isImportingFile = false
    @State private var isDroppingOver = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                libraryToolbar
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                ZStack {
                    scrollContent
                    dropOverlay
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if library.isImporting {
                importingBanner
            }
        }
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            handleImport(result: result)
        }
        .alert(
            "Import Failed",
            isPresented: Binding(
                get: { library.importError != nil },
                set: { if !$0 { library.importError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { library.importError = nil }
        } message: {
            Text(library.importError ?? "")
        }
    }

    // MARK: - Toolbar (Folder + Import always visible)

    private var libraryToolbar: some View {
        HStack(spacing: 8) {
            if !library.videos.isEmpty {
                Text("\(library.videos.count) video\(library.videos.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
            }

            Spacer(minLength: 0)

            Button(action: openLibraryFolder) {
                Label("Folder", systemImage: "folder.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(VideoWallTheme.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Open VideoWall library folder in Finder")

            Button(action: { isImportingFile = true }) {
                Label("Import", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(VideoWallTheme.brandGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Import videos from Finder")
        }
    }

    private var importingBanner: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.85)
                Text("Importing…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 12)
        }
        .allowsHitTesting(false)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeOut(duration: 0.2), value: library.isImporting)
    }

    // MARK: - Content

    private var scrollContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                if library.videos.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 28)
                        .padding(.bottom, 24)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(library.videos) { video in
                            VideoCard(
                                video: video,
                                isSelected: wallpaper.currentVideo?.id == video.id,
                                onPlay: { wallpaper.play(video: video) },
                                onDelete: { library.delete(video: video) }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDroppingOver, perform: handleDrop)
    }

    /// Highlight while dragging files onto the Library surface.
    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                isDroppingOver ? VideoWallTheme.brandGradient : LinearGradient(colors: [.clear], startPoint: .leading, endPoint: .trailing),
                lineWidth: isDroppingOver ? 2.5 : 0
            )
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(VideoWallTheme.gradB.opacity(isDroppingOver ? 0.12 : 0))
            )
            .padding(6)
            .animation(.easeInOut(duration: 0.15), value: isDroppingOver)
            .allowsHitTesting(false)
            .overlay {
                if isDroppingOver {
                    VStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 26, weight: .medium))
                        Text("Drop to import")
                            .font(.system(size: 12, weight: .semibold))
                        Text("mp4, mov, m4v, …")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.55))
                    }
                    .foregroundColor(.white.opacity(0.92))
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(VideoWallTheme.gradB.opacity(0.35), lineWidth: 1)
                    )
                    .allowsHitTesting(false)
                }
            }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(VideoWallTheme.gradB.opacity(0.18))
                    .frame(width: 56, height: 56)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(VideoWallTheme.gradB.opacity(0.25), lineWidth: 1)
                    )
                Image(systemName: "film.stack")
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(.white.opacity(0.75))
            }

            Text("No videos yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(VideoWallTheme.textPrimary)

            Text("Import from Finder, open the library folder,\nor drag a video into this window.")
                .font(.system(size: 11))
                .foregroundColor(VideoWallTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 20)

            HStack(spacing: 10) {
                Button(action: openLibraryFolder) {
                    Label("Folder", systemImage: "folder.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(VideoWallTheme.surfaceRaised)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Open VideoWall library folder in Finder")

                Button(action: { isImportingFile = true }) {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(VideoWallTheme.brandGradient)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Import videos from Finder")
            }
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 5) {
                emptyWay(num: "1", title: "Folder", detail: "open the real library directory")
                emptyWay(num: "2", title: "Import", detail: "pick files in Finder")
                emptyWay(num: "3", title: "Drag", detail: "drop a video on this popover")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private func emptyWay(num: String, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(num).")
                .foregroundColor(VideoWallTheme.textTertiary)
            Text(title)
                .fontWeight(.semibold)
                .foregroundColor(VideoWallTheme.textSecondary)
            Text("— \(detail)")
                .foregroundColor(VideoWallTheme.textTertiary)
        }
        .font(.system(size: 10.5))
    }

    // MARK: - Actions

    /// Reveal the on-disk library directory (Application Support/VideoWall/Library).
    private func openLibraryFolder() {
        let url = library.libraryFolderURL
        // Ensure the folder exists before opening (manager creates it on init).
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private var supportedTypes: [UTType] {
        [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let directURL = item as? URL {
                    url = directURL
                } else {
                    return
                }

                guard let validURL = url else { return }
                let ext = validURL.pathExtension.lowercased()
                guard VideoItem.supportedExtensions.contains(ext) else { return }

                Task { @MainActor in
                    self.library.importVideo(from: validURL)
                }
            }
        }
        return true
    }

    private func handleImport(result: Result<[URL], Error>) {
        if case .success(let urls) = result {
            for url in urls {
                // fileImporter URLs are security-scoped; importVideo starts access.
                library.importVideo(from: url)
            }
        }
    }
}
