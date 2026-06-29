//
//  StemCache.swift
//  Mazut
//
//  Trajni keš razdvojenih pesama. Stemovi se čuvaju u Application Support
//  direktorijumu, u podfolderu nazvanom po SHA256 hash-u sadržaja izvorne
//  pesme — pa ista pesma (bez obzira na ime/putanju) ne mora da se razdvaja
//  više puta.
//

import Foundation
import CryptoKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Jedna keširana pesma za prikaz u biblioteci.
nonisolated struct CachedSong: Identifiable {
    let id: String              // ključ = hash sadržaja
    let name: String            // originalno ime fajla (za prikaz)
    let date: Date              // kada je razdvojena
    let duration: TimeInterval  // trajanje pesme (sekunde)
    let stems: [StemKind: URL]  // putanje 6 stem .wav fajlova
    let size: Int64             // zauzeće na disku (bajtovi)
    let artworkURL: URL?        // cover.jpg ako pesma ima ugrađenu sliku, inače nil

    /// Izvođač iz naziva oblika „Izvođač - Naslov" (prazan ako nema separatora).
    var artist: String {
        guard let r = name.range(of: " - ") else { return "" }
        return String(name[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// Naslov bez izvođača (ceo naziv ako nema separatora).
    var title: String {
        guard let r = name.range(of: " - ") else { return name }
        return String(name[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
}

nonisolated enum StemCache {

    /// Format keširanih stemova (AAC u .m4a kontejneru — ~6× manje od PCM .wav).
    static let stemExtension = "m4a"

    /// Koren keša: <Application Support>/MazutStems/
    private static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MazutStems", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// SHA256 sadržaja fajla (hex) — stabilan ključ nezavisan od imena/putanje.
    static func key(for url: URL) throws -> String {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Folder za dati ključ (kreira ga ako ne postoji).
    static func directory(for key: String) -> URL {
        let dir = root.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Mapa stemova ako su svih 6 fajlova prisutni, inače nil (keš-miss).
    /// Traži .m4a, pa pada na .wav (zbog starijeg keša).
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

    /// Putanja do keširane slike pesme (cover.jpg) ako postoji.
    static func artworkURL(for key: String) -> URL? {
        let url = root.appendingPathComponent(key, isDirectory: true).appendingPathComponent("cover.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Izvuci ugrađenu sliku (album art) iz izvorne pesme i snimi je kao mali
    /// thumbnail (cover.jpg) u keš folder. Bez slike — ništa se ne upisuje.
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

    /// Down-sample slike (ImageIO, cross-platform) i upis kao JPEG.
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

    /// Upiši metapodatke (ime + datum) uz keširane stemove.
    static func saveMeta(key: String, name: String) {
        let meta: [String: String] = [
            "name": name,
            "date": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta) {
            try? data.write(to: directory(for: key).appendingPathComponent("meta.json"))
        }
    }

    /// Sve keširane pesme, najnovije prvo.
    static func library() -> [CachedSong] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }

        let iso = ISO8601DateFormatter()
        var songs: [CachedSong] = []
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let key = dir.lastPathComponent
            guard let stems = stems(for: key) else { continue }   // nepotpun folder → preskoči

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
            // Trajanje se računa jednom i keširaj u meta.json (čitanje audija je sporo).
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

    /// Trajanje audio fajla u sekundama (0 ako se ne može pročitati).
    private static func audioDuration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let sr = file.processingFormat.sampleRate
        return sr > 0 ? Double(file.length) / sr : 0
    }

    /// Ukupno zauzeće keša na disku (bajtovi).
    static func totalSize() -> Int64 {
        folderSize(root)
    }

    /// Obriši keširanu pesmu.
    static func delete(key: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(key, isDirectory: true))
    }

    /// Zbir veličina svih fajlova u (pod)folderu.
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
