//
//  LearningLibrary.swift
//  Mazut
//
//  Model and on-disk storage for the Learning tab: user-created, nestable
//  folders holding items — local videos, photos, and documents copied into
//  the app's storage, or YouTube links referenced by video ID. Stored as
//  JSON under <Application Support>/MazutLearning/, separate from the stem cache.
//

import Foundation
import AVFoundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Where an item's file comes from.
nonisolated enum ClipSource: Codable, Hashable {
    case video(ext: String)      // file at LearningStore.mediaURL(for:)
    case image(ext: String)
    case document(ext: String)
    case youtube(videoID: String)
}

nonisolated enum LearningItemKind {
    case video, image, document, youtube
}

/// A single item inside a folder (video, photo, document, or YouTube link).
nonisolated struct LearningClip: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var title: String
    var source: ClipSource
    var dateAdded: Date = Date()

    var kind: LearningItemKind {
        switch source {
        case .video: return .video
        case .image: return .image
        case .document: return .document
        case .youtube: return .youtube
        }
    }
}

/// A folder grouping related items and, recursively, more folders
/// (e.g. "Scale lesson" containing a "Warm-ups" subfolder).
nonisolated struct LearningFolder: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var subfolders: [LearningFolder] = []
    var clips: [LearningClip] = []
}

nonisolated enum LearningStore {

    /// <Application Support>/MazutLearning/
    private static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MazutLearning", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var indexURL: URL { root.appendingPathComponent("folders.json") }

    /// Local files and generated thumbnails.
    static var mediaDirectory: URL {
        let dir = root.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The id of the implicit top-level folder — never shown as a row, just the
    /// container for whatever lives at the root of the Learning tab.
    static let rootID = "root"

    static func load() -> LearningFolder {
        guard let data = try? Data(contentsOf: indexURL) else {
            return LearningFolder(id: rootID, name: "Learning")
        }
        guard let root = try? JSONDecoder().decode(LearningFolder.self, from: data) else {
            // The file exists but doesn't match the current shape (e.g. an old
            // format from before a schema change). Rather than silently falling
            // back to empty and letting the next save() overwrite — and lose —
            // it, move it aside so it can be recovered by hand if needed.
            let backup = root.appendingPathComponent("folders-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: indexURL, to: backup)
            return LearningFolder(id: rootID, name: "Learning")
        }
        return root
    }

    static func save(_ root: LearningFolder) {
        if let data = try? JSONEncoder().encode(root) {
            try? data.write(to: indexURL)
        }
    }

    // MARK: - Folder tree navigation

    /// Walk `path` (a list of subfolder IDs starting from `root`; empty = the
    /// root itself) and return that folder, or nil if the path no longer
    /// resolves (e.g. an ancestor was deleted elsewhere).
    static func folder(at path: [String], in root: LearningFolder) -> LearningFolder? {
        var current = root
        for id in path {
            guard let next = current.subfolders.first(where: { $0.id == id }) else { return nil }
            current = next
        }
        return current
    }

    /// Mutate the folder at `path` in place, then let the caller persist the result.
    static func mutate(at path: [String], in root: inout LearningFolder,
                       _ body: (inout LearningFolder) -> Void) {
        guard let first = path.first else { body(&root); return }
        guard let idx = root.subfolders.firstIndex(where: { $0.id == first }) else { return }
        mutate(at: Array(path.dropFirst()), in: &root.subfolders[idx], body)
    }

    // MARK: - Media files

    /// Local file for a video/image/document item, nil for YouTube items.
    static func mediaURL(for clip: LearningClip) -> URL? {
        switch clip.source {
        case .video(let ext), .image(let ext), .document(let ext):
            return mediaDirectory.appendingPathComponent("\(clip.id).\(ext)")
        case .youtube:
            return nil
        }
    }

    /// Cached poster/preview image for a locally stored item.
    static func thumbnailURL(for clip: LearningClip) -> URL {
        mediaDirectory.appendingPathComponent("\(clip.id)_thumb.jpg")
    }

    static func importVideo(from sourceURL: URL, title: String) throws -> LearningClip {
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let clip = LearningClip(title: title, source: .video(ext: ext))
        try copyIntoMedia(sourceURL, to: clip.id, ext: ext)
        generateVideoThumbnail(for: clip)
        return clip
    }

    static func importImage(data: Data, ext: String, title: String) throws -> LearningClip {
        let clip = LearningClip(title: title, source: .image(ext: ext))
        let dest = mediaDirectory.appendingPathComponent("\(clip.id).\(ext)")
        try data.write(to: dest)
        generateImageThumbnail(for: clip)
        return clip
    }

    static func importDocument(from sourceURL: URL, title: String) throws -> LearningClip {
        let ext = sourceURL.pathExtension.isEmpty ? "dat" : sourceURL.pathExtension
        let clip = LearningClip(title: title, source: .document(ext: ext))
        try copyIntoMedia(sourceURL, to: clip.id, ext: ext)
        generateDocumentThumbnail(for: clip)
        return clip
    }

    private static func copyIntoMedia(_ source: URL, to id: String, ext: String) throws {
        let needsScope = source.startAccessingSecurityScopedResource()
        defer { if needsScope { source.stopAccessingSecurityScopedResource() } }
        let dest = mediaDirectory.appendingPathComponent("\(id).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: source, to: dest)
    }

    /// Poster frame for a video clip (best-effort, ignored on failure).
    private static func generateVideoThumbnail(for clip: LearningClip) {
        guard let url = mediaURL(for: clip) else { return }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        guard let cgImage = try? generator.copyCGImage(
            at: CMTime(seconds: 0.5, preferredTimescale: 60), actualTime: nil)
        else { return }
        writeThumbnail(cgImage, for: clip)
    }

    /// Down-sampled thumbnail for a photo (best-effort, ignored on failure).
    private static func generateImageThumbnail(for clip: LearningClip) {
        guard let url = mediaURL(for: clip),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
        writeThumbnail(thumb, for: clip)
    }

    /// QuickLook-rendered thumbnail for an arbitrary document (PDF, Word, etc.), async
    /// since QLThumbnailGenerator has no synchronous API; best-effort, ignored on failure.
    private static func generateDocumentThumbnail(for clip: LearningClip) {
        guard let url = mediaURL(for: clip) else { return }
        let size = CGSize(width: 240, height: 240)
        // A fixed 3x scale (typical Retina density) avoids touching the
        // main-actor-isolated `UIScreen` from this nonisolated context.
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size,
                                                    scale: 3, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let cgImage = representation?.cgImage else { return }
            writeThumbnail(cgImage, for: clip)
        }
    }

    private static func writeThumbnail(_ cgImage: CGImage, for clip: LearningClip) {
        guard let dest = CGImageDestinationCreateWithURL(
            thumbnailURL(for: clip) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Remove an item's media + thumbnail from disk (YouTube items have neither, so this is a no-op for them).
    static func deleteMedia(for clip: LearningClip) {
        if let url = mediaURL(for: clip) { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: thumbnailURL(for: clip))
    }

    /// Remove media for every item in a folder and, recursively, its subfolders
    /// (used when deleting a folder).
    static func deleteAllMedia(in folder: LearningFolder) {
        for clip in folder.clips { deleteMedia(for: clip) }
        for sub in folder.subfolders { deleteAllMedia(in: sub) }
    }
}

// MARK: - YouTube helpers

/// No API key / SDK — just URL parsing and the public oEmbed + thumbnail
/// endpoints. Playback itself is done by embedding the standard YouTube
/// iframe player (see YouTubePlayerView), since there is no way to obtain a
/// directly playable video URL without violating YouTube's terms.
nonisolated enum YouTube {

    /// Extract the video ID from any common YouTube URL shape, or a bare ID.
    static func videoID(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.range(of: #"^[\w-]{11}$"#, options: .regularExpression) != nil {
            return trimmed
        }
        guard let comps = URLComponents(string: trimmed) else { return nil }
        let host = comps.host?.lowercased() ?? ""

        if host.contains("youtu.be") {
            let id = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }
        if host.contains("youtube.com") {
            if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value { return v }
            let parts = comps.path.split(separator: "/").map(String.init)
            if let idx = parts.firstIndex(where: { $0 == "shorts" || $0 == "embed" || $0 == "live" }),
               idx + 1 < parts.count {
                return parts[idx + 1]
            }
        }
        return nil
    }

    /// Public thumbnail image for a video ID (no API key needed).
    static func thumbnailURL(for videoID: String) -> URL? {
        URL(string: "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg")
    }

    /// Best-effort title lookup via the public oEmbed endpoint. Returns nil on any failure.
    static func fetchTitle(for videoID: String) async -> String? {
        var comps = URLComponents(string: "https://www.youtube.com/oembed")!
        comps.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = comps.url else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["title"] as? String
    }
}
