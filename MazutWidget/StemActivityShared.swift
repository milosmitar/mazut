//
//  StemActivityShared.swift
//  Mazut / MazutWidget
//
//  Zajednički model Live Activity — kompajlira se i u aplikaciju i u widget
//  ekstenziju (članstvo u obe mete). Redosled kanala MORA da prati
//  `StemKind.allCases` u aplikaciji: vocals, drums, bass, guitar, piano, other.
//

import ActivityKit
import AppIntents
import os.log

/// Atributi Live Activity kartice na zaključanom ekranu.
nonisolated struct StemActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Da li se kanal čuje, redom kao `StemChannel.allCases`.
        var audible: [Bool]
        var isPlaying: Bool
        var title: String
    }
}

/// Kanali (stemovi) — kopija redosleda i naziva iz `StemKind` jer widget
/// ekstenzija ne vidi ostatak aplikacije.
nonisolated enum StemChannel: Int, CaseIterable, Codable, Sendable {
    case vocals, drums, bass, guitar, piano, other

    var naziv: String {
        switch self {
        case .vocals: return "Vokal"
        case .drums:  return "Bubnjevi"
        case .bass:   return "Bas"
        case .guitar: return "Gitara"
        case .piano:  return "Klavir"
        case .other:  return "Ostalo"
        }
    }

    var simbol: String {
        switch self {
        case .vocals: return "music.mic"
        case .drums:  return "metronome"
        case .bass:   return "guitars"
        case .guitar: return "guitars.fill"
        case .piano:  return "pianokeys"
        case .other:  return "music.note"
        }
    }
}

/// Most između intenta i miksera: aplikacija (StemMixerEngine) postavlja
/// `onToggle`, a intent ga poziva. U procesu widgeta je nil — bezopasno,
/// jer se `LiveActivityIntent` ionako izvršava u procesu aplikacije.
@MainActor final class StemToggleBox {
    static let shared = StemToggleBox()
    var onToggle: ((Int) -> Void)?
    private init() {}
}

/// Pali/gasi kanal sa dugmeta na Live Activity kartici, bez otključavanja
/// telefona i bez otvaranja aplikacije. `AudioPlaybackIntent` se uvek
/// izvršava u procesu aplikacije (namenjen audio kontrolama sa widgeta).
struct ToggleStemIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Uključi/isključi kanal" }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Kanal")
    var stemIndex: Int

    init() {}
    init(stemIndex: Int) { self.stemIndex = stemIndex }

    @MainActor
    func perform() async throws -> some IntentResult {
        let log = Logger(subsystem: "com.tarmi.Mazut", category: "intent")
        log.info("ToggleStemIntent: kanal \(stemIndex), most postavljen: \(StemToggleBox.shared.onToggle != nil)")
        StemToggleBox.shared.onToggle?(stemIndex)
        return .result()
    }
}
