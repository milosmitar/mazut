//
//  StemMixerEngine.swift
//  Mazut
//
//  AVAudioEngine graf koji svira vise stemova sinhronizovano, sa zasebnom
//  kontrolom jacine / mute / solo po stemu i zajednickim transportom
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

    /// Jedina instanca. Engine u `init()` vezuje globalne mostove (remote
    /// komande, prekidi sesije, StemToggleBox za Live Activity) — sme da
    /// postoji samo jedan, inače poslednja konstruisana (prazna) instanca
    /// pregazi mostove i dugmići sa zaključanog ekrana rade u prazno.
    static let shared = StemMixerEngine()

    // MARK: - Javno stanje (UI ga posmatra)

    private(set) var isPlaying = false
    /// Trajanje najduzeg ucitanog stema, u sekundama.
    private(set) var duration: TimeInterval = 0
    /// Trenutna pozicija reprodukcije u sekundama.
    var currentTime: TimeInterval = 0
    private(set) var isLoaded = false

    /// Pozove se (na glavnoj niti) kada pesma stigne prirodno do kraja —
    /// koristi se za automatski prelazak na sledeću pesmu.
    var onPlaybackFinished: (() -> Void)?

    /// Komande „sledeća" / „prethodna" sa zaključanog ekrana ili slušalica.
    var onRemoteNext: (() -> Void)?
    var onRemotePrevious: (() -> Void)?

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

    // MARK: - Zaključani ekran (Now Playing)

    /// Metapodaci trenutne pesme za zaključani ekran / Control Center.
    private var npTitle = ""
    private var npArtist = ""
    private var npArtwork: MPMediaItemArtwork?

    /// Live Activity kartica sa dugmićima za kanale na zaključanom ekranu.
    private let liveActivity = StemActivityController()

    private init() {
        for kind in StemKind.allCases {
            tracks[kind] = Track()
        }
        setupRemoteCommands()
        observeInterruptions()
        // Dugme na Live Activity kartici → pali/gasi kanal.
        StemToggleBox.shared.onToggle = { [weak self] index in
            self?.toggleStem(at: index)
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

        // Sinhronizovan start: svi nodovi krecu na isti buduci sample time.
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
        // Zapamti gde smo stali pre nego sto zaustavimo nodove.
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
        updateNowPlayingInfo()
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
        liveActivity.update(state: activityState())
    }

    /// Pali/gasi kanal sa Live Activity kartice. Ako je solo aktivan, prvo se
    /// trenutna čujnost „zamrzne" u mute flagove pa se solo ugasi — da dugmići
    /// na kartici uvek rade predvidljivo (šta vidiš, to i čuješ).
    func toggleStem(at index: Int) {
        let kinds = StemKind.allCases
        guard kinds.indices.contains(index), let target = stems[kinds[index]] else {
            Logger(subsystem: "com.tarmi.Mazut", category: "intent")
                .warning("toggleStem: kanal \(index) ne postoji ili nije učitan")
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

    // MARK: - Pomocno

    private func activePlayers() -> [AVAudioPlayerNode] {
        tracks.values.filter { $0.file != nil }.map { $0.player }
    }

    /// Zakazi reprodukciju svih fajlova od seekFrame do kraja.
    private func scheduleFromSeekFrame() {
        // Odbrana: startingFrame mora biti u [0, file.length].
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

    /// Trenutni frame na osnovu pozicije player node-a.
    private func currentFrame() -> AVAudioFramePosition {
        guard let player = activePlayers().first,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return seekFrame }
        // Pre nego sto zakazani `play(at:)` start stigne, sampleTime je negativan;
        // ne dozvoli da pozicija (a samim tim i seekFrame) padne ispod nule.
        return max(0, seekFrame + playerTime.sampleTime)
    }

    private func startDisplayTimer() {
        stopDisplayTimer()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self else { return }
            let frame = self.currentFrame()
            self.currentTime = min(Double(frame) / self.sampleRate, self.duration)
            // Kraj pesme: zaustavi i javi (auto-prelazak na sledeću).
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

    // MARK: - Zaključani ekran / Control Center

    /// Postavi metapodatke pesme koji se prikazuju na zaključanom ekranu.
    /// Pozvati posle `load(stems:)`; prazan naslov briše prikaz.
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

    /// Trenutno stanje za Live Activity karticu: čujnost svakog kanala
    /// (mute/solo logika kao u `applyMixToAllTracks`), da li svira i naslov.
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

    /// Osveži stanje na zaključanom ekranu (naslov, trajanje, pozicija, da li svira).
    /// Sistem sam ekstrapolira poziciju preko `rate`, pa je dovoljno zvati ovo
    /// na play/pause/seek, ne na svaki otkucaj tajmera.
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

    /// Registruj komande sa zaključanog ekrana / slušalica. Handleri mogu stići
    /// van glavne niti, pa se rad prebacuje na main.
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

    /// Prekidi audio sesije (telefonski poziv, Siri…) i izvučene slušalice.
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
                // Nastavi samo ako sistem kaže da treba (npr. kraj poziva).
                let opts = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume) {
                    self.play()
                }
            @unknown default:
                break
            }
        }
        // Izvučene slušalice / prekinut Bluetooth → pauza (standardno ponašanje).
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
