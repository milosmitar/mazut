//
//  TimingCoach.swift
//  Mazut
//
//  Listens through the microphone while the metronome runs and reports, for
//  every note played, how far it landed from the nearest grid step — early
//  (rushing) or late (dragging).
//
//  Headphones are assumed. There is no echo cancellation here: over the speaker
//  the microphone would hear the metronome itself, exactly on the beat, and the
//  coach would happily grade its own click as a perfect performance. The UI says
//  so; `hearsMetronomeOverSpeaker` reports when the current route is a speaker so
//  the warning can be made loud.
//
//  Onset detection is time-domain (see `OnsetDetector`): a played attack is a
//  sharp rise above the recent level, which is enough for anything percussive or
//  plucked and costs a fraction of a spectral-flux analysis.
//

import AVFoundation
import Observation

@Observable
final class TimingCoach {

    /// One detected note and how far it sat from the nearest grid step.
    struct Hit: Identifiable {
        let id = UUID()
        /// Positive = late (dragging), negative = early (rushing).
        let deviationMs: Double
        var isOnTime: Bool { abs(deviationMs) <= TimingCoach.toleranceMs }
    }

    /// A note inside this window counts as on the beat.
    static let toleranceMs = 25.0
    /// How many recent notes the score is computed over.
    private static let historyLimit = 16

    // MARK: Public state (observed by the UI)

    private(set) var isListening = false
    /// Microphone permission denied → the UI shows instructions.
    private(set) var permissionDenied = false
    /// Why the last start attempt didn't take, for the UI to show.
    private(set) var failure: String?
    /// Most recent notes, oldest first.
    private(set) var hits: [Hit] = []

    var lastHit: Hit? { hits.last }
    /// Share of recent notes inside the tolerance window (0…1), nil below 4 notes.
    var accuracy: Double? {
        guard hits.count >= 4 else { return nil }
        return Double(hits.filter(\.isOnTime).count) / Double(hits.count)
    }
    /// Mean deviation — the systematic part: consistently ahead of or behind the beat.
    var averageOffsetMs: Double? {
        guard hits.count >= 4 else { return nil }
        return hits.map(\.deviationMs).reduce(0, +) / Double(hits.count)
    }

    /// True when the output route is a built-in speaker, i.e. the microphone
    /// would hear the metronome as well as the player. Stored rather than
    /// computed: the UI has to re-render when the route changes, and a computed
    /// property reading `AVAudioSession` is outside the observation graph.
    /// Any other route — wired, Bluetooth, USB, AirPlay — counts as headphones.
    private(set) var hearsMetronomeOverSpeaker = true

    /// Smoothed input peak (0…1) — the UI shows it so a silent microphone is
    /// visibly silent instead of looking like a detector that never fires.
    private(set) var inputLevel: Float = 0

    /// Diagnostics, shown while listening. Together they say which stage is dead:
    /// no notes at all = the microphone or the thresholds; notes but nothing
    /// graded = the click track can't be read.
    private(set) var detectedNotes = 0
    private(set) var gradedNotes = 0
    private(set) var inputSampleRate: Double = 0

    // MARK: Audio graph

    /// No engine of its own: the tap goes on the metronome's engine. See
    /// `Metronome.attachInputTap`.
    /// Detection runs off the audio I/O thread, as in `Tuner`.
    nonisolated private let analysisQueue = DispatchQueue(label: "com.tarmi.Mazut.timing")
    /// Touched ONLY from `analysisQueue` (serial → no race).
    @ObservationIgnored nonisolated(unsafe) private var detector = OnsetDetector()
    /// Host time of the last level update, to publish at ~20 Hz instead of per buffer.
    @ObservationIgnored nonisolated(unsafe) private var lastLevelUpdate: Double = 0
    /// Peak since the last published level — a per-buffer peak would miss the
    /// attacks that land in the buffers between two publishes.
    @ObservationIgnored nonisolated(unsafe) private var pendingPeak: Float = 0
    @ObservationIgnored private var routeObserver: NSObjectProtocol?
    /// Set between the button tap and `beginCapture()`; cleared by `stop()` so a
    /// cancel during the permission prompt doesn't start capturing afterwards.
    @ObservationIgnored private var startRequested = false
    private weak var metronome: Metronome?

    init() {
        // Observed for the whole lifetime, not just while listening: the button
        // is enabled off this state, so it has to be right before the first tap.
        observeRouteChanges()
        refreshRoute()
    }

    deinit { stopObservingRouteChanges() }

    // MARK: Control

    func toggle(metronome: Metronome) { isListening ? stop() : start(metronome: metronome) }

    func start(metronome: Metronome) {
        guard !isListening else { return }
        self.metronome = metronome
        startRequested = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await Tuner.requestMicPermission() else {
                self.startRequested = false
                self.permissionDenied = true
                return
            }
            self.permissionDenied = false
            self.beginCapture()
        }
    }

    func stop() {
        startRequested = false   // cancels a start still waiting on the permission prompt
        guard isListening else { return }
        isListening = false
        inputLevel = 0
        inputSampleRate = 0
        metronome?.onInputTapLost = nil
        metronome?.detachInputTap()
        // Hand the session back: the metronome sets its own category again.
        metronome?.sessionOwnedExternally = false
        restoreSession()
    }

    func reset() { hits.removeAll() }

    private func beginCapture() {
        // The permission prompt is async: by the time it resolves the metronome
        // may have stopped or the tab may have changed. Starting anyway would
        // leave the session stuck in .playAndRecord with no way back.
        guard startRequested, let metronome, metronome.isRunning else {
            startRequested = false
            return
        }
        startRequested = false
        configureSession()

        analysisQueue.async { [weak self] in self?.detector = OnsetDetector() }
        let tap: AVAudioNodeTapBlock = { [weak self] buffer, time in
            guard let self, let samples = Tuner.monoSamples(buffer) else { return }
            let sampleRate = buffer.format.sampleRate
            guard sampleRate > 0 else { return }
            // The tap's timestamp is the start of this buffer on the host clock;
            // it is the only link between what was played and the click track.
            // Without one the buffer has to go: `mach_absolute_time()` here is the
            // *delivery* time, a whole buffer period later (~21 ms at 48 kHz), and
            // would report every note as dragging by about the tolerance window.
            guard time.isHostTimeValid else { return }
            let bufferHostTime = time.hostTime
            self.analysisQueue.async {
                let onsets = self.detector.process(samples, sampleRate: sampleRate)
                self.pendingPeak = samples.reduce(self.pendingPeak) { max($0, abs($1)) }
                let hostTimes = onsets.map { offset -> UInt64 in
                    Self.hostTime(bufferHostTime, plus: Double(offset) / sampleRate - Self.inputLatency)
                }
                let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                let peak = self.pendingPeak
                let publishLevel = now - self.lastLevelUpdate > 0.05
                if publishLevel {
                    self.lastLevelUpdate = now
                    self.pendingPeak = 0
                }
                guard !hostTimes.isEmpty || publishLevel else { return }
                Task { @MainActor in
                    if publishLevel { self.updateLevel(peak) }
                    for t in hostTimes { self.register(hostTime: t) }
                }
            }
        }

        // An engine rebuild would silently throw the tap away — stop instead of
        // staying green with no buffers arriving.
        metronome.onInputTapLost = { [weak self] in self?.stop() }

        // One engine for click + microphone; two of them fight over the route.
        guard let rate = metronome.attachInputTap(bufferSize: 1024, block: tap) else {
            print("TimingCoach: microphone input unavailable")
            // Say it out loud: silently not turning green is indistinguishable
            // from a dead button.
            failure = "Couldn't open the microphone. Try again."
            metronome.onInputTapLost = nil
            metronome.sessionOwnedExternally = false   // don't leave the session hostage
            restoreSession()
            return
        }
        failure = nil
        inputSampleRate = rate
        hits.removeAll()
        detectedNotes = 0
        gradedNotes = 0
        isListening = true
        refreshRoute()
    }

    /// Tracks the output route: it decides whether measuring is possible at all,
    /// and headphones pulled mid-session take the tap and the click's connections
    /// with them without anything else reporting it.
    ///
    /// Watching the *route* rather than the engine's configuration is deliberate:
    /// engaging the microphone reconfigures the engine ourselves, so an
    /// engine-level observer tears down the setup it has just seen created.
    private func observeRouteChanges() {
        #if os(iOS)
        stopObservingRouteChanges()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            self.refreshRoute()
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard self.isListening, let raw,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
            else { return }
            self.stop()
        }
        #endif
    }

    /// Re-read the output route. Public so the UI can ask before the session has
    /// ever been activated, when the route is still unknown.
    func refreshRoute() {
        #if os(iOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        // An unknown route counts as a speaker: refusing to measure is the safe
        // side of that guess, since measuring the metronome's own click reports
        // a flawless take to someone who played nothing.
        hearsMetronomeOverSpeaker = outputs.isEmpty || outputs.contains { $0.portType == .builtInSpeaker }
        #else
        hearsMetronomeOverSpeaker = false
        #endif
    }

    private func stopObservingRouteChanges() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
    }

    /// Peak level with a slow fall, so the meter doesn't flicker between buffers.
    private func updateLevel(_ peak: Float) {
        inputLevel = peak > inputLevel ? peak : inputLevel * 0.8 + peak * 0.2
    }

    /// Grade one detected note against the metronome grid.
    private func register(hostTime: UInt64) {
        detectedNotes += 1
        // Over the speaker every "note" is really the metronome's own click,
        // landing on the beat by construction. Grading those would report a
        // flawless performance to someone who played nothing at all.
        guard !hearsMetronomeOverSpeaker else { return }
        guard let deviation = metronome?.deviation(atHostTime: hostTime) else { return }
        gradedNotes += 1
        hits.append(Hit(deviationMs: deviation * 1000))
        if hits.count > Self.historyLimit { hits.removeFirst(hits.count - Self.historyLimit) }
    }

    // MARK: Session + clock

    private func configureSession() {
        metronome?.sessionOwnedExternally = true
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Mode is `.default`, not `.measurement`: measurement mode gives the
        // cleanest transients for detection but drops output level so far that
        // the click all but disappears — and a metronome you can't hear is not a
        // metronome. `.defaultToSpeaker` keeps playback off the earpiece, which
        // is where plain `.playAndRecord` would put it.
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setActive(true)
        #endif
    }

    private func restoreSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        metronome?.restartIfRunning()
    }

    /// Delay between a sound reaching the microphone and its samples arriving in the tap.
    nonisolated private static var inputLatency: Double {
        #if os(iOS)
        AVAudioSession.sharedInstance().inputLatency
        #else
        0
        #endif
    }

    nonisolated private static func hostTime(_ base: UInt64, plus seconds: Double) -> UInt64 {
        let shifted = AVAudioTime.seconds(forHostTime: base) + seconds
        return AVAudioTime.hostTime(forSeconds: max(0, shifted))
    }
}

// MARK: - Onset detection

/// Time-domain transient detector.
///
/// A note attack is a short burst well above the level just before it, so the
/// rectified, pre-emphasised signal is compared against two trackers: a fast one
/// (~60 ms) that represents "what was already sounding", and a slow one (~2 s)
/// that represents room noise. A rise above both, outside the refractory window,
/// is an onset. Both trackers are updated *after* the test so an attack never
/// raises the bar it has to clear.
struct OnsetDetector {

    private var sampleRate: Double
    private var fastCoef: Float
    private var noiseCoef: Float
    private var refractory: Int

    private var fast: Float = 0
    private var noise: Float = 0.001
    private var previous: Float = 0
    private var sinceOnset = Int.max

    /// A note must stand this far above what was already sounding.
    private static let riseFactor: Float = 3
    /// …and this far above the room noise, so a quiet room doesn't self-trigger.
    private static let noiseFactor: Float = 8
    /// Absolute floor — below this it is silence, whatever the ratios say.
    private static let silenceFloor: Float = 0.006

    init(sampleRate: Double = 44_100) {
        self.sampleRate = sampleRate
        fastCoef = Float(1 - exp(-1 / (0.06 * sampleRate)))
        noiseCoef = Float(1 - exp(-1 / (2.0 * sampleRate)))
        refractory = Int(0.08 * sampleRate)   // 80 ms — no double-triggering on one attack
    }

    /// Offsets, in samples from the start of this buffer, of the onsets found.
    /// The hardware rate is only known once buffers start arriving, so the
    /// detector re-tunes itself the first time it sees a different one.
    mutating func process(_ samples: [Float], sampleRate: Double) -> [Int] {
        if sampleRate != self.sampleRate { self = OnsetDetector(sampleRate: sampleRate) }
        var onsets: [Int] = []
        for (i, sample) in samples.enumerated() {
            // Pre-emphasis: removes rumble/DC and lifts the attack over the body.
            let magnitude = abs(sample - 0.97 * previous)
            previous = sample

            if sinceOnset < Int.max { sinceOnset += 1 }
            let threshold = max(fast * Self.riseFactor, noise * Self.noiseFactor, Self.silenceFloor)
            if magnitude > threshold, sinceOnset > refractory {
                onsets.append(i)
                sinceOnset = 0
            }

            fast += (magnitude - fast) * fastCoef
            noise += (magnitude - noise) * noiseCoef
        }
        return onsets
    }
}
