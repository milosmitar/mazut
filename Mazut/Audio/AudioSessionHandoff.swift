//
//  AudioSessionHandoff.swift
//  Mazut
//
//  The one place that hands the audio session back to plain playback after the
//  microphone was in use (Tuner, TimingCoach).
//

import AVFoundation

enum AudioSessionHandoff {
    /// Back to `.playback` after recording.
    ///
    /// - `keepActive`: something of Mazut's is still sounding (a song, the
    ///   metronome). Deactivating under it would cut it off mid-song, so the
    ///   session stays active.
    /// - Otherwise the session is deactivated with `.notifyOthersOnDeactivation`,
    ///   so another app's audio that the microphone stopped (Spotify, a podcast)
    ///   is told it may resume.
    /// - `afterInterruption`: a call or Siri took the session; it is already
    ///   inactive and `setActive` would fail while the interruption lasts, so only
    ///   the category is reset.
    static func restorePlayback(keepActive: Bool, afterInterruption: Bool = false) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        guard !afterInterruption else { return }
        if keepActive {
            try? session.setActive(true)
        } else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }
}
