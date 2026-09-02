import AppKit
import AVFoundation
import Foundation

// MARK: - AerialsInjector
//
// 1.1.0 registered the current wallpaper video as a custom macOS aerial under
// ~/Library/Application Support/com.apple.wallpaper/ so WallpaperAgent could
// play it on the lock screen. That is another app's folder and a Files &
// Folders prompt on every launch after Don't Allow.
//
// Production I/O now stays inside VideoWall's own Application Support.
// Desktop / lock / screensaver playback uses VideoWall's overlay windows.
// `touchesSystem: false` keeps all I/O inside the supplied directories (tests).

final class AerialsInjector: Sendable {

    let touchesSystem: Bool
    let aerialsRoot: URL
    let storeURL: URL
    let backupURL: URL
    let assetIDURL: URL

    private let categoryID    = "VW000000-0000-4000-8000-000000000001"
    private let subcategoryID = "VW000000-0000-4000-8000-000000000002"

    init(
        touchesSystem: Bool = true,
        aerialsRoot: URL? = nil,
        storeURL: URL? = nil,
        supportDir: URL? = nil
    ) {
        self.touchesSystem = touchesSystem
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let support = supportDir
            ?? appSupport.appendingPathComponent("VideoWall", isDirectory: true)
        // Never default into Apple's wallpaper store or another app's container.
        self.aerialsRoot = aerialsRoot
            ?? support.appendingPathComponent("aerials", isDirectory: true)
        self.storeURL = storeURL
            ?? support.appendingPathComponent("Store/Index.plist")
        self.backupURL = support.appendingPathComponent("wallpaper-store-backup.plist")
        self.assetIDURL = support.appendingPathComponent("aerials-asset-id")
    }

    private var videosDir: URL { aerialsRoot.appendingPathComponent("videos", isDirectory: true) }
    private var thumbsDir: URL { aerialsRoot.appendingPathComponent("thumbnails", isDirectory: true) }
    private var entriesURL: URL {
        aerialsRoot.appendingPathComponent("manifest/entries.json")
    }

    // MARK: Install / uninstall

    /// Copies `videoURL` into the aerials catalog and points the wallpaper
    /// store at it. Returns false if the catalog or store could not be written.
    @discardableResult
    func install(videoURL: URL, displayName: String) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: videosDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(
            at: entriesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fm.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let assetID = resolvedAssetID()
        let ext = videoURL.pathExtension.isEmpty ? "mov" : videoURL.pathExtension.lowercased()
        let dest = videosDir.appendingPathComponent("\(assetID).\(ext)")
        let videoChanged = copyVideoIfNeeded(from: videoURL, to: dest)
        guard fm.fileExists(atPath: dest.path) else { return false }

        let thumb = thumbsDir.appendingPathComponent("\(assetID).png")
        if videoChanged || !fm.fileExists(atPath: thumb.path) {
            generateThumbnail(from: videoURL, to: thumb)
        }

        backupStoreIfNeeded()

        guard updateEntriesJSON(
            assetID: assetID,
            videoName: displayName,
            videoURL: dest,
            thumbURL: thumb
        ) else { return false }

        guard updateWallpaperStore(assetID: assetID) else { return false }

        persistAssetID(assetID)

        if touchesSystem && videoChanged && Self.isForeignWallpaperLocation(storeURL) {
            restartWallpaperAgent()
        }
        return true
    }

    /// True when a previous injection left VideoWall-owned markers.
    var hasLocalInstallMarker: Bool {
        FileManager.default.fileExists(atPath: backupURL.path) || storedAssetID() != nil
    }

    /// Cleans a prior injection. Skips Apple / other-app folders so launch
    /// never triggers a Files & Folders prompt; retires local markers either way
    /// so the attempt is one-shot.
    func uninstallIfPreviouslyInstalled() {
        guard hasLocalInstallMarker else { return }
        uninstall()
    }

    func uninstall() {
        if Self.isForeignWallpaperLocation(aerialsRoot)
            || Self.isForeignWallpaperLocation(storeURL) {
            clearLocalInstallMarkers()
            return
        }

        removeFromEntriesJSON()
        if let id = storedAssetID() {
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: videosDir, includingPropertiesForKeys: nil) {
                for url in files where url.deletingPathExtension().lastPathComponent == id {
                    try? fm.removeItem(at: url)
                }
            }
            try? fm.removeItem(at: thumbsDir.appendingPathComponent("\(id).png"))
        }
        restoreStoreBackup()
        clearLocalInstallMarkers()
        // Do not bounce WallpaperAgent: we no longer mutate Apple's store.
    }

    func clearLocalInstallMarkers() {
        let fm = FileManager.default
        try? fm.removeItem(at: backupURL)
        try? fm.removeItem(at: assetIDURL)
    }

    /// Apple's wallpaper store and other apps' containers are TCC-protected.
    static func isForeignWallpaperLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path.contains("/com.apple.wallpaper/") || path.hasSuffix("/com.apple.wallpaper") {
            return true
        }
        if path.contains("/Library/Containers/") {
            return true
        }
        return false
    }

    /// True when the catalog file and the copied video are present.
    func isHealthy() -> Bool {
        guard let id = storedAssetID() else { return false }
        let fm = FileManager.default
        guard fm.fileExists(atPath: entriesURL.path) else { return false }
        guard let files = try? fm.contentsOfDirectory(at: videosDir, includingPropertiesForKeys: nil)
        else { return false }
        return files.contains { $0.deletingPathExtension().lastPathComponent == id }
    }

    // MARK: Video copy

    private func copyVideoIfNeeded(from source: URL, to dest: URL) -> Bool {
        let fm = FileManager.default
        let srcSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        let dstSize = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
        if srcSize == dstSize, srcSize > 0, fm.fileExists(atPath: dest.path) {
            return false
        }
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: source, to: dest)
            return true
        } catch {
            NSLog("[VideoWall] Aerials copy failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: entries.json

    private func updateEntriesJSON(
        assetID: String,
        videoName: String,
        videoURL: URL,
        thumbURL: URL
    ) -> Bool {
        var entries: [String: Any]
        if let data = try? Data(contentsOf: entriesURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            entries = parsed
        } else {
            entries = ["version": 1, "categories": [] as [Any], "assets": [] as [Any]]
        }

        var categories = entries["categories"] as? [[String: Any]] ?? []
        var assets = entries["assets"] as? [[String: Any]] ?? []

        let thumbFile = thumbURL.absoluteString
        let videoFile = videoURL.absoluteString

        let categoryEntry: [String: Any] = [
            "id": categoryID,
            "localizedNameKey": "VideoWall",
            "localizedDescriptionKey": "VideoWall live wallpaper",
            "preferredOrder": 999,
            "representativeAssetID": assetID,
            "previewImage": thumbFile,
            "subcategories": [[
                "id": subcategoryID,
                "localizedNameKey": "VideoWall",
                "localizedDescriptionKey": "VideoWall live wallpaper",
                "preferredOrder": 0,
                "previewImage": thumbFile,
                "representativeAssetID": assetID
            ]]
        ]

        if let idx = categories.firstIndex(where: { ($0["id"] as? String) == categoryID }) {
            categories[idx] = categoryEntry
        } else {
            categories.append(categoryEntry)
        }

        let assetEntry: [String: Any] = [
            "id": assetID,
            "localizedNameKey": videoName,
            "accessibilityLabel": videoName,
            "shotID": "VIDEOWALL_CUSTOM",
            "showInTopLevel": true,
            "includeInShuffle": true,
            "preferredOrder": 0,
            "categories": [categoryID],
            "subcategories": [subcategoryID],
            "url-4K-SDR-240FPS": videoFile,
            "previewImage": thumbFile,
            "pointsOfInterest": ["0": "VIDEOWALL_0"]
        ]

        assets.removeAll { asset in
            (asset["categories"] as? [String])?.contains(categoryID) == true
        }
        assets.append(assetEntry)

        entries["categories"] = categories
        entries["assets"] = assets

        do {
            let json = try JSONSerialization.data(
                withJSONObject: entries,
                options: [.prettyPrinted, .sortedKeys]
            )
            let tmp = entriesURL.appendingPathExtension("tmp")
            try json.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(entriesURL, withItemAt: tmp)
            return true
        } catch {
            NSLog("[VideoWall] Aerials entries.json failed: \(error.localizedDescription)")
            return false
        }
    }

    private func removeFromEntriesJSON() {
        guard let data = try? Data(contentsOf: entriesURL),
              var entries = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if var categories = entries["categories"] as? [[String: Any]] {
            categories.removeAll { ($0["id"] as? String) == categoryID }
            entries["categories"] = categories
        }
        if var assets = entries["assets"] as? [[String: Any]] {
            assets.removeAll { ($0["categories"] as? [String])?.contains(categoryID) == true }
            entries["assets"] = assets
        }
        if let json = try? JSONSerialization.data(
            withJSONObject: entries,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? json.write(to: entriesURL)
        }
    }

    // MARK: Store / Index.plist

    private func updateWallpaperStore(assetID: String) -> Bool {
        let configDict = ["assetID": assetID]
        guard let configData = try? PropertyListSerialization.data(
            fromPropertyList: configDict, format: .binary, options: 0
        ) else { return false }

        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var store: [String: Any]
        if let data = try? Data(contentsOf: storeURL),
           let parsed = try? PropertyListSerialization.propertyList(
               from: data, options: .mutableContainersAndLeaves, format: nil
           ) as? [String: Any] {
            store = parsed
        } else {
            store = [:]
        }

        let choice: [String: Any] = [
            "Provider": "com.apple.wallpaper.choice.aerials",
            "Files": [] as [Any],
            "Configuration": configData
        ]
        let content: [String: Any] = ["Choices": [choice]]
        let linked: [String: Any] = [
            "Content": content,
            "LastSet": Date(),
            "LastUse": Date()
        ]
        let entry: [String: Any] = [
            "Type": "linked",
            "Linked": linked
        ]

        store["SystemDefault"] = entry
        store["AllSpacesAndDisplays"] = entry

        if var displays = store["Displays"] as? [String: Any] {
            for key in displays.keys { displays[key] = entry }
            store["Displays"] = displays
        }
        if var spaces = store["Spaces"] as? [String: Any] {
            for spaceKey in spaces.keys {
                guard var space = spaces[spaceKey] as? [String: Any] else { continue }
                if space["Default"] != nil { space["Default"] = entry }
                if var spaceDisplays = space["Displays"] as? [String: Any] {
                    for dKey in spaceDisplays.keys { spaceDisplays[dKey] = entry }
                    space["Displays"] = spaceDisplays
                }
                spaces[spaceKey] = space
            }
            store["Spaces"] = spaces
        }

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: store, format: .binary, options: 0
            )
            let tmp = storeURL.appendingPathExtension("tmp")
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tmp)
            return true
        } catch {
            NSLog("[VideoWall] Aerials store write failed: \(error.localizedDescription)")
            return false
        }
    }

    private func backupStoreIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: backupURL.path) else { return }
        guard fm.fileExists(atPath: storeURL.path) else { return }
        try? fm.copyItem(at: storeURL, to: backupURL)
    }

    private func restoreStoreBackup() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupURL.path) else { return }
        try? fm.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fm.removeItem(at: storeURL)
        do {
            try fm.copyItem(at: backupURL, to: storeURL)
            try fm.removeItem(at: backupURL)
        } catch {
            // Leave the backup if the copy failed; caller still retires markers.
        }
    }

    // MARK: Thumbnail

    private func generateThumbnail(from videoURL: URL, to dest: URL) {
        let asset = AVURLAsset(url: videoURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        var actual = CMTime.zero
        guard let cg = try? gen.copyCGImage(at: time, actualTime: &actual) else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dest)
        }
    }

    // MARK: Asset ID

    private func resolvedAssetID() -> String {
        if let existing = storedAssetID() { return existing }
        let id = UUID().uuidString.uppercased()
        persistAssetID(id)
        return id
    }

    private func storedAssetID() -> String? {
        guard let raw = try? String(contentsOf: assetIDURL, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func persistAssetID(_ id: String) {
        try? id.write(to: assetIDURL, atomically: true, encoding: .utf8)
    }

    // MARK: WallpaperAgent

    private func restartWallpaperAgent() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["WallpaperAgent"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }
}
