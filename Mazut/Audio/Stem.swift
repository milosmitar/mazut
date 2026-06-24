//
//  Stem.swift
//  Mazut
//
//  Model jednog razdvojenog izvora zvuka (vokal, bas, bubnjevi, ostalo).
//

import SwiftUI

/// Tip stema. Redosled prati standardni izlaz Spleeter / Demucs modela (4 stema).
enum StemKind: String, CaseIterable, Identifiable {
    case vocals
    case drums
    case bass
    case guitar
    case piano
    case other

    var id: String { rawValue }

    /// Naziv na srpskom za prikaz u UI-ju.
    var displayName: String {
        switch self {
        case .vocals: return "Vokal"
        case .drums:  return "Bubnjevi"
        case .bass:   return "Bas"
        case .guitar: return "Gitara"
        case .piano:  return "Klavir"
        case .other:  return "Ostalo"
        }
    }

    var systemImage: String {
        switch self {
        case .vocals: return "music.mic"
        case .drums:  return "metronome"
        case .bass:   return "guitars"
        case .guitar: return "guitars.fill"
        case .piano:  return "pianokeys"
        case .other:  return "music.note"
        }
    }

    var color: Color {
        switch self {
        case .vocals: return .pink
        case .drums:  return .orange
        case .bass:   return .purple
        case .guitar: return .red
        case .piano:  return .teal
        case .other:  return .blue
        }
    }
}

/// Stanje jednog stema u mikseru — jačina, mute i solo.
@Observable
final class Stem: Identifiable {
    let kind: StemKind
    /// Audio fajl ovog stema. Nil dok separacija ne proizvede stem.
    var url: URL?

    /// Jačina 0...1 koju korisnik podešava sliderom.
    var volume: Float = 1.0
    var isMuted: Bool = false
    var isSolo: Bool = false

    var id: String { kind.id }

    init(kind: StemKind, url: URL? = nil) {
        self.kind = kind
        self.url = url
    }

    var displayName: String { kind.displayName }
}
