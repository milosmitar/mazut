//
//  PracticeSettings.swift
//  Mazut
//
//  Per-song practice settings — playback speed and tempo. The A–B loop is not
//  stored (made fresh each time a song is opened); older files that still
//  contain loopStart/loopEnd decode fine, the keys are just ignored.
//  Stored as practice.json inside the song's cache folder
//  (<Application Support>/MazutStems/<hash>/), so it follows the song's
//  content hash and is deleted together with the song.
//

import Foundation

nonisolated struct PracticeSettings: Codable, Equatable {
    /// Playback speed (1 = original). Optional for forward-compatible JSON.
    var rate: Float?
    /// Tempo found by TempoDetector (computed once per song, then cached here).
    var detectedBPM: Double?
    /// Metronome tempo the user chose for this song (nil = use detectedBPM).
    var bpm: Int?
    /// TempoDetector.version that produced detectedBPM — set even when nothing
    /// was found, so a song without a detectable tempo isn't re-analysed on
    /// every open; a newer detector version recomputes.
    var tempoVersion: Int?

    var isEmpty: Bool {
        (rate ?? 1) == 1 && detectedBPM == nil && bpm == nil && tempoVersion == nil
    }
}

nonisolated enum PracticeStore {

    /// nil if the song's folder is gone (song deleted) — never recreate it,
    /// or an orphan folder holding only practice.json would be left behind.
    private static func fileURL(for songID: String) -> URL? {
        StemCache.existingDirectory(for: songID)?.appendingPathComponent("practice.json")
    }

    static func load(songID: String) -> PracticeSettings {
        guard let url = fileURL(for: songID),
              let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(PracticeSettings.self, from: data)
        else { return PracticeSettings() }
        return settings
    }

    static func save(_ settings: PracticeSettings, songID: String) {
        guard let url = fileURL(for: songID) else { return }
        if settings.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: url)
        }
    }
}
