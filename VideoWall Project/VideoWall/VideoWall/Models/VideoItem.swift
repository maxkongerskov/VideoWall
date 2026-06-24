import Foundation
import AppKit

// MARK: - VideoResolution

enum VideoResolution: String, CaseIterable, Codable {
    case original = "Original"
    case uhd4k    = "4K"
    case fhd1080  = "1080p"
    case hd720    = "720p"

    var renderSize: CGSize? {
        switch self {
        case .original: return nil
        case .uhd4k:    return CGSize(width: 3840, height: 2160)
        case .fhd1080:  return CGSize(width: 1920, height: 1080)
        case .hd720:    return CGSize(width: 1280, height: 720)
        }
    }

    var label: String { rawValue }
}

// MARK: - VideoItem

struct VideoItem: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let filename: String
    var duration: TimeInterval
    var thumbnailData: Data?

    /// Decoded thumbnail, cached by id so SwiftUI re-renders don't re-decode the
    /// Data on every access (the grid reads this every layout pass).
    var thumbnail: NSImage? {
        let key = id as NSUUID
        if let cached = Self.thumbnailCache.object(forKey: key) { return cached }
        guard let data = thumbnailData, !data.isEmpty, let img = NSImage(data: data) else { return nil }
        Self.thumbnailCache.setObject(img, forKey: key)
        return img
    }

    var durationString: String {
        guard duration.isFinite && duration >= 0 else { return "00:00" }
        let total = Int(duration)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, filename, duration, thumbnailData
    }

    static func == (lhs: VideoItem, rhs: VideoItem) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: Thumbnail cache

    /// Thread-safe decoded-thumbnail cache keyed by video id. NSCache does its
    /// own locking, so `nonisolated(unsafe)` is sound here.
    nonisolated(unsafe) private static let thumbnailCache = NSCache<NSUUID, NSImage>()

    /// Drops a cached thumbnail (call when a video is deleted).
    static func evictThumbnail(id: UUID) {
        thumbnailCache.removeObject(forKey: id as NSUUID)
    }
}

// MARK: - Supported file extensions

extension VideoItem {
    static let supportedExtensions: Set<String> = [
        "mp4", "m4v", "mov", "avi", "mkv",
        "wmv", "flv", "webm", "ts", "mts",
        "m2ts", "mpeg", "mpg", "3gp", "hevc"
    ]
}

