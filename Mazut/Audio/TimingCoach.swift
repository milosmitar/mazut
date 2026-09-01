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

    /// True when the output route is a built-in speaker, i.e. the microphone is
    /// about to hear the metronome as well as the player.
    var hearsMetronomeOverSpeaker: Bool {
        #if os(iOS)
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        #else
        false
        #endif
    }

    // MARK: Audio graph

    private let engine = AVAudioEngine()
    /// Detection runs off the audio I/O thread, as in `Tuner`.
    nonisolated private let analysisQueue = DispatchQueue(label: "com.tarmi.Mazut.timing")
    /// Touched ONLY from `analysisQueue` (serial → no race).
    @ObservationIgnored nonisolated(unsafe) private var detector = OnsetDetector()
    private weak var metronome: Metronome?

    // MARK: Control

    func toggle(metronome: Metronome) { isListening ? stop() : start(metronome: metronome) }

    func start(metronome: Metronome) {
        guard !isListening else { return }
        self.metronome = metronome
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await Tuner.requestMicPermission() else {
                self.permissionDenied = true
                return
            }
            self.permissionDenied = false
            self.beginCapture()
        }
    }

    func stop() {
        guard isListening else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isListening = false
        // Hand the session back: the metronome sets its own category again.
        metronome?.sessionOwnedExternally = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        metronome?.restartIfRunning()
    }

    func reset() { hits.removeAll() }

    private func beginCapture() {
        configureSession()
        // The category change moved the route; the metronome's engine has to
        // follow it or it keeps rendering into the old one.
        metronome?.restartIfRunning()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return }

        analysisQueue.async { [weak self] in self?.detector = OnsetDetector(sampleRate: sampleRate) }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self, let samples = Tuner.monoSamples(buffer) else { return }
            // The tap's timestamp is the start of this buffer on the host clock;
            // it is the only link between what was played and the click track.
            guard time.isHostTimeValid else { return }
            let bufferHostTime = time.hostTime
            self.analysisQueue.async {
                let onsets = self.detector.process(samples)
                guard !onsets.isEmpty else { return }
                let hostTimes = onsets.map { offset -> UInt64 in
                    Self.hostTime(bufferHostTime, plus: Double(offset) / sampleRate - Self.inputLatency)
                }
                Task { @MainActor in for t in hostTimes { self.register(hostTime: t) } }
            }
        }

        engine.prepare()
        do {
            try engine.start()
            isListening = true
            hits.removeAll()
        } catch {
            print("TimingCoach start error: \(error)")
            input.removeTap(onBus: 0)
            metronome?.sessionOwnedExternally = false   // don't leave the session hostage
        }
    }

    /// Grade one detected note against the metronome grid.
    private func register(hostTime: UInt64) {
        guard let deviation = metronome?.deviation(atHostTime: hostTime) else { return }
        hits.append(Hit(deviationMs: deviation * 1000))
        if hits.count > Self.historyLimit { hits.removeFirst(hits.count - Self.historyLimit) }
    }

    // MARK: Session + clock

    private func configureSession() {
        metronome?.sessionOwnedExternally = true
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // .measurement turns off AGC/EQ — processing would smear the attacks the
        // detector keys on. No .defaultToSpeaker: this mode is meant for headphones.
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothA2DP])
        try? session.setActive(true)
        #endif
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

    private let sampleRate: Double
    private let fastCoef: Float
    private let noiseCoef: Float
    private let refractory: Int

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
    mutating func process(_ samples: [Float]) -> [Int] {
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
