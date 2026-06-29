//
//  Metronome.swift
//  Mazut
//
//  Jednostavan, uzorkom-tačan metronom. Koristi sopstveni AVAudioEngine i
//  jedan player node u koji se ubacuje bafer jednog takta (klik na svaki
//  dobar, akcenat na prvi) koji se vrti u petlji. Tako tempo ne „klizi".
//

import AVFoundation
import Observation

@Observable
final class Metronome {

    /// Tempo u otkucajima u minuti.
    var bpm: Int = 120 {
        didSet { if isRunning, bpm != oldValue { reschedule() } }
    }
    /// Broj dobara u taktu (npr. 4 = 4/4).
    var beatsPerMeasure: Int = 4 {
        didSet { if isRunning, beatsPerMeasure != oldValue { reschedule() } }
    }

    private(set) var isRunning = false
    /// Trenutni dobar (0-baziran) — za vizuelni indikator.
    private(set) var currentBeat = 0

    // MARK: - Audio graf

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44_100
    private let format: AVAudioFormat
    /// Dužina takta u frejmovima (za računanje trenutnog dobra).
    private var measureFrames: AVAudioFramePosition = 0
    private var displayTimer: Timer?

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    // MARK: - Kontrola

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

    /// Tempo/takt promenjen dok svira — ponovo zakaži petlju.
    private func reschedule() {
        player.stop()
        scheduleLoop()
        player.play()
    }

    // MARK: - Bafer takta

    private func scheduleLoop() {
        let buffer = makeMeasureBuffer()
        measureFrames = AVAudioFramePosition(buffer.frameLength)
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    }

    /// Bafer jednog takta: kratak klik na početku svakog dobra; prvi dobar
    /// je viši i glasniji (akcenat).
    private func makeMeasureBuffer() -> AVAudioPCMBuffer {
        let framesPerBeat = max(1, Int(sampleRate * 60.0 / Double(bpm)))
        let total = framesPerBeat * beatsPerMeasure
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let samples = buffer.floatChannelData![0]
        for i in 0..<total { samples[i] = 0 }   // tišina između klikova

        let clickFrames = min(framesPerBeat, Int(sampleRate * 0.03))
        let decay = sampleRate * 0.008   // brza eksponencijalna envelopa
        for beat in 0..<beatsPerMeasure {
            // Akcenat (viši/glasniji klik) samo kad ima više dobara; 1/1 = ravan klik.
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

    // MARK: - Vizuelni indikator (trenutni dobar)

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
