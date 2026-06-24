//
//  StemMixerEngine.swift
//  Mazut
//
//  AVAudioEngine graf koji svira vise stemova sinhronizovano, sa zasebnom
//  kontrolom jacine / mute / solo po stemu i zajednickim transportom
//  (play / pause / seek).
//

import AVFoundation
import Observation

@Observable
final class StemMixerEngine {

    // MARK: - Javno stanje (UI ga posmatra)

    private(set) var isPlaying = false
    /// Trajanje najduzeg ucitanog stema, u sekundama.
    private(set) var duration: TimeInterval = 0
    /// Trenutna pozicija reprodukcije u sekundama.
    var currentTime: TimeInterval = 0
    private(set) var isLoaded = false

    // MARK: - Audio graf

    private let engine = AVAudioEngine()

    /// Po jedan player node + audio fajl za svaki StemKind.
    private struct Track {
        let player = AVAudioPlayerNode()
        var file: AVAudioFile?
    }
    private var tracks: [StemKind: Track] = [:]

    /// Referenca na Stem modele kako bi engine citao volume/mute/solo.
    private var stems: [StemKind: Stem] = [:]

    /// Frame sa kog krece reprodukcija (za seek / resume).
    private var seekFrame: AVAudioFramePosition = 0
    /// Sample rate referentnog fajla.
    private var sampleRate: Double = 44_100
    /// Ukupan broj frejmova najduzeg stema.
    private var totalFrames: AVAudioFramePosition = 0

    /// Timer koji osvezava currentTime dok svira.
    private var displayTimer: Timer?

    init() {
        for kind in StemKind.allCases {
            tracks[kind] = Track()
        }
    }

    // MARK: - Ucitavanje

    /// Ucitava stemove i pravi audio graf. `stems` su modeli iz UI-ja.
    func load(stems: [Stem]) throws {
        stop()
        engine.stop()
        // Skini sve stare nodove sa grafa.
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

    /// Oslobodi sve stemove i vrati engine u prazno stanje (UI → izbor pesme).
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

        // Sinhronizovan start: svi nodovi krecu na isti buduci sample time.
        guard let anyPlayer = activePlayers().first,
              let renderTime = anyPlayer.lastRenderTime ?? engine.outputNode.lastRenderTime
        else {
            activePlayers().forEach { $0.play() }
            isPlaying = true
            startDisplayTimer()
            return
        }

        let startSample = renderTime.sampleTime + AVAudioFramePosition(sampleRate * 0.1)
        let startTime = AVAudioTime(sampleTime: startSample, atRate: sampleRate)
        for player in activePlayers() {
            player.play(at: startTime)
        }
        isPlaying = true
        startDisplayTimer()
    }

    func pause() {
        guard isPlaying else { return }
        // Zapamti gde smo stali pre nego sto zaustavimo nodove.
        seekFrame = currentFrame()
        activePlayers().forEach { $0.stop() }
        isPlaying = false
        stopDisplayTimer()
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

    /// Premotavanje na zadato vreme u sekundama.
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
    }

    // MARK: - Mix kontrola (volume / mute / solo)

    /// Primeni jacinu i mute/solo logiku na sve player nodove.
    /// Pozvati svaki put kad korisnik promeni slider ili dugme.
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
    }

    // MARK: - Pomocno

    private func activePlayers() -> [AVAudioPlayerNode] {
        tracks.values.filter { $0.file != nil }.map { $0.player }
    }

    /// Zakazi reprodukciju svih fajlova od seekFrame do kraja.
    private func scheduleFromSeekFrame() {
        for (_, track) in tracks {
            guard let file = track.file else { continue }
            let frameCount = AVAudioFrameCount(max(0, file.length - seekFrame))
            guard frameCount > 0 else { continue }
            track.player.scheduleSegment(file,
                                         startingFrame: seekFrame,
                                         frameCount: frameCount,
                                         at: nil)
        }
    }

    /// Trenutni frame na osnovu pozicije player node-a.
    private func currentFrame() -> AVAudioFramePosition {
        guard let player = activePlayers().first,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return seekFrame }
        return seekFrame + playerTime.sampleTime
    }

    private func startDisplayTimer() {
        stopDisplayTimer()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self else { return }
            let frame = self.currentFrame()
            self.currentTime = min(Double(frame) / self.sampleRate, self.duration)
            // Auto-stop na kraju pesme.
            if frame >= self.totalFrames, self.totalFrames > 0 {
                self.pause()
                self.seekFrame = 0
                self.currentTime = 0
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
}
