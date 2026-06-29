//
//  Playlist.swift
//  Mazut
//
//  Korisničke plejliste — uređeni spiskovi ključeva keširanih pesama.
//  Čuvaju se kao JSON pored keša stemova (Application Support/MazutStems/).
//

import Foundation

/// Jedna plejlista: naziv + uređeni spisak ključeva (hash) keširanih pesama.
nonisolated struct Playlist: Identifiable, Codable, Hashable {
    var id: String          // UUID
    var name: String
    var songIDs: [String]   // ključevi pesama iz StemCache, redosledom reprodukcije
    /// Pauza (sekunde) između pesama pri auto-prelasku. Opciono zbog starijeg JSON-a.
    var delaySeconds: Int?

    /// Pauza u sekundama (0 = bez pauze).
    var delay: Int { delaySeconds ?? 0 }
}

nonisolated enum PlaylistStore {

    /// <Application Support>/MazutStems/playlists.json
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MazutStems", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("playlists.json")
    }

    static func load() -> [Playlist] {
        guard let data = try? Data(contentsOf: fileURL),
              let lists = try? JSONDecoder().decode([Playlist].self, from: data)
        else { return [] }
        return lists
    }

    static func save(_ playlists: [Playlist]) {
        if let data = try? JSONEncoder().encode(playlists) {
            try? data.write(to: fileURL)
        }
    }
}
