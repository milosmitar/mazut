//
//  StemCache.swift
//  Mazut
//
//  Persistent cache of separated songs. Stems are stored in the Application
//  Support directory, in a subfolder named after the SHA256 hash of the
//  source song's content — so the same song (regardless of name/path) never
//  needs to be separated more than once.
//

import Foundation
import CryptoKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// A single cached song for display in the library.
nonisolated struct CachedSong: Identifiable {
    let id: String              // key = content hash
    let name: String            // original file name (for display)
    let date: Date               // when it was separated
    let duration: TimeInterval  // song duration (seconds)
    let stems: [StemKind: URL]  // paths to the 6 stem files
    let size: Int64              // disk usage (bytes)
    let artworkURL: URL?         // cover.jpg if the song has embedded artwork, otherwise nil

    /// Artist from a name of the form "Artist - Title" (empty if there's no separator).
    var artist: String {
        guard let r = name.range(of: " - ") else { return "" }
        return String(name[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// Title without the artist (the whole name if there's no separator).
    var title: String {
        guard let r = name.range(of: " - ") else { return name }
        return String(name[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
}

nonisolated enum StemCache {

    /// Format of cached stems (AAC in an .m4a container — ~6× smaller than PCM .wav).
    static let stemExtension = "m4a"

    /// Cache root: <Application Support>/MazutStems/
    private static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MazutStems", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// SHA256 of the file's content (hex) — a stable key independent of name/path.
    static func key(for url: URL) throws -> String {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Folder for the given key (creates it if it doesn't exist).
    static func directory(for key: String) -> URL {
        let dir = root.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Map of stems if all 6 files are present, otherwise nil (cache miss).
    /// Looks for .m4a, falling back to .wav (for older caches).
    static func stems(for key: String) -> [StemKind: URL]? {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(key, isDirectory: true)
        var map: [StemKind: URL] = [:]
        for kind in StemKind.allCases {
            let m4a = dir.appendingPathComponent("\(kind.rawValue).\(stemExtension)")
            let wav = dir.appendingPathComponent("\(kind.rawValue).wav")
            if fm.fileExists(atPath: m4a.path) {
                map[kind] = m4a
            } else if fm.fileExists(atPath: wav.path) {
                map[kind] = wav
            } else {
                return nil
            }
        }
        return map
    }

    /// Path to the song's cached artwork (cover.jpg) if it exists.
    static func artworkURL(for key: String) -> URL? {
        let url = root.appendingPathComponent(key, isDirectory: true).appendingPathComponent("cover.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Extract the embedded artwork from the source song and save it as a small
    /// thumbnail (cover.jpg) in the cache folder. No artwork — nothing is written.
    static func saveArtwork(key: String, from sourceURL: URL) async {
        let dest = directory(for: key).appendingPathComponent("cover.jpg")
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }

        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        let asset = AVURLAsset(url: sourceURL)
        guard let metadata = try? await asset.load(.commonMetadata) else { return }
        let items = AVMetadataItem.metadataItems(from: metadata,
                                                 filteredByIdentifier: .commonIdentifierArtwork)
        guard let item = items.first, let data = try? await item.load(.dataValue) else { return }
        writeThumbnail(data: data, to: dest, maxPixel: 240)
    }

    /// Down-sample the image (ImageIO, cross-platform) and write it as JPEG.
    private static func writeThumbnail(data: Data, to dest: URL, maxPixel: Int) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(out, thumb, nil)
        CGImageDestinationFinalize(out)
    }

    /// Write metadata (name + date) alongside the cached stems.
    static func saveMeta(key: String, name: String) {
        let meta: [String: String] = [
            "name": name,
            "date": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta) {
            try? data.write(to: directory(for: key).appendingPathComponent("meta.json"))
        }
    }

    /// All cached songs, newest first.
    static func library() -> [CachedSong] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }

        let iso = ISO8601DateFormatter()
        var songs: [CachedSong] = []
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let key = dir.lastPathComponent
            guard let stems = stems(for: key) else { continue }   // incomplete folder → skip

            var name = key
            var date = Date.distantPast
            var meta: [String: String] = [:]
            let metaURL = dir.appendingPathComponent("meta.json")
            if let data = try? Data(contentsOf: metaURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                meta = json
                name = meta["name"] ?? name
                if let d = meta["date"], let parsed = iso.date(from: d) { date = parsed }
            }
            // Duration is computed once and cached in meta.json (reading audio is slow).
            var duration = meta["duration"].flatMap(TimeInterval.init) ?? 0
            if duration == 0, let any = stems[.vocals] ?? stems.values.first {
                duration = audioDuration(of: any)
                meta["duration"] = String(duration)
                if let data = try? JSONSerialization.data(withJSONObject: meta) {
                    try? data.write(to: metaURL)
                }
            }

            songs.append(CachedSong(id: key, name: name, date: date, duration: duration,
                                    stems: stems, size: folderSize(dir),
                                    artworkURL: artworkURL(for: key)))
        }
        return songs.sorted { $0.date > $1.date }
    }

    /// Audio file duration in seconds (0 if it can't be read).
    private static func audioDuration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let sr = file.processingFormat.sampleRate
        return sr > 0 ? Double(file.length) / sr : 0
    }

    /// Total disk usage of the cache (bytes).
    static func totalSize() -> Int64 {
        folderSize(root)
    }

    /// Delete a cached song.
    static func delete(key: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(key, isDirectory: true))
    }

    /// Sum of the sizes of all files in the (sub)folder.
    private static func folderSize(_ dir: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in en {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
