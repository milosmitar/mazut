//
//  StemActivityShared.swift
//  Mazut / MazutWidget
//
//  Shared Live Activity model — compiled into both the app and the widget
//  extension (membership in both targets). Channel order MUST match
//  `StemKind.allCases` in the app: vocals, drums, bass, guitar, piano, other.
//

import AppIntents
import os.log
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Attributes of the Live Activity card on the lock screen. Live Activities
/// don't exist on Mac Catalyst at all (the `ActivityAttributes` conformance
/// itself is unavailable there, even though the module imports fine), so the
/// `ContentState` shape — used unconditionally by `StemMixerEngine` — is kept
/// as a plain type and the conformance is added only where it's actually usable.
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
nonisolated struct StemActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Whether a channel is audible, in the order of `StemChannel.allCases`.
        var audible: [Bool]
        var isPlaying: Bool
        var title: String
    }
}
#else
nonisolated struct StemActivityAttributes {
    struct ContentState: Codable, Hashable {
        var audible: [Bool]
        var isPlaying: Bool
        var title: String
    }
}
#endif

/// Channels (stems) — a copy of the order and names from `StemKind` because
/// the widget extension can't see the rest of the app.
nonisolated enum StemChannel: Int, CaseIterable, Codable, Sendable {
    case vocals, drums, bass, guitar, piano, other

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
}

/// Bridge between the intent and the mixer: the app (StemMixerEngine) sets
/// `onToggle`, and the intent calls it. Nil in the widget process — harmless,
/// since `LiveActivityIntent` always executes in the app's process anyway.
@MainActor final class StemToggleBox {
    static let shared = StemToggleBox()
    var onToggle: ((Int) -> Void)?
    private init() {}
}

/// Toggle a channel from a button on the Live Activity card, without unlocking
/// the phone and without opening the app. `AudioPlaybackIntent` always
/// executes in the app's process (intended for audio controls from the widget).
struct ToggleStemIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Toggle Channel" }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Channel")
    var stemIndex: Int

    init() {}
    init(stemIndex: Int) { self.stemIndex = stemIndex }

    @MainActor
    func perform() async throws -> some IntentResult {
        let log = Logger(subsystem: "com.tarmi.Mazut", category: "intent")
        log.info("ToggleStemIntent: channel \(stemIndex), bridge set: \(StemToggleBox.shared.onToggle != nil)")
        StemToggleBox.shared.onToggle?(stemIndex)
        return .result()
    }
}
