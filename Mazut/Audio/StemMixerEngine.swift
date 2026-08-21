//
//  StemMixerEngine.swift
//  Mazut
//
//  AVAudioEngine graph that plays multiple stems in sync, with independent
//  volume / mute / solo control per stem and a shared transport
//  (play / pause / seek).
//

import AVFoundation
import MediaPlayer
import Observation
import os
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Observable
final class StemMixerEngine {

    /// The single instance. The engine's `init()` binds global bridges (remote
    /// commands, session interruptions, StemToggleBox for the Live Activity) —
    /// only one may exist, otherwise the last-constructed (empty) instance
    /// overwrites the bridges and the lock-screen buttons do nothing.
    static let shared = StemMixerEngine()

    // MARK: - Public state (observed by the UI)

    private(set) var isPlaying = false
    /// Duration of the longest loaded stem, in seconds.
    private(set) var duration: TimeInterval = 0
    /// Current playback position in seconds.
    var currentTime: TimeInterval = 0
    private(set) var isLoaded = false

    /// Called (on the main thread) when a song reaches its natural end —
    /// used to auto-advance to the next song.
    var onPlaybackFinished: (() -> Void)?

    /// "Next" / "previous" commands from the lock screen or headphones.
    var onRemoteNext: (() -> Void)?
    var onRemotePrevious: (() -> Void)?

    // MARK: - Audio graph

    private let engine = AVAudioEngine()

    /// One player node + audio file per StemKind.
    private struct Track {
        let player = AVAudioPlayerNode()
        var file: AVAudioFile?
    }
    private var tracks: [StemKind: Track] = [:]

    /// Reference to the Stem models so the engine can read volume/mute/solo.
    private var stems: [StemKind: Stem] = [:]

    /// Frame at which playback starts (for seek / resume).
    private var seekFrame: AVAudioFramePosition = 0
    /// Sample rate of the reference file.
    private var sampleRate: Double = 44_100
    /// Total frame count of the longest stem.
    private var totalFrames: AVAudioFramePosition = 0

    /// Timer that refreshes currentTime while playing.
    private var displayTimer: Timer?

    // MARK: - Lock screen (Now Playing)

    /// Metadata of the current song shown on the lock screen / Control Center.
    private var npTitle = ""
    private var npArtist = ""
    private var npArtwork: MPMediaItemArtwork?

    /// Live Activity card with per-channel buttons on the lock screen.
    private let liveActivity = StemActivityController()

    private init() {
        for kind in StemKind.allCases {
            tracks[kind] = Track()
        }
        setupRemoteCommands()
        observeInterruptions()
        // Button on the Live Activity card → toggles a channel on/off.
        StemToggleBox.shared.onToggle = { [weak self] index in
            self?.toggleStem(at: index)
        }
    }

    // MARK: - Loading

    /// Loads the stems and builds the audio graph. `stems` are the models from the UI.
    func load(stems: [Stem]) throws {
        stop()
        engine.stop()
        // Remove all old nodes from the graph.
        for (_, track) in tracks {
            if track.player.engine != nil { engine.detach(track.player) }
        }

        self.stems.removeAll()
        var maxFrames: AVAudioFramePosition = 0
        var refSampleRate: Double = 44_100

        for stem in stems {
            self.stems[stem.kind] = stem
            guard let url = stem.url else { continue }

            let file = try AVAudioFile(forReading: url)
            tracks[stem.kind]?.file = file

            engine.attach(tracks[stem.kind]!.player)
            engine.connect(tracks[stem.kind]!.player,
                           to: engine.mainMixerNode,
                           format: file.processingFormat)

            if file.length > maxFrames {
                maxFrames = file.length
                refSampleRate = file.processingFormat.sampleRate
            }
        }

        totalFrames = maxFrames
        sampleRate = refSampleRate
        duration = refSampleRate > 0 ? Double(maxFrames) / refSampleRate : 0
        seekFrame = 0
        currentTime = 0
        isLoaded = maxFrames > 0

        engine.prepare()
        applyMixToAllTracks()
    }

    /// Release all stems and return the engine to an empty state (UI → song selection).
    func unload() {
        stop()
        engine.stop()
        for (_, track) in tracks {
            if track.player.engine != nil { engine.detach(track.player) }
        }
        for kind in StemKind.allCases { tracks[kind]?.file = nil }
        stems.removeAll()
        duration = 0
        totalFrames = 0
        seekFrame = 0
        currentTime = 0
        isLoaded = false
        npTitle = ""
        npArtist = ""
        npArtwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        liveActivity.end()
    }

    // MARK: - Transport

    func play() {
        guard isLoaded, !isPlaying else { return }
        do {
            configureSession()
            if !engine.isRunning { try engine.start() }
        } catch {
            print("Engine start error: \(error)")
            return
        }

        scheduleFromSeekFrame()

        // Synchronized start: all nodes begin at the same future sample time.
        guard let anyPlayer = activePlayers().first,
              let renderTime = anyPlayer.lastRenderTime ?? engine.outputNode.lastRenderTime
        else {
            activePlayers().forEach { $0.play() }
            isPlaying = true
            startDisplayTimer()
            updateNowPlayingInfo()
            liveActivity.start(state: activityState())
            return
        }

        let startSample = renderTime.sampleTime + AVAudioFramePosition(sampleRate * 0.1)
        let startTime = AVAudioTime(sampleTime: startSample, atRate: sampleRate)
        for player in activePlayers() {
            player.play(at: startTime)
        }
        isPlaying = true
        startDisplayTimer()
        updateNowPlayingInfo()
        liveActivity.start(state: activityState())
    }

    func pause() {
        guard isPlaying else { return }
        // Remember where we stopped before halting the nodes.
        seekFrame = currentFrame()
        activePlayers().forEach { $0.stop() }
        isPlaying = false
        stopDisplayTimer()
        updateNowPlayingInfo()
        liveActivity.update(state: activityState())
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func stop() {
        activePlayers().forEach { $0.stop() }
        engine.stop()
        isPlaying = false
        seekFrame = 0
        currentTime = 0
        stopDisplayTimer()
    }

    /// Seek to the given time in seconds.
    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration))
        let wasPlaying = isPlaying
        if isPlaying { activePlayers().forEach { $0.stop() } }

        seekFrame = AVAudioFramePosition(clamped * sampleRate)
        currentTime = clamped

        if wasPlaying {
            scheduleFromSeekFrame()
            let startSample = (engine.outputNode.lastRenderTime?.sampleTime ?? 0)
                + AVAudioFramePosition(sampleRate * 0.1)
            let startTime = AVAudioTime(sampleTime: startSample, atRate: sampleRate)
            activePlayers().forEach { $0.play(at: startTime) }
        }
        updateNowPlayingInfo()
    }

    // MARK: - Mix control (volume / mute / solo)

    /// Apply volume and mute/solo logic to all player nodes.
    /// Call every time the user changes a slider or button.
    func applyMixToAllTracks() {
        let soloActive = stems.values.contains { $0.isSolo }
        for (kind, stem) in stems {
            guard let player = tracks[kind]?.player, player.engine != nil else { continue }
            let audible: Bool
            if soloActive {
                audible = stem.isSolo
            } else {
                audible = !stem.isMuted
            }
            player.volume = audible ? stem.volume : 0
        }
        liveActivity.update(state: activityState())
    }

    /// Toggle a channel from the Live Activity card. If solo is active, the
    /// current audibility is first "frozen" into the mute flags and solo is
    /// turned off — so the card's buttons always behave predictably (what you
    /// see is what you hear).
    func toggleStem(at index: Int) {
        let kinds = StemKind.allCases
        guard kinds.indices.contains(index), let target = stems[kinds[index]] else {
            Logger(subsystem: "com.tarmi.Mazut", category: "intent")
                .warning("toggleStem: channel \(index) doesn't exist or isn't loaded")
            return
        }
        if stems.values.contains(where: { $0.isSolo }) {
            for stem in stems.values {
                stem.isMuted = !stem.isSolo
                stem.isSolo = false
            }
        }
        target.isMuted.toggle()
        applyMixToAllTracks()
    }

    // MARK: - Helpers

    private func activePlayers() -> [AVAudioPlayerNode] {
        tracks.values.filter { $0.file != nil }.map { $0.player }
    }

    /// Schedule playback of all files from seekFrame to the end.
    private func scheduleFromSeekFrame() {
        // Guard: startingFrame must be within [0, file.length].
        let start = max(0, seekFrame)
        for (_, track) in tracks {
            guard let file = track.file else { continue }
            let frameCount = AVAudioFrameCount(max(0, file.length - start))
            guard frameCount > 0 else { continue }
            track.player.scheduleSegment(file,
                                         startingFrame: start,
                                         frameCount: frameCount,
                                         at: nil)
        }
    }

    /// Current frame based on the player node's position.
    private func currentFrame() -> AVAudioFramePosition {
        guard let player = activePlayers().first,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return seekFrame }
        // Before a scheduled `play(at:)` start arrives, sampleTime is negative;
        // don't let the position (and thus seekFrame) drop below zero.
        return max(0, seekFrame + playerTime.sampleTime)
    }

    private func startDisplayTimer() {
        stopDisplayTimer()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self else { return }
            let frame = self.currentFrame()
            self.currentTime = min(Double(frame) / self.sampleRate, self.duration)
            // End of song: stop and notify (auto-advance to the next).
            if frame >= self.totalFrames, self.totalFrames > 0 {
                self.pause()
                self.seekFrame = 0
                self.currentTime = 0
                self.onPlaybackFinished?()
            }
        }
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func configureSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
    }

    // MARK: - Lock screen / Control Center

    /// Set the song metadata shown on the lock screen.
    /// Call after `load(stems:)`; an empty title clears the display.
    func setNowPlaying(title: String, artist: String = "", artworkURL: URL? = nil) {
        npTitle = title
        npArtist = artist
        npArtwork = nil
        if let url = artworkURL {
            #if canImport(UIKit)
            if let img = UIImage(contentsOfFile: url.path) {
                npArtwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            }
            #elseif canImport(AppKit)
            if let img = NSImage(contentsOfFile: url.path) {
                npArtwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            }
            #endif
        }
        updateNowPlayingInfo()
        liveActivity.update(state: activityState())
    }

    /// Current state for the Live Activity card: audibility of every channel
    /// (mute/solo logic as in `applyMixToAllTracks`), whether it's playing, and the title.
    private func activityState() -> StemActivityAttributes.ContentState {
        let soloActive = stems.values.contains { $0.isSolo }
        let audible = StemKind.allCases.map { kind -> Bool in
            guard let stem = stems[kind], tracks[kind]?.file != nil else { return false }
            return soloActive ? stem.isSolo : !stem.isMuted
        }
        return .init(audible: audible,
                     isPlaying: isPlaying,
                     title: npTitle.isEmpty ? "Mazut" : npTitle)
    }

    /// Refresh the lock-screen state (title, duration, position, playing or not).
    /// The system extrapolates position via `rate` on its own, so it's enough to
    /// call this on play/pause/seek, not on every timer tick.
    private func updateNowPlayingInfo() {
        guard isLoaded, !npTitle.isEmpty else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: npTitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: min(Double(currentFrame()) / sampleRate, duration),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if !npArtist.isEmpty { info[MPMediaItemPropertyArtist] = npArtist }
        if let art = npArtwork { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Register commands from the lock screen / headphones. Handlers may arrive
    /// off the main thread, so the work is dispatched to main.
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onRemoteNext?() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onRemotePrevious?() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = e.positionTime
            DispatchQueue.main.async { self?.seek(to: time) }
            return .success
        }
    }

    /// Audio session interruptions (phone call, Siri…) and headphones unplugged.
    private func observeInterruptions() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.pause()
            case .ended:
                // Resume only if the system says to (e.g. call ended).
                let opts = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume) {
                    self.play()
                }
            @unknown default:
                break
            }
        }
        // Headphones unplugged / Bluetooth dropped → pause (standard behavior).
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
            else { return }
            self?.pause()
        }
        #endif
    }
}
