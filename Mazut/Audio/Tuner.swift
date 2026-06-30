//
//  Tuner.swift
//  Mazut
//
//  Štimer za gitaru. Snima sa mikrofona preko sopstvenog AVAudioEngine-a i
//  detektuje osnovnu frekvenciju (pitch) YIN algoritmom u Swiftu (Accelerate),
//  pa je mapira na najbližu notu + odstupanje u centima. Podržava standardni i
//  alternativne štimove (Drop D, Open G…), kao i čisto hromatski režim.
//
//  Monofona detekcija (jedna žica u trenutku) je mnogo lakša od separacije —
//  YIN je tačan baš na niskim frekvencijama (niska E ~82 Hz) i otporan na
//  harmonike, gde FFT-pristup često „pogreši oktavu".
//

import AVFoundation
import Accelerate
import Observation

// MARK: - Štim

/// Jedan preset štima: ime + 6 žica izraženih kao MIDI brojevi (od najniže ka
/// najvišoj). Prazan `strings` znači hromatski režim (bez ciljnih žica).
struct GuitarTuning: Identifiable, Hashable {
    let name: String
    /// MIDI brojevi žica, niska → visoka. Prazno = hromatski.
    let strings: [Int]

    var id: String { name }
    var isChromatic: Bool { strings.isEmpty }

    /// Indeks žice (0–5) najbliže datoj MIDI noti, ili nil u hromatskom režimu.
    func nearestString(toMidi midi: Int) -> Int? {
        guard !strings.isEmpty else { return nil }
        return strings.indices.min { abs(strings[$0] - midi) < abs(strings[$1] - midi) }
    }

    // E2=40, A2=45, D3=50, G3=55, B3=59, E4=64
    static let standard = GuitarTuning(name: "Standardni (E)", strings: [40, 45, 50, 55, 59, 64])
    static let dropD    = GuitarTuning(name: "Drop D",         strings: [38, 45, 50, 55, 59, 64])
    static let dropC    = GuitarTuning(name: "Drop C",         strings: [36, 43, 48, 53, 57, 62])
    static let halfStep = GuitarTuning(name: "Pola tona niže (Eb)", strings: [39, 44, 49, 54, 58, 63])
    static let openG    = GuitarTuning(name: "Open G",         strings: [38, 43, 50, 55, 59, 62])
    static let openD    = GuitarTuning(name: "Open D",         strings: [38, 45, 50, 54, 57, 62])
    static let dadgad   = GuitarTuning(name: "DADGAD",         strings: [38, 45, 50, 55, 57, 62])
    static let chromatic = GuitarTuning(name: "Hromatski",     strings: [])

    static let all: [GuitarTuning] = [
        .standard, .dropD, .dropC, .halfStep, .openG, .openD, .dadgad, .chromatic,
    ]
}

// MARK: - Štimer engine

@Observable
final class Tuner {

    // MARK: Javno stanje (UI ga posmatra)

    private(set) var isRunning = false
    /// Ima li trenutno upotrebljivog (periodičnog, dovoljno glasnog) tona.
    private(set) var hasSignal = false
    /// Detektovana frekvencija u Hz (zaglađena), 0 ako nema signala.
    private(set) var frequency: Double = 0
    /// Najbliža nota kao MIDI broj.
    private(set) var midiNote: Int = 0
    /// Odstupanje od te note u centima (−50…+50; 0 = u štimu).
    private(set) var cents: Double = 0
    /// Dozvola za mikrofon odbijena → UI prikazuje uputstvo.
    private(set) var permissionDenied = false

    /// Izabran štim (UI bira; utiče samo na prikaz ciljnih žica).
    var tuning: GuitarTuning = .standard

    /// Ime note bez oktave radi velikog prikaza, npr. "E", "A#".
    var noteName: String { Tuner.noteName(forMidi: midiNote) }
    /// Ime note sa oktavom, npr. "E2".
    var noteNameWithOctave: String { Tuner.noteName(forMidi: midiNote, withOctave: true) }

    // MARK: Audio graf

    private let engine = AVAudioEngine()
    /// Zaseban red za YIN analizu — da se DSP ne radi na audio I/O niti.
    nonisolated private let analysisQueue = DispatchQueue(label: "com.tarmi.Mazut.tuner")
    /// Poslednjih nekoliko frekvencija za medijansko zaglađivanje (gasi „skok oktave").
    private var history: [Double] = []

    /// Akumulator sempla preko više tap-bafera. Tap može da isporuči kratke
    /// bafere; za nisku E (~82 Hz) YIN-u treba bar 2 periode (~1170 sempl na
    /// 48 kHz) u prozoru, pa skupljamo do `windowSamples` pre analize. Diramo
    /// ga ISKLJUČIVO sa `analysisQueue` (serijski → bez trke).
    @ObservationIgnored nonisolated(unsafe) private var ring: [Float] = []
    /// ~170 ms na 48 kHz — dovoljno za nisku E sa rezervom, a i dalje lagano.
    private static let windowSamples = 8192

    // MARK: Kontrola

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning else { return }
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
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        hasSignal = false
        history.removeAll()
        analysisQueue.async { [weak self] in self?.ring.removeAll(keepingCapacity: true) }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func beginCapture() {
        configureSession()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sr = format.sampleRate
        guard sr > 0 else { return }

        analysisQueue.async { [weak self] in self?.ring.removeAll(keepingCapacity: true) }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let samples = Tuner.monoSamples(buffer) else { return }
            // DSP van glavnog aktora; rezultat se vraća na main radi objave.
            self.analysisQueue.async {
                // Akumuliraj pa zadrži samo poslednjih `windowSamples` (klizni prozor).
                self.ring.append(contentsOf: samples)
                if self.ring.count > Self.windowSamples {
                    self.ring.removeFirst(self.ring.count - Self.windowSamples)
                }
                guard self.ring.count >= Self.windowSamples else { return }
                let freq = Tuner.detectPitch(self.ring, sampleRate: sr)
                Task { @MainActor in self.apply(freq) }
            }
        }

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
        } catch {
            print("Tuner start error: \(error)")
            input.removeTap(onBus: 0)
        }
    }

    /// Primeni novu (sirovu) frekvenciju: zaglađivanje + mapiranje na notu.
    private func apply(_ freq: Double) {
        guard freq > 0 else { hasSignal = false; return }
        history.append(freq)
        if history.count > 5 { history.removeFirst() }
        let f = Tuner.median(history)
        let (midi, c) = Tuner.midiAndCents(forFrequency: f)
        frequency = f
        midiNote = midi
        cents = c
        hasSignal = true
    }

    // MARK: Dozvola + sesija

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
        // .measurement gasi obradu (AGC/EQ) → tačnija frekvencija.
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try? session.setActive(true)
        #endif
    }
}

// MARK: - Čista DSP/teorija (nonisolated, bez stanja)

extension Tuner {

    /// Spoji buffer u mono [Float] (prvi kanal je dovoljan za štimer).
    nonisolated static func monoSamples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let ch = buffer.floatChannelData else { return nil }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: n))
    }

    // Opseg gitare: niska E ~82 Hz, sa rezervom 60 Hz; gornja granica ~1200 Hz.
    private static let minFreq = 60.0
    private static let maxFreq = 1200.0
    private static let rmsGate: Float = 0.01   // ispod ovog = tišina

    /// YIN detekcija osnovne frekvencije. Vrati Hz, ili 0 ako ton nije
    /// dovoljno periodičan/glasan.
    nonisolated static func detectPitch(_ samples: [Float], sampleRate: Double) -> Double {
        let n = samples.count
        let maxTau = min(n / 2, Int(sampleRate / minFreq))
        let minTau = max(2, Int(sampleRate / maxFreq))
        guard maxTau > minTau + 1 else { return 0 }

        // Kapija po jačini (RMS) — ne „lovimo" šum.
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(n))
        guard rms >= rmsGate else { return 0 }

        // 1) Funkcija razlike d(τ) = Σ_j (x[j] − x[j+τ])²
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

        // 2) Kumulativna srednja normalizovana razlika d'(τ)
        var cmnd = [Float](repeating: 1, count: maxTau)
        var running: Float = 0
        for tau in 1..<maxTau {
            running += diff[tau]
            cmnd[tau] = running > 0 ? diff[tau] * Float(tau) / running : 1
        }

        // 3) Apsolutni prag → prvi lokalni minimum ispod praga
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

        // 4) Parabolička interpolacija oko minimuma → preciznija perioda
        let betterTau = parabolicMin(cmnd, found)
        return betterTau > 0 ? sampleRate / betterTau : 0
    }

    /// Subsempl-tačan minimum parabolom kroz (τ−1, τ, τ+1).
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

    /// Frekvencija → (najbliža MIDI nota, odstupanje u centima).
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
