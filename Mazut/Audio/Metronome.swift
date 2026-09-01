//
//  Metronome.swift
//  Mazut
//
//  A simple, sample-accurate metronome. Uses its own AVAudioEngine and a
//  single player node fed with a looping one-measure buffer — a click on every
//  beat (accented on the first), or a synthesized drum groove. This way the
//  tempo never "drifts".
//

import AVFoundation
import Observation

/// What the metronome plays on each beat.
enum MetronomeSound: String, CaseIterable, Identifiable {
    /// Synthesized sine click (accented first beat).
    case click
    /// Synthesized drum kit: kick on the accented beat, hi-hat on the others.
    case drums

    var id: String { rawValue }

    var label: String {
        switch self {
        case .click: return "Click"
        case .drums: return "Drums"
        }
    }

    var symbol: String {
        switch self {
        case .click: return "metronome"
        case .drums: return "music.note"
        }
    }
}

/// A one-measure drum pattern on a fixed grid.
///
/// `steps` has `beats * stepsPerBeat` entries, one per grid slot; each is a
/// string of voice letters — `K` kick, `S` snare, `H` hi-hat, `-` rest
/// (e.g. `"KH"` = kick and hi-hat together).
struct DrumPattern {
    let beats: Int
    let stepsPerBeat: Int
    let steps: [String]
}

/// Drum groove played when `MetronomeSound.drums` is selected.
enum DrumGroove: String, CaseIterable, Identifiable {
    /// Plain metronome in drum voices: kick on the accent, hi-hat on the rest.
    /// The only groove that follows the user's time-signature setting.
    case basic
    case rock
    case shuffle
    case funk
    case waltz
    case bossa

    var id: String { rawValue }

    var label: String {
        switch self {
        case .basic:   return "Basic"
        case .rock:    return "Rock"
        case .shuffle: return "Shuffle"
        case .funk:    return "Funk"
        case .waltz:   return "Waltz"
        case .bossa:   return "Bossa"
        }
    }

    /// `nil` for `.basic`, which follows `Metronome.beatsPerMeasure` instead.
    var pattern: DrumPattern? {
        switch self {
        case .basic:
            return nil
        // Straight 8ths: kick on 1 and 3, snare on 2 and 4.
        case .rock:
            return DrumPattern(beats: 4, stepsPerBeat: 2, steps: [
                "KH", "H", "SH", "H", "KH", "H", "SH", "H",
            ])
        // Triplet feel: hi-hat on the 1st and 3rd triplet of each beat.
        case .shuffle:
            return DrumPattern(beats: 4, stepsPerBeat: 3, steps: [
                "KH", "-", "H", "SH", "-", "H", "KH", "-", "H", "SH", "-", "H",
            ])
        // 16th grid, hats on the 8ths, syncopated kick.
        case .funk:
            return DrumPattern(beats: 4, stepsPerBeat: 4, steps: [
                "KH", "-", "H", "K", "SH", "-", "H", "-",
                "H",  "-", "KH", "-", "SH", "-", "H", "K",
            ])
        // 3/4: kick on 1, snare on 2 and 3.
        case .waltz:
            return DrumPattern(beats: 3, stepsPerBeat: 2, steps: [
                "KH", "H", "SH", "H", "SH", "H",
            ])
        // Hats on the 8ths, surdo-style kick, 3-2 clave on the rim (snare).
        case .bossa:
            return DrumPattern(beats: 4, stepsPerBeat: 4, steps: [
                "KSH", "-", "H", "S", "KH", "-", "SH", "-",
                "KH",  "-", "SH", "-", "KSH", "-", "H", "-",
            ])
        }
    }

    /// Fixed number of beats per measure, or `nil` when the groove follows the setting.
    var beats: Int? { pattern?.beats }
}

@Observable
final class Metronome {

    /// Tempo in beats per minute.
    var bpm: Int = 120 {
        didSet { if isRunning, bpm != oldValue { reschedule() } }
    }
    /// Number of beats per measure (e.g. 4 = 4/4).
    var beatsPerMeasure: Int = 4 {
        didSet { if isRunning, beatsPerMeasure != oldValue { reschedule() } }
    }
    /// Click or drum kit.
    var sound: MetronomeSound = .click {
        didSet { if isRunning, sound != oldValue { reschedule() } }
    }
    /// Drum groove — only used when `sound == .drums`.
    var groove: DrumGroove = .basic {
        didSet { if isRunning, sound == .drums, groove != oldValue { reschedule() } }
    }

    /// Beats per measure actually being played: a fixed groove overrides the setting.
    var activeBeatsPerMeasure: Int {
        if sound == .drums, let beats = groove.beats { return beats }
        return beatsPerMeasure
    }

    /// Set by `TimingCoach` while it owns the audio session (`.playAndRecord`) —
    /// the metronome must not switch the category back to `.playback` under it.
    var sessionOwnedExternally = false

    private(set) var isRunning = false
    /// Current beat (0-based) — for the visual indicator.
    private(set) var currentBeat = 0

    // MARK: - Audio graph

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44_100
    private let format: AVAudioFormat
    /// Measure length in frames (for computing the current beat).
    private var measureFrames: AVAudioFramePosition = 0
    private var displayTimer: Timer?

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    // MARK: - Control

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning else { return }
        configureSession()
        scheduleLoop()
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            print("Metronome start error: \(error)")
            return
        }
        player.play()
        isRunning = true
        currentBeat = 0
        startDisplayTimer()
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        isRunning = false
        currentBeat = 0
        stopDisplayTimer()
    }

    /// Tempo/time signature changed while playing — reschedule the loop.
    private func reschedule() {
        player.stop()
        scheduleLoop()
        player.play()
    }

    /// Re-establish the graph after someone else changed the session category or
    /// route (the timing coach switching to `.playAndRecord` and back).
    func restartIfRunning() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        do {
            try engine.start()
        } catch {
            print("Metronome restart error: \(error)")
            return
        }
        scheduleLoop()
        player.play()
        currentBeat = 0
    }

    // MARK: - Grid (for the timing coach)

    /// The grid a played note is judged against. A groove uses its own step
    /// resolution; everything else uses 8th notes, so playing between the clicks
    /// isn't reported as being half a beat late.
    var gridStepsPerMeasure: Int {
        var subdivision = 2
        if sound == .drums, let pattern = groove.pattern {
            subdivision = max(pattern.stepsPerBeat, 2)
        }
        return activeBeatsPerMeasure * subdivision
    }

    /// How far a note played at `hostTime` sits from the nearest grid step, in
    /// seconds (positive = late). `nil` while the metronome is stopped.
    ///
    /// The comparison happens on the timeline the player *hears*, so the click's
    /// output latency is taken out; the caller is expected to have already taken
    /// out the microphone's input latency.
    func deviation(atHostTime hostTime: UInt64) -> Double? {
        guard isRunning, measureFrames > 0,
              let nodeTime = player.lastRenderTime, nodeTime.isHostTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return nil }
        let elapsed = AVAudioTime.seconds(forHostTime: hostTime)
            - AVAudioTime.seconds(forHostTime: nodeTime.hostTime)
        let position = Double(playerTime.sampleTime) / sampleRate + elapsed - outputLatency
        let step = Double(measureFrames) / sampleRate / Double(gridStepsPerMeasure)
        guard step > 0 else { return nil }
        // Distance to the nearest step, so the result lands in ±step/2.
        return position - (position / step).rounded() * step
    }

    private var outputLatency: Double {
        #if os(iOS)
        AVAudioSession.sharedInstance().outputLatency
        #else
        0
        #endif
    }

    // MARK: - Measure buffer

    private func scheduleLoop() {
        let buffer = makeMeasureBuffer()
        measureFrames = AVAudioFramePosition(buffer.frameLength)
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    }

    /// One-measure buffer. Click and the `.basic` groove put one voice at the
    /// start of every beat (accented first); any other groove renders its own
    /// step grid instead. Voices ring past their step and wrap around the loop
    /// point, so a tail is not cut off when the measure repeats.
    private func makeMeasureBuffer() -> AVAudioPCMBuffer {
        let framesPerBeat = max(1, Int(sampleRate * 60.0 / Double(bpm)))
        let beats = activeBeatsPerMeasure
        let total = framesPerBeat * beats
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let samples = buffer.floatChannelData![0]
        for i in 0..<total { samples[i] = 0 }   // silence between hits

        var rng: UInt64 = 0x9E3779B97F4A7C15
        if sound == .drums, let pattern = groove.pattern {
            let stepCount = pattern.beats * pattern.stepsPerBeat
            for (i, step) in pattern.steps.prefix(stepCount).enumerated() {
                // Integer split so steps stay evenly spread with no rounding drift.
                let start = total * i / stepCount
                for voice in step {
                    switch voice {
                    case "K": renderKick(samples, total: total, at: start, rng: &rng)
                    case "S": renderSnare(samples, total: total, at: start, rng: &rng)
                    case "H": renderHiHat(samples, total: total, at: start, rng: &rng)
                    default: break
                    }
                }
            }
        } else {
            for beat in 0..<beats {
                // Accent only when there's more than one beat; 1/1 stays flat.
                let isAccent = beats > 1 && beat == 0
                let start = beat * framesPerBeat
                switch sound {
                case .click:
                    renderClick(samples, total: total, at: start, accent: isAccent)
                case .drums:
                    if isAccent || beats == 1 {
                        renderKick(samples, total: total, at: start, rng: &rng)
                    } else {
                        renderHiHat(samples, total: total, at: start, rng: &rng)
                    }
                }
            }
        }
        normalize(samples, count: total)
        return buffer
    }

    /// Overlapping voices can sum past full scale — scale the measure down if they do.
    private func normalize(_ out: UnsafeMutablePointer<Float>, count: Int) {
        var peak: Float = 0
        for i in 0..<count { peak = max(peak, abs(out[i])) }
        guard peak > 0.95 else { return }
        let gain = 0.95 / peak
        for i in 0..<count { out[i] *= gain }
    }

    // MARK: - Voices

    private func renderClick(_ out: UnsafeMutablePointer<Float>, total: Int, at start: Int,
                             accent: Bool) {
        let frames = min(total, Int(sampleRate * 0.03))
        let decay = sampleRate * 0.008
        let freq = accent ? 1_500.0 : 1_000.0
        let amp: Float = accent ? 0.9 : 0.55
        for n in 0..<frames {
            let t = Double(n) / sampleRate
            let env = Float(exp(-Double(n) / decay))
            out[(start + n) % total] += Float(sin(2 * .pi * freq * t)) * env * amp
        }
    }

    /// Kick: sine whose pitch drops 140 → 48 Hz, with a short noise transient for attack.
    private func renderKick(_ out: UnsafeMutablePointer<Float>, total: Int, at start: Int,
                            rng: inout UInt64) {
        let frames = min(total, Int(sampleRate * 0.28))
        let transient = min(frames, Int(sampleRate * 0.004))
        var phase = 0.0
        for n in 0..<frames {
            let t = Double(n) / sampleRate
            let freq = 48 + 92 * exp(-t / 0.025)
            phase += 2 * .pi * freq / sampleRate
            let env = Float(exp(-t / 0.11))
            var s = Float(sin(phase)) * env * 0.85
            if n < transient { s += whiteNoise(&rng) * Float(1 - Double(n) / Double(transient)) * 0.25 }
            out[(start + n) % total] += s
        }
    }

    /// Hi-hat: white noise through a one-pole high-pass, very fast decay.
    private func renderHiHat(_ out: UnsafeMutablePointer<Float>, total: Int, at start: Int,
                             rng: inout UInt64) {
        let frames = min(total, Int(sampleRate * 0.07))
        var prevIn: Float = 0
        var prevOut: Float = 0
        for n in 0..<frames {
            let x = whiteNoise(&rng)
            prevOut = 0.87 * (prevOut + x - prevIn)
            prevIn = x
            let env = Float(exp(-Double(n) / sampleRate / 0.012))
            out[(start + n) % total] += prevOut * env * 0.4
        }
    }

    /// Snare: band-limited noise body plus a short 185 Hz tone for the drum shell.
    private func renderSnare(_ out: UnsafeMutablePointer<Float>, total: Int, at start: Int,
                             rng: inout UInt64) {
        let frames = min(total, Int(sampleRate * 0.18))
        var prevIn: Float = 0
        var prevOut: Float = 0
        for n in 0..<frames {
            let t = Double(n) / sampleRate
            let x = whiteNoise(&rng)
            prevOut = 0.7 * (prevOut + x - prevIn)   // mild high-pass, keeps some body
            prevIn = x
            let noiseEnv = Float(exp(-t / 0.055))
            let tone = Float(sin(2 * .pi * 185 * t)) * Float(exp(-t / 0.03)) * 0.3
            out[(start + n) % total] += prevOut * noiseEnv * 0.5 + tone
        }
    }

    private func whiteNoise(_ state: inout UInt64) -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
    }

    // MARK: - Visual indicator (current beat)

    private func startDisplayTimer() {
        stopDisplayTimer()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateBeat()
        }
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func updateBeat() {
        let beats = activeBeatsPerMeasure
        guard measureFrames > 0, beats > 0,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return }
        let pos = ((playerTime.sampleTime % measureFrames) + measureFrames) % measureFrames
        let framesPerBeat = measureFrames / AVAudioFramePosition(beats)
        let beat = Int(pos / max(1, framesPerBeat))
        if beat != currentBeat { currentBeat = beat }
    }

    private func configureSession() {
        guard !sessionOwnedExternally else { return }   // the coach needs .playAndRecord
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
    }
}
