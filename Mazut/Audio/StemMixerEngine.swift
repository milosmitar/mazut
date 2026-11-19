//
//  StemMixerEngine.swift
//  Mazut
//
//  AVAudioEngine graph that plays multiple stems in sync, with independent
//  volume / mute / solo control per stem and a shared transport
//  (play / pause / seek), an A–B loop and pitch-preserving slow-down.
//
//  Graph: player (one per stem) → stemMixer → timePitch → mainMixer.
//  Every position is computed on the *players'* timeline (upstream of
//  timePitch), so it is always in song frames regardless of speed — never mix
//  in outputNode times, which run at a different rate once speed ≠ 100%.
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

    // MARK: - Loop (A–B) and speed

    /// Loop boundaries in seconds (nil = not set).
    private(set) var loopStart: TimeInterval?
    private(set) var loopEnd: TimeInterval?
    /// Whether the A–B region is repeating (only effective with a valid region).
    private(set) var isLoopEnabled = false
    /// Playback speed, pitch preserved (1 = original).
    private(set) var rate: Float = 1.0

    static let minLoopLength: TimeInterval = 0.5
    static let rateRange: ClosedRange<Float> = 0.5...1.0

    /// Both boundaries set and far enough apart.
    var hasLoopRegion: Bool { loopFrames != nil }

    // MARK: - Audio graph

    private let engine = AVAudioEngine()

    /// One player node + audio file per StemKind.
    private struct Track {
        let player = AVAudioPlayerNode()
        var file: AVAudioFile?
    }
    private var tracks: [StemKind: Track] = [:]

    /// All stems are summed here, so the speed change runs once, not 6×.
    private let stemMixer = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()

    /// Loop the current schedule was built with (nil = linear playback to the end).
    /// Kept separate from loopStart/End so currentFrame() maps against what is
    /// actually queued on the players, even mid-edit.
    private var scheduledLoop: (start: AVAudioFramePosition, end: AVAudioFramePosition)?
    /// Bumped on every reschedule; stale loop-pass completions compare against it.
    private var scheduleGeneration = 0
    /// Audio kept queued ahead in a loop (gapless wrap B → A). Refills arrive via
    /// the main thread, so this must outlast a main-thread stall: a fixed 2 passes
    /// would be only ~1 s for the shortest (0.5 s) loop.
    private static let loopQueueAhead: TimeInterval = 3
    /// Deferred requeue after A/B nudges while playing (see `loopChanged`).
    private var pendingLoopRestart: DispatchWorkItem?
    private static let nudgeSettle: TimeInterval = 0.4

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
        engine.attach(stemMixer)
        engine.attach(timePitch)
        timePitch.bypass = true
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
                           to: stemMixer,
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
        resetLoopAndRate()

        if let fmt = AVAudioFormat(standardFormatWithSampleRate: refSampleRate, channels: 2) {
            engine.connect(stemMixer, to: timePitch, format: fmt)
            engine.connect(timePitch, to: engine.mainMixerNode, format: fmt)
        }

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
        resetLoopAndRate()
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

        // isPlaying first: loop-pass completions only re-queue while playing.
        isPlaying = true
        scheduleFromSeekFrame()
        startPlayersSynchronized()
        startDisplayTimer()
        updateNowPlayingInfo()
        liveActivity.start(state: activityState())
    }

    func pause() {
        guard isPlaying else { return }
        // Remember where we stopped before halting the nodes.
        seekFrame = currentFrame()
        isPlaying = false
        activePlayers().forEach { $0.stop() }
        scheduledLoop = nil
        // play() schedules with the current loop anyway; a deferred nudge requeue
        // firing after a quick pause → play would only add another gap.
        pendingLoopRestart?.cancel()
        pendingLoopRestart = nil
        stopDisplayTimer()
        updateNowPlayingInfo()
        liveActivity.update(state: activityState())
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func stop() {
        isPlaying = false
        activePlayers().forEach { $0.stop() }
        engine.stop()
        seekFrame = 0
        currentTime = 0
        scheduledLoop = nil
        stopDisplayTimer()
    }

    /// Seek to the given time in seconds. Seeking before A plays into the loop
    /// and repeats it. Seeking past the loop's end (B) turns the loop off when
    /// `exitsLoop` — the scrubber passes false while dragging (a target past B
    /// then just snaps to A) and calls `endScrub(at:)` on release, so merely
    /// dragging over B doesn't kill the loop.
    func seek(to time: TimeInterval, exitsLoop: Bool = true) {
        let clamped = max(0, min(time, duration))
        let target = frame(clamped)
        if exitsLoop, loopActive, let loop = loopFrames, target >= loop.end {
            isLoopEnabled = false
        }
        restart(at: target)
    }

    /// Scrubber released at `time`: only if it ended past B does the loop turn
    /// off (and playback moves there). Otherwise the drag's seeks already stand.
    func endScrub(at time: TimeInterval) {
        guard loopActive, let loop = loopFrames,
              frame(max(0, min(time, duration))) >= loop.end else { return }
        seek(to: time)
    }

    /// Move playback to `target` (song frames), rescheduling if playing.
    /// With an active loop, a position at/after B snaps to A.
    private func restart(at target: AVAudioFramePosition) {
        // This restart applies the current loop, superseding any deferred one.
        pendingLoopRestart?.cancel()
        pendingLoopRestart = nil
        var target = max(0, min(target, totalFrames))
        if loopActive, let loop = loopFrames, target >= loop.end { target = loop.start }
        let wasPlaying = isPlaying
        if wasPlaying { activePlayers().forEach { $0.stop() } }

        seekFrame = target
        currentTime = sampleRate > 0 ? Double(target) / sampleRate : 0

        if wasPlaying {
            scheduleFromSeekFrame()
            startPlayersSynchronized()
        } else {
            scheduledLoop = nil
        }
        updateNowPlayingInfo()
    }

    // MARK: - Loop / speed control

    /// Set A at `time`. Drops B if it would end up before/too close to A.
    func setLoopStart(_ time: TimeInterval) {
        let a = max(0, min(time, duration))
        loopStart = a
        if let b = loopEnd, b - a < Self.minLoopLength {
            loopEnd = nil
            isLoopEnabled = false
        }
        loopChanged()
    }

    /// Set B at `time` and switch the loop on (jumps back to A when playing
    /// past it). Returns false (nothing changes) if A isn't set or B would be
    /// too close to / before A.
    @discardableResult
    func setLoopEnd(_ time: TimeInterval) -> Bool {
        guard let a = loopStart else { return false }
        let b = max(0, min(time, duration))
        guard b - a >= Self.minLoopLength else { return false }
        loopEnd = b
        isLoopEnabled = true
        loopChanged()
        return true
    }

    /// Set both boundaries at once (timeline ruler: create / move / resize the
    /// region). Applied once when the gesture ends — the timeline draws its own
    /// draft while dragging, so there's no restart per drag step. Returns false
    /// (nothing changes) if the region is shorter than `minLoopLength`.
    @discardableResult
    func setLoopRegion(start: TimeInterval, end: TimeInterval, enabled: Bool) -> Bool {
        let a = max(0, min(start, duration)), b = max(0, min(end, duration))
        guard b - a >= Self.minLoopLength - 0.0001 else { return false }
        loopStart = a
        loopEnd = b
        isLoopEnabled = enabled
        loopChanged()
        return true
    }

    /// Shift A or B by `delta` seconds, keeping the minimum loop length.
    func nudgeLoopStart(by delta: TimeInterval) {
        guard let a = loopStart else { return }
        var new = max(0, min(a + delta, duration))
        if let b = loopEnd { new = min(new, b - Self.minLoopLength) }
        loopStart = max(0, new)
        loopChanged(deferred: true)
    }

    func nudgeLoopEnd(by delta: TimeInterval) {
        guard let b = loopEnd else { return }
        var new = max(0, min(b + delta, duration))
        if let a = loopStart { new = max(new, a + Self.minLoopLength) }
        loopEnd = min(duration, new)
        loopChanged(deferred: true)
    }

    func setLoopEnabled(_ on: Bool) {
        guard on != isLoopEnabled else { return }
        isLoopEnabled = on && hasLoopRegion
        loopChanged()
    }

    func clearLoop() {
        loopStart = nil
        loopEnd = nil
        isLoopEnabled = false
        loopChanged()
    }

    /// Playback speed (clamped to `rateRange`); pitch is preserved.
    func setRate(_ newRate: Float) {
        let r = min(max(newRate, Self.rateRange.lowerBound), Self.rateRange.upperBound)
        rate = (r * 100).rounded() / 100
        timePitch.rate = rate
        // At 100% skip the time-stretch DSP entirely (no artifacts, no latency).
        timePitch.bypass = rate == 1
        updateNowPlayingInfo()
    }

    /// Re-apply loop state to the transport. Playing: requeue only if the loop
    /// affects (or affected) the schedule, to avoid a needless restart gap.
    /// Paused: just snap the position into the loop if needed.
    ///
    /// `deferred` (nudges): while playing, the requeue waits until the edits stop
    /// for `nudgeSettle`, so a burst of ±0.1 s taps costs one restart gap instead
    /// of one per tap. Until then the old loop keeps playing (and currentFrame
    /// keeps mapping against it via scheduledLoop).
    private func loopChanged(deferred: Bool = false) {
        if deferred, isPlaying, loopActive || scheduledLoop != nil {
            pendingLoopRestart?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.pendingLoopRestart = nil
                self?.loopChanged()
            }
            pendingLoopRestart = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.nudgeSettle, execute: work)
            return
        }
        if isPlaying {
            guard loopActive || scheduledLoop != nil else { return }
            restart(at: currentFrame())
        } else if loopActive, let loop = loopFrames, seekFrame >= loop.end {
            restart(at: loop.start)
        }
    }

    private func resetLoopAndRate() {
        pendingLoopRestart?.cancel()
        pendingLoopRestart = nil
        loopStart = nil
        loopEnd = nil
        isLoopEnabled = false
        scheduledLoop = nil
        rate = 1
        timePitch.rate = 1
        timePitch.bypass = true
    }

    private var loopFrames: (start: AVAudioFramePosition, end: AVAudioFramePosition)? {
        guard let a = loopStart, let b = loopEnd, b - a >= Self.minLoopLength - 0.0001 else { return nil }
        return (frame(a), frame(b))
    }

    private var loopActive: Bool { isLoopEnabled && loopFrames != nil }

    private func frame(_ time: TimeInterval) -> AVAudioFramePosition {
        AVAudioFramePosition((time * sampleRate).rounded())
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

    /// Loaded tracks in a fixed order, so the reference player (index 0, whose
    /// position drives currentFrame and whose completions drive loop refills)
    /// is always the same one.
    private func loadedTracks() -> [Track] {
        StemKind.allCases.compactMap { tracks[$0] }.filter { $0.file != nil }
    }

    private func activePlayers() -> [AVAudioPlayerNode] {
        loadedTracks().map { $0.player }
    }

    /// Start all players together 0.1 s from now, by host (system) time. Host
    /// time is shared by every node and always available — unlike lastRenderTime,
    /// which can be nil right after engine.start() (→ unsynced starts) and whose
    /// sample timeline differs per node once timePitch changes the speed.
    private func startPlayersSynchronized() {
        let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.1))
        activePlayers().forEach { $0.play(at: start) }
    }

    /// Schedule playback of all files from seekFrame: to the end, or — with an
    /// active loop — up to B followed by back-to-back A→B passes (refilled as
    /// they finish, see `enqueueLoopPass`). Each player plays its own queue
    /// gaplessly, and all queues are identical, so stems stay sample-locked.
    private func scheduleFromSeekFrame() {
        scheduleGeneration += 1
        if loopActive, let loop = loopFrames {
            if seekFrame >= loop.end { seekFrame = loop.start }
            scheduledLoop = loop
            let start = max(0, seekFrame)
            for track in loadedTracks() {
                schedule(track, from: start, to: loop.end)
            }
            let loopSeconds = Double(loop.end - loop.start) / sampleRate
            let passes = min(8, max(2, Int((Self.loopQueueAhead / max(loopSeconds, 0.01)).rounded(.up))))
            for _ in 0..<passes { enqueueLoopPass() }
        } else {
            scheduledLoop = nil
            // Guard: startingFrame must be within [0, file.length].
            let start = max(0, seekFrame)
            for track in loadedTracks() {
                schedule(track, from: start, to: track.file?.length ?? 0)
            }
        }
    }

    private func schedule(_ track: Track, from start: AVAudioFramePosition,
                          to end: AVAudioFramePosition,
                          completion: AVAudioNodeCompletionHandler? = nil) {
        guard let file = track.file else { return }
        let count = min(end, file.length) - start
        guard count > 0 else { return }
        track.player.scheduleSegment(file, startingFrame: start,
                                     frameCount: AVAudioFrameCount(count), at: nil,
                                     completionHandler: completion)
    }

    /// Queue one more A→B pass on every player. Only the reference player gets a
    /// completion; when its pass is consumed, another pass is queued, keeping
    /// the same number of passes (≥ `loopQueueAhead` of audio) in flight. Completions from a superseded schedule
    /// (seek, loop edit, pause — player.stop() fires them all) are ignored.
    private func enqueueLoopPass() {
        guard let loop = scheduledLoop else { return }
        let generation = scheduleGeneration
        for (i, track) in loadedTracks().enumerated() {
            let completion: AVAudioNodeCompletionHandler? = i == 0 ? { [weak self] in
                DispatchQueue.main.async { self?.loopPassFinished(generation) }
            } : nil
            schedule(track, from: loop.start, to: loop.end, completion: completion)
        }
    }

    private func loopPassFinished(_ generation: Int) {
        guard generation == scheduleGeneration, isPlaying, scheduledLoop != nil else { return }
        enqueueLoopPass()
    }

    /// Current position in song frames. The reference player's sampleTime counts
    /// frames played since the last schedule; with a loop that's [seekFrame→B)
    /// then repeating [A→B), so it's folded back into the loop.
    private func currentFrame() -> AVAudioFramePosition {
        guard let player = activePlayers().first,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return seekFrame }
        // Before a scheduled `play(at:)` start arrives, sampleTime is negative;
        // don't let the position (and thus seekFrame) drop below zero.
        let elapsed = max(0, playerTime.sampleTime)
        guard let loop = scheduledLoop, loop.end > loop.start else {
            return max(0, seekFrame + elapsed)
        }
        let leadIn = max(0, loop.end - seekFrame)
        if elapsed < leadIn { return seekFrame + elapsed }
        return loop.start + (elapsed - leadIn) % (loop.end - loop.start)
    }

    private func startDisplayTimer() {
        stopDisplayTimer()
        var lastFrame = currentFrame()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self else { return }
            let frame = self.currentFrame()
            self.currentTime = min(Double(frame) / self.sampleRate, self.duration)
            // Loop wrapped B → A (position went backwards): the lock screen
            // extrapolates linearly, so correct it — on every wrap including the
            // first one after the lead-in, and at the moment it's actually played
            // (loop-pass completions fire when data is consumed, i.e. early).
            if self.scheduledLoop != nil, frame < lastFrame {
                self.updateNowPlayingInfo()
            }
            lastFrame = frame
            // End of song: stop and notify (auto-advance to the next).
            // A looping schedule never reaches the end.
            if self.scheduledLoop == nil, frame >= self.totalFrames, self.totalFrames > 0 {
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
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
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
