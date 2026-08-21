//
//  Playlist.swift
//  Mazut
//
//  User playlists — ordered lists of cached-song keys.
//  Stored as JSON alongside the stem cache (Application Support/MazutStems/).
//

import Foundation

/// A single playlist: name + ordered list of cached-song keys (hashes).
nonisolated struct Playlist: Identifiable, Codable, Hashable {
    var id: String          // UUID
    var name: String
    var songIDs: [String]   // song keys from StemCache, in playback order
    /// Pause (seconds) between songs on auto-advance. Optional for backward-compatible JSON.
    var delaySeconds: Int?

    /// Pause in seconds (0 = no pause).
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
