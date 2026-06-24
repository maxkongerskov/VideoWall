import Foundation
import AppKit
import AVFoundation

// MARK: - VideoLibraryManager

@MainActor
final class VideoLibraryManager: ObservableObject {

    @Published var videos: [VideoItem] = []
    @Published var isImporting: Bool = false

    /// Set with a user-facing message when an import fails; the UI observes it
    /// to present an alert, then clears it.
    @Published var importError: String?

    /// Counts how many concurrent import tasks are running.
    /// `isImporting` stays true while this is > 0.
    private var activeImports: Int = 0

    /// Destination filenames currently being imported. The directory watcher
    /// skips these so it doesn't re-import a file the app itself is copying in.
    private var importingFilenames: Set<String> = []

    private let libraryDir: URL
    private let metadataURL: URL

    /// DispatchSource watching libraryDir for file additions made outside the app.
    private var dirWatchSource: DispatchSourceFileSystemObject?

    // MARK: Init

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        libraryDir  = appSupport.appendingPathComponent("VideoWall/Library", isDirectory: true)
        metadataURL = appSupport.appendingPathComponent("VideoWall/metadata.json")

        try? FileManager.default.createDirectory(at: libraryDir,
                                                 withIntermediateDirectories: true)
        loadMetadata()
        startWatchingLibraryDirectory()
    }

    /// Call this before releasing the manager (e.g., on app termination)
    /// to cancel the directory watcher. Swift 6 deinit cannot touch
    /// non-Sendable stored properties from an @MainActor class.
    func stopWatching() {
        dirWatchSource?.cancel()
        dirWatchSource = nil
    }

    // MARK: Public API

    func url(for video: VideoItem) -> URL {
        libraryDir.appendingPathComponent(video.filename)
    }

    func importVideo(from sourceURL: URL) {
        activeImports += 1
        isImporting = true

        Task { @MainActor [weak self] in
            guard let self else {
                // Ensure we don't leave the counter stuck if self vanished.
                return
            }
            defer {
                self.activeImports -= 1
                self.isImporting = self.activeImports > 0
            }

            // Reserve the destination filename (synchronously, before any await)
            // so a concurrent import and the directory watcher both see it taken.
            let dest     = self.uniqueDestURL(for: sourceURL.lastPathComponent)
            let destName = dest.lastPathComponent
            self.importingFilenames.insert(destName)
            defer { self.importingFilenames.remove(destName) }

            // Copy off the main thread — video files can be gigabytes and a
            // synchronous copy here would freeze the whole UI.
            let copyError: String? = await Task.detached(priority: .userInitiated) {
                let didAccess = sourceURL.startAccessingSecurityScopedResource()
                defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
                do {
                    try FileManager.default.copyItem(at: sourceURL, to: dest)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value

            if let copyError {
                print("[Library] Copy failed: \(copyError)")
                self.importError = "Couldn't import “\(sourceURL.lastPathComponent)”: \(copyError)"
                return
            }

            // Generate thumbnail + duration concurrently
            async let thumb    = self.generateThumbnail(for: dest)
            async let duration = self.videoDuration(for: dest)

            let (thumbImage, dur) = await (thumb, duration)

            var item = VideoItem(
                id: UUID(),
                name: sourceURL.deletingPathExtension().lastPathComponent,
                filename: destName,
                duration: dur,
                thumbnailData: nil
            )
            item.thumbnailData = thumbImage.flatMap { Self.encodeThumbnail($0) }

            self.videos.append(item)
            self.saveMetadata()
        }
    }

    func delete(video: VideoItem) {
        let fileURL = url(for: video)
        try? FileManager.default.removeItem(at: fileURL)
        videos.removeAll { $0.id == video.id }
        VideoItem.evictThumbnail(id: video.id)
        saveMetadata()
    }

    func rename(video: VideoItem, to newName: String) {
        guard let idx = videos.firstIndex(of: video) else { return }
        videos[idx].name = newName
        saveMetadata()
    }

    /// Deletes every video file and clears the library completely.
    func deleteAll() {
        for video in videos {
            try? FileManager.default.removeItem(at: url(for: video))
            VideoItem.evictThumbnail(id: video.id)
        }
        videos.removeAll()
        try? FileManager.default.removeItem(at: metadataURL)
    }

    /// The URL of the library folder on disk (for "Open in Finder").
    var libraryFolderURL: URL { libraryDir }

    // MARK: Private helpers

    private func uniqueDestURL(for filename: String) -> URL {
        var dest = libraryDir.appendingPathComponent(filename)
        var counter = 1
        let base = (filename as NSString).deletingPathExtension
        let ext  = (filename as NSString).pathExtension

        // Avoid both on-disk files and names reserved by an in-flight import.
        while FileManager.default.fileExists(atPath: dest.path)
                || importingFilenames.contains(dest.lastPathComponent) {
            dest = libraryDir.appendingPathComponent("\(base)_\(counter).\(ext)")
            counter += 1
        }
        return dest
    }

    /// Encodes a thumbnail as JPEG. Far smaller than TIFF, which keeps
    /// metadata.json and in-memory `videos` from ballooning on large libraries.
    private static func encodeThumbnail(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    private func generateThumbnail(for url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let gen   = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 270)

        do {
            // Try 1s in; for very short clips the generator will error and we simply return nil.
            let (cgImage, _) = try await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600))
            return NSImage(cgImage: cgImage, size: NSSize(width: 480, height: 270))
        } catch {
            return nil
        }
    }

    private func videoDuration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            return duration.seconds.isNaN ? 0 : duration.seconds
        } catch {
            return 0
        }
    }

    // MARK: Private – directory watcher (Finder drag-in support)

    private func startWatchingLibraryDirectory() {
        let fd = open(libraryDir.path, O_EVTONLY)
        guard fd >= 0 else {
            print("[Library] Could not open directory fd for watching")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask:      .write,
            queue:          .main
        )

        source.setEventHandler { [weak self] in
            // Debounce: small delay lets multi-file copies finish before we scan.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.syncNewFilesFromDisk()
                }
            }
        }

        source.setCancelHandler { close(fd) }
        source.resume()
        dirWatchSource = source
    }

    /// Scans libraryDir for video files not yet tracked in `videos`.
    private func syncNewFilesFromDisk() async {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at:                         libraryDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options:                    .skipsHiddenFiles
        ) else { return }

        let knownFilenames = Set(videos.map { $0.filename })

        var addedAny = false
        for fileURL in contents {
            let filename = fileURL.lastPathComponent
            let ext      = fileURL.pathExtension.lowercased()

            guard !knownFilenames.contains(filename) else { continue }
            // Skip files an in-app import is still copying/processing.
            guard !importingFilenames.contains(filename) else { continue }
            guard VideoItem.supportedExtensions.contains(ext) else { continue }
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }

            async let thumb    = generateThumbnail(for: fileURL)
            async let duration = videoDuration(for: fileURL)
            let (thumbImage, dur) = await (thumb, duration)

            var item = VideoItem(
                id:            UUID(),
                name:          fileURL.deletingPathExtension().lastPathComponent,
                filename:      filename,
                duration:      dur,
                thumbnailData: nil
            )
            item.thumbnailData = thumbImage.flatMap { Self.encodeThumbnail($0) }

            videos.append(item)
            addedAny = true
        }

        if addedAny { saveMetadata() }
    }

    // MARK: Persistence

    private func loadMetadata() {
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([VideoItem].self, from: data)
        else { return }

        videos = decoded.filter {
            FileManager.default.fileExists(atPath: url(for: $0).path)
        }
    }

    private func saveMetadata() {
        guard let data = try? JSONEncoder().encode(videos) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }
}

