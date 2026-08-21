//
//  Metronome.swift
//  Mazut
//
//  A simple, sample-accurate metronome. Uses its own AVAudioEngine and a
//  single player node fed with a one-measure buffer (a click on every beat,
//  accented on the first) that loops. This way the tempo never "drifts".
//

import AVFoundation
import Observation

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

    // MARK: - Measure buffer

    private func scheduleLoop() {
        let buffer = makeMeasureBuffer()
        measureFrames = AVAudioFramePosition(buffer.frameLength)
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    }

    /// One-measure buffer: a short click at the start of every beat; the first
    /// beat is higher-pitched and louder (accented).
    private func makeMeasureBuffer() -> AVAudioPCMBuffer {
        let framesPerBeat = max(1, Int(sampleRate * 60.0 / Double(bpm)))
        let total = framesPerBeat * beatsPerMeasure
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let samples = buffer.floatChannelData![0]
        for i in 0..<total { samples[i] = 0 }   // silence between clicks

        let clickFrames = min(framesPerBeat, Int(sampleRate * 0.03))
        let decay = sampleRate * 0.008   // fast exponential envelope
        for beat in 0..<beatsPerMeasure {
            // Accent (higher-pitched/louder click) only when there's more than one beat; 1/1 = flat click.
            let isAccent = beatsPerMeasure > 1 && beat == 0
            let freq = isAccent ? 1_500.0 : 1_000.0
            let amp: Float = isAccent ? 0.9 : 0.55
            let start = beat * framesPerBeat
            for n in 0..<clickFrames {
                let t = Double(n) / sampleRate
                let env = Float(exp(-Double(n) / decay))
                samples[start + n] = Float(sin(2 * .pi * freq * t)) * env * amp
            }
        }
        return buffer
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
        guard measureFrames > 0, beatsPerMeasure > 0,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return }
        let pos = ((playerTime.sampleTime % measureFrames) + measureFrames) % measureFrames
        let framesPerBeat = measureFrames / AVAudioFramePosition(beatsPerMeasure)
        let beat = Int(pos / max(1, framesPerBeat))
        if beat != currentBeat { currentBeat = beat }
    }

    private func configureSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
    }
}
