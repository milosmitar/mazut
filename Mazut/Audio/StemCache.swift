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

/// Jedna keširana pesma za prikaz u biblioteci.
struct CachedSong: Identifiable {
    let id: String              // ključ = hash sadržaja
    let name: String            // originalno ime fajla (za prikaz)
    let date: Date              // kada je razdvojena
    let stems: [StemKind: URL]  // putanje 6 stem .wav fajlova
    let size: Int64             // zauzeće na disku (bajtovi)
}

enum StemCache {

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
            if let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                name = json["name"] ?? name
                if let d = json["date"], let parsed = iso.date(from: d) { date = parsed }
            }
            songs.append(CachedSong(id: key, name: name, date: date,
                                    stems: stems, size: folderSize(dir)))
        }
        return songs.sorted { $0.date > $1.date }
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
