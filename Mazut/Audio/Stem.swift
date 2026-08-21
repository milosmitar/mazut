//
//  Stem.swift
//  Mazut
//
//  Model of a single separated audio source (vocals, bass, drums, other).
//

import SwiftUI

/// Stem type. The order follows the standard output of the Spleeter / Demucs model (4 stems).
nonisolated enum StemKind: String, CaseIterable, Identifiable {
    case vocals
    case drums
    case bass
    case guitar
    case piano
    case other

    var id: String { rawValue }

    /// Display name shown in the UI.
    var displayName: String {
        switch self {
        case .vocals: return "Vocals"
        case .drums:  return "Drums"
        case .bass:   return "Bass"
        case .guitar: return "Guitar"
        case .piano:  return "Piano"
        case .other:  return "Other"
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

/// State of a single stem in the mixer — volume, mute and solo.
@Observable
final class Stem: Identifiable {
    let kind: StemKind
    /// This stem's audio file. Nil until separation produces the stem.
    var url: URL?

    /// Volume 0...1 adjusted by the user via the slider.
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
