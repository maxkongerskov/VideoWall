import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var wallpaper: WallpaperManager
    @EnvironmentObject var library: VideoLibraryManager
    @EnvironmentObject var settings: AppSettings

    @State private var isImportingFile = false
    @State private var isDroppingOver = false
    @State private var showDeleteAllAlert = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private let deepPurple = Color(red: 0.40, green: 0.00, blue: 0.60)

    var body: some View {
        ZStack {
            scrollContent

            dropOverlay
        }
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            handleImport(result: result)
        }
        .confirmationDialog(
            "Clear entire video library?",
            isPresented: $showDeleteAllAlert,
            titleVisibility: .visible
        ) {
            Button("Delete All Videos", role: .destructive) {
                wallpaper.stop()
                library.deleteAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all \(library.videos.count) video files from disk.")
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

    private var scrollContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                if library.videos.isEmpty {
                    emptyState
                        .padding(.vertical, 32)
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
                    .padding(12)

                    // Bottom action row: reveal-in-Finder + add
                    HStack(spacing: 14) {
                        Spacer()

                        // Reveal library folder in Finder. Drag/drop into the
                        // folder also imports — VideoLibraryManager watches the
                        // directory for new files.
                        Button {
                            NSWorkspace.shared.open(library.libraryFolderURL)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.08))
                                    .frame(width: 36, height: 36)

                                Image(systemName: "folder.fill")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.65))
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Reveal Library Folder in Finder")

                        // Add via file picker
                        Button(action: { isImportingFile = true }) {
                            ZStack {
                                Circle()
                                    .fill(deepPurple.opacity(0.25))
                                    .frame(width: 44, height: 44)

                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Add Videos")

                        Spacer()
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDroppingOver, perform: handleDrop)
    }

    private var dropOverlay: some View {
        Rectangle()
            .stroke(Color.purple.opacity(isDroppingOver ? 0.6 : 0), lineWidth: 2)
            .animation(.easeInOut(duration: 0.15), value: isDroppingOver)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(.white.opacity(0.18))

            Text("No Videos Yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))

            Text("Drag a video here or tap Import")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))

            Button(action: { isImportingFile = true }) {
                Label("Import Video", systemImage: "plus.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
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
                library.importVideo(from: url)
            }
        }
    }
}
