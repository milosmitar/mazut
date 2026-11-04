//
//  Tuner.swift
//  Mazut
//
//  Guitar tuner. Records from the microphone via its own AVAudioEngine and
//  detects the fundamental frequency (pitch) with a YIN algorithm in Swift
//  (Accelerate), then maps it to the nearest note + deviation in cents.
//  Supports standard and alternative tunings (Drop D, Open G…), as well as a
//  pure chromatic mode.
//
//  Monophonic detection (one string at a time) is much easier than separation —
//  YIN is accurate right down to low frequencies (low E ~82 Hz) and resistant
//  to harmonics, where an FFT-based approach often "gets the octave wrong".
//

import AVFoundation
import Accelerate
import Observation

// MARK: - Tuning

/// A single tuning preset: name + 6 strings expressed as MIDI numbers (lowest to
/// highest). An empty `strings` means chromatic mode (no target strings).
struct GuitarTuning: Identifiable, Hashable {
    let name: String
    /// MIDI numbers of the strings, low → high. Empty = chromatic.
    let strings: [Int]

    var id: String { name }
    var isChromatic: Bool { strings.isEmpty }

    /// Index of the string (0–5) nearest the given MIDI note, or nil in chromatic mode.
    func nearestString(toMidi midi: Int) -> Int? {
        guard !strings.isEmpty else { return nil }
        return strings.indices.min { abs(strings[$0] - midi) < abs(strings[$1] - midi) }
    }

    // E2=40, A2=45, D3=50, G3=55, B3=59, E4=64
    static let standard = GuitarTuning(name: "Standard (E)", strings: [40, 45, 50, 55, 59, 64])
    static let dropD    = GuitarTuning(name: "Drop D",         strings: [38, 45, 50, 55, 59, 64])
    static let dropC    = GuitarTuning(name: "Drop C",         strings: [36, 43, 48, 53, 57, 62])
    static let halfStep = GuitarTuning(name: "Half step down (Eb)", strings: [39, 44, 49, 54, 58, 63])
    static let openG    = GuitarTuning(name: "Open G",         strings: [38, 43, 50, 55, 59, 62])
    static let openD    = GuitarTuning(name: "Open D",         strings: [38, 45, 50, 54, 57, 62])
    static let dadgad   = GuitarTuning(name: "DADGAD",         strings: [38, 45, 50, 55, 57, 62])
    static let chromatic = GuitarTuning(name: "Chromatic",     strings: [])

    static let all: [GuitarTuning] = [
        .standard, .dropD, .dropC, .halfStep, .openG, .openD, .dadgad, .chromatic,
    ]
}

// MARK: - Tuner engine

@Observable
final class Tuner {

    // MARK: Public state (observed by the UI)

    private(set) var isRunning = false
    /// Whether there's currently a usable (periodic, loud enough) tone.
    private(set) var hasSignal = false
    /// Detected frequency in Hz (smoothed), 0 if there's no signal.
    private(set) var frequency: Double = 0
    /// Nearest note as a MIDI number.
    private(set) var midiNote: Int = 0
    /// Deviation from that note in cents (−50…+50; 0 = in tune).
    private(set) var cents: Double = 0
    /// Microphone permission denied → UI shows instructions.
    private(set) var permissionDenied = false
    /// Why the microphone isn't listening although it was asked to — it couldn't
    /// open, or a call took the audio. Without it a listener waits forever.
    private(set) var failure: String?

    /// Selected tuning (chosen by the UI; only affects the display of target strings).
    var tuning: GuitarTuning = .standard

    /// Every smoothed reading as it is published — `nil` while there is no usable
    /// tone — with the newest buffer's RMS level. For listeners that need each
    /// reading rather than the latest state: the note trainer counts how long a
    /// note has been held, and tells a fresh pluck from a ringing string by the
    /// level jumping.
    @ObservationIgnored var onReading: ((_ midi: Int?, _ cents: Double, _ level: Float) -> Void)?
    /// Called when the microphone stops on its own — see `failure`.
    @ObservationIgnored var onFailure: (() -> Void)?

    /// Note name without octave, for the large display, e.g. "E", "A#".
    var noteName: String { Tuner.noteName(forMidi: midiNote) }
    /// Note name with octave, e.g. "E2".
    var noteNameWithOctave: String { Tuner.noteName(forMidi: midiNote, withOctave: true) }

    // MARK: Audio graph

    private let engine = AVAudioEngine()
    /// Set between `start()` and the capture beginning; cleared by `stop()`, so a
    /// stop during the permission prompt is not lost and a second start does not
    /// install a second tap (which AVAudioEngine answers with a crash).
    @ObservationIgnored private var startRequested = false
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    /// Separate queue for YIN analysis — so DSP doesn't run on the audio I/O thread.
    nonisolated private let analysisQueue = DispatchQueue(label: "com.tarmi.Mazut.tuner")
    /// The last few frequencies for median smoothing (suppresses "octave jumps").
    private var history: [Double] = []

    /// Sample accumulator across multiple tap buffers. The tap can deliver short
    /// buffers; for a low E (~82 Hz) YIN needs at least 2 periods (~1170 samples at
    /// 48 kHz) in the window, so we collect up to `windowSamples` before analyzing.
    /// Touched ONLY from `analysisQueue` (serial → no race).
    @ObservationIgnored nonisolated(unsafe) private var ring: [Float] = []
    /// ~170 ms at 48 kHz — enough for a low E with margin, and still light.
    private static let windowSamples = 8192

    // MARK: Control

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning, !startRequested else { return }
        // Cleared now, not after the async permission check: a failure from the
        // last session would otherwise still show (and offer Resume) meanwhile.
        failure = nil
        startRequested = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await Tuner.requestMicPermission() else {
                self.startRequested = false
                self.permissionDenied = true
                return
            }
            self.permissionDenied = false
            guard self.startRequested else { return }   // stopped while asking
            self.startRequested = false
            self.beginCapture()
        }
    }

    func stop(afterInterruption: Bool = false) {
        startRequested = false
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        hasSignal = false
        history.removeAll()
        analysisQueue.async { [weak self] in self?.ring.removeAll(keepingCapacity: true) }
        restoreSession(afterInterruption: afterInterruption)
    }

    /// Back to plain playback. Stays active if a song started while the
    /// microphone was open (play on the lock screen ends a drill) — deactivating
    /// would cut it off; otherwise deactivates so other apps can resume.
    private func restoreSession(afterInterruption: Bool = false) {
        AudioSessionHandoff.restorePlayback(keepActive: StemMixerEngine.shared.isPlaying,
                                            afterInterruption: afterInterruption)
    }

    private func fail(_ message: String) {
        failure = message
        onFailure?()
    }

    private func beginCapture() {
        failure = nil
        configureSession()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sr = format.sampleRate
        guard sr > 0 else {
            restoreSession()
            fail("Couldn't open the microphone. Check that no other app is using it.")
            return
        }

        analysisQueue.async { [weak self] in self?.ring.removeAll(keepingCapacity: true) }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let samples = Tuner.monoSamples(buffer) else { return }
            // DSP off the main actor; the result is bounced back to main for publishing.
            self.analysisQueue.async {
                // Accumulate, then keep only the last `windowSamples` (sliding window).
                self.ring.append(contentsOf: samples)
                if self.ring.count > Self.windowSamples {
                    self.ring.removeFirst(self.ring.count - Self.windowSamples)
                }
                guard self.ring.count >= Self.windowSamples else { return }
                let freq = Tuner.detectPitch(self.ring, sampleRate: sr)
                var level: Float = 0
                vDSP_rmsqv(samples, 1, &level, vDSP_Length(samples.count))
                Task { @MainActor in self.apply(freq, level: level) }
            }
        }

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
            observeInterruptions()
        } catch {
            print("Tuner start error: \(error)")
            input.removeTap(onBus: 0)
            restoreSession()
            fail("Couldn't open the microphone. Check that no other app is using it.")
        }
    }

    /// A call or Siri takes the input and stops the engine without saying so to
    /// anyone listening for readings.
    private func observeInterruptions() {
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.isRunning,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self.stop(afterInterruption: true)
            self.fail("The audio was interrupted, so the microphone stopped.")
        }
        #endif
    }

    /// Apply a new (raw) frequency: smoothing + mapping to a note.
    private func apply(_ freq: Double, level: Float) {
        // Readings already on their way when `stop()` ran would otherwise refill
        // the history and report a tone on a stopped tuner.
        guard isRunning else { return }
        guard freq > 0 else {
            hasSignal = false
            onReading?(nil, 0, level)
            return
        }
        history.append(freq)
        if history.count > 5 { history.removeFirst() }
        let f = Tuner.median(history)
        let (midi, c) = Tuner.midiAndCents(forFrequency: f)
        frequency = f
        midiNote = midi
        cents = c
        hasSignal = true
        onReading?(midi, c, level)
    }

    // MARK: Permission + session

    nonisolated static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            #if os(iOS)
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
            #else
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            #endif
        }
    }

    private func configureSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // .measurement disables processing (AGC/EQ) → more accurate frequency.
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try? session.setActive(true)
        #endif
    }
}

// MARK: - Pure DSP/theory (nonisolated, stateless)

extension Tuner {

    /// Flatten the buffer to mono [Float] (the first channel is enough for the tuner).
    nonisolated static func monoSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let ch = buffer.floatChannelData else { return nil }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: n))
    }

    // Guitar range: low E ~82 Hz, with a 60 Hz margin; upper bound ~1200 Hz.
    private static let minFreq = 60.0
    private static let maxFreq = 1200.0
    private static let rmsGate: Float = 0.01   // below this = silence

    /// YIN fundamental-frequency detection. Returns Hz, or 0 if the tone isn't
    /// periodic/loud enough.
    nonisolated static func detectPitch(_ samples: [Float], sampleRate: Double) -> Double {
        let n = samples.count
        let maxTau = min(n / 2, Int(sampleRate / minFreq))
        let minTau = max(2, Int(sampleRate / maxFreq))
        guard maxTau > minTau + 1 else { return 0 }

        // Gate by loudness (RMS) — don't chase noise.
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(n))
        guard rms >= rmsGate else { return 0 }

        // 1) Difference function d(τ) = Σ_j (x[j] − x[j+τ])²
        var diff = [Float](repeating: 0, count: maxTau)
        var temp = [Float](repeating: 0, count: n)
        samples.withUnsafeBufferPointer { x in
            guard let base = x.baseAddress else { return }
            for tau in 1..<maxTau {
                let count = vDSP_Length(n - tau)
                // temp = x[j] − x[j+tau]   (vDSP_vsub: C = A − B, A=base, B=base+tau)
                vDSP_vsub(base + tau, 1, base, 1, &temp, 1, count)
                var sum: Float = 0
                vDSP_svesq(temp, 1, &sum, count)
                diff[tau] = sum
            }
        }

        // 2) Cumulative mean normalized difference d'(τ)
        var cmnd = [Float](repeating: 1, count: maxTau)
        var running: Float = 0
        for tau in 1..<maxTau {
            running += diff[tau]
            cmnd[tau] = running > 0 ? diff[tau] * Float(tau) / running : 1
        }

        // 3) Absolute threshold → first local minimum below the threshold
        let threshold: Float = 0.15
        var tau = minTau
        var found = -1
        while tau < maxTau {
            if cmnd[tau] < threshold {
                while tau + 1 < maxTau && cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                found = tau
                break
            }
            tau += 1
        }
        guard found > 0 else { return 0 }

        // 4) Parabolic interpolation around the minimum → more precise period
        let betterTau = parabolicMin(cmnd, found)
        return betterTau > 0 ? sampleRate / betterTau : 0
    }

    /// Sub-sample-accurate minimum via a parabola through (τ−1, τ, τ+1).
    nonisolated private static func parabolicMin(_ d: [Float], _ tau: Int) -> Double {
        guard tau > 0, tau < d.count - 1 else { return Double(tau) }
        let s0 = Double(d[tau - 1]), s1 = Double(d[tau]), s2 = Double(d[tau + 1])
        let denom = s0 - 2 * s1 + s2
        guard denom != 0 else { return Double(tau) }
        return Double(tau) + (s0 - s2) / (2 * denom)
    }

    nonisolated private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count.isMultiple(of: 2) ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// Frequency → (nearest MIDI note, deviation in cents).
    nonisolated static func midiAndCents(forFrequency f: Double) -> (midi: Int, cents: Double) {
        let exact = 69 + 12 * log2(f / 440)
        let midi = Int(exact.rounded())
        return (midi, (exact - Double(midi)) * 100)
    }

    nonisolated static func noteName(forMidi midi: Int, withOctave: Bool = false) -> String {
        let name = noteNames[((midi % 12) + 12) % 12]
        return withOctave ? "\(name)\(midi / 12 - 1)" : name
    }
}
