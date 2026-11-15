//
//  TimingCoach.swift
//  Mazut
//
//  Listens through the microphone while the metronome runs and reports, for
//  every note played, how far it landed from the nearest grid step — early
//  (rushing) or late (dragging).
//
//  Onset detection is time-domain (see `OnsetDetector`): a played attack is a
//  sharp rise above the recent level, which is enough for anything percussive or
//  plucked and costs a fraction of a spectral-flux analysis.
//
//  The hard part is the metronome itself. Over a speaker the microphone hears the
//  click, and a detector that can hear it reports a flawless performance to
//  someone who played nothing — the click lands on the beat by construction.
//
//  With headphones there is nothing to remove. Over the phone's own speaker the
//  click is swapped for a tick a few milliseconds long and `ClickCanceller`
//  takes it back out of the microphone signal; the reasoning and the
//  measurements behind it are on that type. Anything else that plays out loud
//  (AirPlay, HDMI, a car) is refused: its delay is neither known nor steady.
//
//  What was tried before and did not survive a real phone, so nobody tries it
//  again:
//  - Notch filters on the click's tones. The click reaches the microphone
//    through the phone's body as a thump and a rattle, nowhere near the notches.
//  - Learning the click's echo once, in a quiet countdown, and subtracting it.
//    Every volume step, route settle or stray sound in the countdown ended the
//    take. (`ClickCanceller` also subtracts a learned echo, but keeps learning,
//    only ever from clicks heard in quiet, and blanks what subtraction can't
//    reach.)
//  - The system echo canceller (voice processing). It removes the click
//    superbly — 70 dB — by turning the microphone down while the click sounds:
//    a note under way is cut off at the click, one starting within 30 ms of it
//    is swallowed or reported late. A dead zone of about 50 ms centred on the
//    beat, which is the one place this feature has to measure.
//

import AVFoundation
import Observation

@Observable
final class TimingCoach {

    /// One detected note and how far it sat from the nearest grid step.
    struct Hit: Identifiable {
        let id = UUID()
        /// Position in the take — the chart's x axis, so notes stay in order and
        /// keep their spacing as the window scrolls.
        let index: Int
        /// Positive = late (dragging), negative = early (rushing).
        let deviationMs: Double
        var isOnTime: Bool { abs(deviationMs) <= TimingCoach.toleranceMs }
    }

    /// How a whole take went, built when listening stops. Kept separately from
    /// `hits` because that is a rolling window — the score for a take has to
    /// count every note, not the last 32.
    struct Summary: Identifiable {
        let id = UUID()
        let notes: Int
        let onTime: Int
        /// Mean deviation: the systematic part, ahead of or behind the beat.
        let averageMs: Double
        /// Standard deviation: how consistent the playing was, apart from any
        /// constant offset. A steady player who is always 30 ms late has a large
        /// average and a small spread.
        let spreadMs: Double
        let earliestMs: Double
        let latestMs: Double
        /// The tail of the take, for the chart.
        let tape: [Hit]

        var accuracy: Double { notes > 0 ? Double(onTime) / Double(notes) : 0 }
    }

    /// Why listening ended. Only a take the user ended themselves earns a
    /// verdict; everything else is an interruption.
    enum StopReason { case user, interrupted }

    /// A normal graded take, or measuring the headphones' hidden latency.
    enum Mode { case take, calibration }

    /// What the player is playing between the clicks — the grid every note is
    /// placed on. The click itself never plays it; it only decides which step a
    /// note belongs to, so triplets aren't graded as 8ths half a step off.
    enum Subdivision: Int, CaseIterable, Identifiable {
        case eighths = 2, triplets = 3, sixteenths = 4
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .eighths: return "8ths"
            case .triplets: return "Triplets"
            case .sixteenths: return "16ths"
            }
        }
    }

    /// The stored latency correction for the current headphones.
    struct Calibration: Equatable {
        let routeName: String
        let offsetMs: Double
    }

    /// A note inside this window counts as on the beat.
    static let toleranceMs = 25.0
    /// Seconds after the microphone opens before notes count. Engaging the input
    /// renegotiates the route (an A2DP headset has no input side), and the route
    /// is only judged once that has settled.
    private static let warmUpSeconds = 1.0
    /// No microphone audio for this long means the capture died under the take.
    /// Longer than a Bluetooth renegotiation's gap, far shorter than a player
    /// takes to notice a dead readout.
    private static let stallSeconds = 1.5
    /// Below this a take is too short to say anything about.
    private static let minimumNotesForSummary = 4
    /// How many notes the chart keeps.
    static let historyLimit = 32
    /// Notes collected in a calibration run, and how many of the first ones are
    /// thrown away while the player locks onto the click.
    static let calibrationNotes = 16
    static let calibrationLeadIn = 4
    /// Calibration is refused when the notes scatter more than this (median
    /// absolute deviation): the offset would be a guess.
    private static let calibrationMaxScatterMs = 15.0
    /// A real route's hidden latency stays well under this; beyond it the notes
    /// were most likely landing on the wrong click.
    private static let calibrationMaxOffsetMs = 200.0
    private static let calibrationStoreKey = "timingLatencyOffsets"
    /// Click-echo guard: among the last `echoWindow` notes, `echoHits` or more
    /// inside a `echoSpreadMs` band means the microphone is hearing the click —
    /// it arrives at the same delay every beat, which no player manages.
    private static let echoWindow = 16
    private static let echoHits = 12
    private static let echoSpreadMs = 3.0

    /// How many of the most recent notes the score is computed over — shorter
    /// than the chart, so the percentage reacts to what is being played now.
    private static let scoreWindow = 16

    // MARK: Public state (observed by the UI)

    /// The last recorded take (WAV + notes), for sharing. Takes are recorded
    /// only while the hidden `debugRecordingKey` switch is on.
    private(set) var lastRecording: [URL] = []
    static let debugRecordingKey = "timingDebugRecording"
    /// Whether the running take has `ClickCanceller` taking the tick out.
    private(set) var clickMasking = false
    /// While a speaker take is still learning what the tick sounds like: how
    /// many quiet ticks it has heard so far, out of `clickLearningNeeded`. The
    /// player has to stay quiet for these, so the UI counts them down; notes are
    /// not graded until it is nil again.
    private(set) var clickLearningProgress: Int?
    /// The click is clipping the microphone on a speaker take: the volume
    /// should come down a little, or clicks start slipping through as notes.
    private(set) var clickOverloading = false
    /// How many clicks the current speaker take listens to before grading.
    private(set) var clickLearningNeeded = 4

    /// The grid notes are placed on. Changed only between takes (the UI hides
    /// it while listening): a take graded across two grids means nothing.
    var subdivision: Subdivision = Subdivision(
        rawValue: UserDefaults.standard.integer(forKey: TimingCoach.subdivisionKey)) ?? .eighths {
        didSet { UserDefaults.standard.set(subdivision.rawValue, forKey: Self.subdivisionKey) }
    }
    /// Grade only the notes that land on a click; the ones between are heard
    /// and placed on the grid, then left out of the score.
    var gradesBeatsOnly: Bool = UserDefaults.standard.bool(forKey: TimingCoach.beatsOnlyKey) {
        didSet { UserDefaults.standard.set(gradesBeatsOnly, forKey: Self.beatsOnlyKey) }
    }
    private static let subdivisionKey = "timingSubdivision"
    private static let beatsOnlyKey = "timingBeatsOnly"

    private(set) var isListening = false
    /// What the current (or last) listening session is for.
    private(set) var mode: Mode = .take
    /// Notes collected so far in a calibration run (lead-in included).
    private(set) var calibrationCount = 0
    /// Shown after a successful calibration.
    private(set) var calibrationMessage: String?
    /// The stored correction for the headphones currently connected, nil when
    /// they have never been calibrated. Refreshed on every route change.
    private(set) var currentCalibration: Calibration?
    /// Microphone permission denied → the UI shows instructions.
    private(set) var permissionDenied = false
    /// Why the last start attempt didn't take, for the UI to show.
    private(set) var failure: String?
    /// Most recent notes, oldest first.
    private(set) var hits: [Hit] = []

    var lastHit: Hit? { hits.last }
    /// The notes the score is computed over.
    private var scored: [Hit] { Array(hits.suffix(Self.scoreWindow)) }
    /// How many notes that is. The live percentage counts this window while the
    /// summary counts the whole take, so the UI has to name what it is scoring —
    /// otherwise a take that started badly reads 94% live and 61% one frame later.
    var scoredCount: Int { min(hits.count, Self.scoreWindow) }
    /// Share of recent notes inside the tolerance window (0…1), nil below 4 notes.
    var accuracy: Double? {
        let recent = scored
        guard recent.count >= 4 else { return nil }
        return Double(recent.filter(\.isOnTime).count) / Double(recent.count)
    }
    /// Mean deviation — the systematic part: consistently ahead of or behind the beat.
    var averageOffsetMs: Double? {
        let recent = scored
        guard recent.count >= 4 else { return nil }
        return recent.map(\.deviationMs).reduce(0, +) / Double(recent.count)
    }

    /// Smoothed input peak (0…1) — the UI shows it so a silent microphone is
    /// visibly silent instead of looking like a detector that never fires.
    private(set) var inputLevel: Float = 0

    /// Diagnostics, shown while listening. Together they say which stage is dead:
    /// no notes at all = the microphone or the thresholds; notes but nothing
    /// graded = the click track can't be read.
    private(set) var detectedNotes = 0
    /// Notes measured against the grid. Doubles as the take's note count and as
    /// the next note's x position on the chart — they are the same number.
    private(set) var gradedNotes = 0
    private(set) var inputSampleRate: Double = 0
    /// The output latency the system reports, in ms — the one figure every note
    /// is corrected by and nothing checks. Shown, so a take where every note is
    /// "late" by the same amount on Bluetooth can be read for what it is.
    private(set) var outputLatencyMs: Double?
    /// The calibrated correction applied to this take, in ms (0 = none).
    private(set) var appliedOffsetMs: Double = 0
    /// Where the canceller last found the tick on a speaker take, in ms —
    /// kept through the warm-up so the offset applies from the first note.
    @ObservationIgnored private var tickOffsetMs: Double?

    // Running totals for the whole take (`hits` only keeps the last 32).
    @ObservationIgnored private var takeOnTime = 0
    @ObservationIgnored private var takeSum = 0.0
    @ObservationIgnored private var takeSumOfSquares = 0.0
    @ObservationIgnored private var takeMin = 0.0
    @ObservationIgnored private var takeMax = 0.0
    /// Raw deviations collected by a calibration run.
    @ObservationIgnored private var calibrationSamples: [Double] = []
    /// Raw deviations of the most recent notes, for the click-echo guard.
    @ObservationIgnored private var recentRaw: [Double] = []
    /// This take runs over the phone's speaker, with the short tick and
    /// `ClickCanceller`. Decided once, when the take starts.
    @ObservationIgnored private var speakerTake = false
    /// Re-learns the tick when the volume moves under a speaker take.
    @ObservationIgnored private var volumeObservation: NSKeyValueObservation?
    /// Where the running take is being recorded; nil when it isn't.
    @ObservationIgnored private var debugWavURL: URL?
    /// "file sample, loop position" pairs tying the recording to the click track.
    @ObservationIgnored private var debugAnchors: [String] = []
    @ObservationIgnored private var debugDeviations: [String] = []
    // Touched ONLY from `analysisQueue`.
    @ObservationIgnored nonisolated(unsafe) private var canceller: ClickCanceller?
    /// Microphone samples seen since the tap started — the canceller's clock.
    @ObservationIgnored nonisolated(unsafe) private var inputSampleCount: Int64 = 0
    /// Microphone samples of the latest onsets, for `ClickCanceller.isUndetected`.
    @ObservationIgnored nonisolated(unsafe) private var recentOnsets: [Int64] = []
    @ObservationIgnored nonisolated(unsafe) private var debugFile: AVAudioFile?
    @ObservationIgnored nonisolated(unsafe) private var debugRecording = false
    @ObservationIgnored nonisolated(unsafe) private var debugSamplesWritten: Int64 = 0
    /// The route the take/calibration runs on, fixed once it has settled.
    @ObservationIgnored private var routeKey: String?

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
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    /// Set between the button tap and `beginCapture()`; cleared by `stop()` so a
    /// cancel during the permission prompt doesn't start capturing afterwards.
    @ObservationIgnored private var startRequested = false
    /// The route is still settling after the input was engaged: route changes
    /// are ignored and notes are not graded. Cleared by `watchTask`, which then
    /// judges the settled route.
    @ObservationIgnored private var settling = false
    /// Judges the route after the warm-up, then watches for the audio stopping.
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    /// When the microphone's audio last reached the main actor.
    @ObservationIgnored private var lastAudioAt = Date()
    private weak var metronome: Metronome?

    init() {
        observeRouteChanges()
        refreshCalibration()
    }

    deinit {
        stopObservingRouteChanges()
        stopObservingInterruptions()
    }

    // MARK: Control

    /// Start a graded take, or — with `calibrate` — a run that measures the
    /// latency the system doesn't report (Bluetooth codecs mostly) and stores it
    /// for the current headphones.
    func start(metronome: Metronome, calibrate: Bool = false) {
        guard !isListening else { return }
        mode = calibrate ? .calibration : .take
        calibrationMessage = nil
        // Refused before the microphone opens: engaging it only to tear it down
        // a second later flashes the readout and glitches the click.
        if Self.clickGoesToSpeaker() {
            if calibrate {
                failure = Self.calibrationNeedsHeadphones
                return
            }
            guard Self.clickGoesToPhoneSpeaker() else {
                failure = Self.needsHeadphones
                return
            }
            guard metronome.tickLayout != nil else {
                failure = Self.speakerNeedsClick
                return
            }
        }
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

    /// Stop listening, returning the take's summary when the user ended it and
    /// enough notes were measured — nil for every other reason. The rule lives
    /// here rather than at the call site: `stop()` runs on several paths (button,
    /// tab change, unplugged headphones, lost tap) and only one of them is a
    /// finished take.
    @discardableResult
    func stop(reason: StopReason = .interrupted, afterInterruption: Bool = false) -> Summary? {
        startRequested = false   // cancels a start still waiting on the permission prompt
        watchTask?.cancel()
        watchTask = nil
        settling = false
        guard isListening else { return nil }
        finishRecording()
        speakerTake = false
        volumeObservation?.invalidate()
        volumeObservation = nil
        clickMasking = false
        clickOverloading = false
        clickLearningProgress = nil
        let summary = reason == .user ? makeSummary() : nil
        isListening = false   // stops grading notes still in flight on the analysis queue
        inputLevel = 0
        inputSampleRate = 0
        outputLatencyMs = nil
        appliedOffsetMs = 0
        tickOffsetMs = nil
        routeKey = nil
        calibrationSamples = []
        calibrationCount = 0
        recentRaw = []
        stopObservingInterruptions()
        metronome?.onInputTapLost = nil
        metronome?.onGridChanged = nil
        metronome?.shortClick = false
        metronome?.detachInputTap()
        // Hand the session back: the metronome sets its own category again.
        metronome?.sessionOwnedExternally = false
        restoreSession(afterInterruption: afterInterruption)
        return summary
    }

    private func beginCapture() {
        // The permission prompt is async: by the time it resolves the metronome
        // may have stopped or the tab may have changed. Starting anyway would
        // leave the session stuck in .playAndRecord with no way back.
        guard startRequested, let metronome, metronome.isRunning else {
            startRequested = false
            return
        }
        startRequested = false
        // Read before the session changes: under `.playback` the route is where
        // the click is going right now.
        speakerTake = mode == .take && Self.clickGoesToPhoneSpeaker() && metronome.tickLayout != nil
        let recordURL = UserDefaults.standard.bool(forKey: Self.debugRecordingKey)
            ? Self.newRecordingURL(speaker: speakerTake) : nil
        debugWavURL = recordURL
        debugAnchors = []
        debugDeviations = []
        configureSession()

        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.detector = OnsetDetector()
            self.debugFile = nil
            self.debugSamplesWritten = 0
            self.debugRecording = recordURL != nil
            self.canceller = nil
            self.inputSampleCount = 0
            self.recentOnsets = []
            // Carried over, these hand the new take the previous one's last
            // 50 ms: the meter flashes at a level nothing is producing.
            self.pendingPeak = 0
            self.lastLevelUpdate = 0
        }
        let tap: AVAudioNodeTapBlock = { [weak self] buffer, time in
            guard let self, let samples = Tuner.monoSamples(buffer) else { return }
            let sampleRate = buffer.format.sampleRate
            guard sampleRate > 0 else { return }
            // The tap's timestamp is the start of this buffer on the host clock;
            // it is the only link between what was played and the click track.
            // Without one the buffer has to go: `mach_absolute_time()` here is the
            // *delivery* time, a whole buffer period later (~21 ms at 48 kHz), and
            // would report every note as dragging by about the tolerance window.
            // Such a buffer still goes through the detector (its history stays
            // continuous) and the level meter — it is live audio, and the stall
            // watchdog must see it — only its onsets are dropped.
            let hostTimeValid = time.isHostTimeValid
            let bufferHostTime = time.hostTime
            self.analysisQueue.async {
                let bufferStart = self.inputSampleCount
                self.inputSampleCount += Int64(samples.count)
                // The recording keeps the raw microphone; the detector gets it
                // with the tick taken out.
                if let recordURL { self.record(samples, sampleRate: sampleRate, to: recordURL) }
                var heard = samples
                var candidates: [ClickCanceller.Candidate] = []
                if self.canceller != nil {
                    candidates = self.canceller?.process(&heard, firstSample: bufferStart) ?? []
                }
                var onsets = self.detector.process(heard, sampleRate: sampleRate)
                // Onsets past this index came from under the tick, not the detector.
                let detectedCount = onsets.count
                if self.canceller != nil {
                    self.recentOnsets.append(contentsOf: onsets.map { bufferStart + Int64($0) })
                    // A note that began under the tick has no attack left to
                    // detect; it is taken from the level it leaves behind.
                    for candidate in candidates
                    where ClickCanceller.isUndetected(candidate, onsets: self.recentOnsets, sampleRate: sampleRate) {
                        onsets.append(Int(candidate.sample - bufferStart))
                        self.recentOnsets.append(candidate.sample)
                    }
                    if self.recentOnsets.count > 16 { self.recentOnsets.removeFirst(self.recentOnsets.count - 16) }
                }
                self.pendingPeak = samples.reduce(self.pendingPeak) { max($0, abs($1)) }
                let hostTimes = hostTimeValid ? onsets.enumerated().map { index, offset in
                    NoteOnset(hostTime: Self.hostTime(bufferHostTime, plus: Double(offset) / sampleRate - Self.inputLatency),
                              fileSample: bufferStart + Int64(offset),
                              underTick: index >= detectedCount)
                } : []
                // nil = no canceller; otherwise how far learning has got, or
                // nil-equivalent 1 once it is ready (learned, or given up).
                let learned = self.canceller.map { $0.isReady ? 1 : min($0.learningProgress, 0.99) }
                let tickOffset = self.canceller?.tickOffsetSeconds
                let overloaded = self.canceller?.isOverloaded ?? false
                let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                let peak = self.pendingPeak
                let publishLevel = now - self.lastLevelUpdate > 0.05
                if publishLevel {
                    self.lastLevelUpdate = now
                    self.pendingPeak = 0
                }
                guard !hostTimes.isEmpty || publishLevel else { return }
                Task { @MainActor in
                    if publishLevel {
                        self.lastAudioAt = Date()
                        self.updateLevel(peak)
                        if let learned, self.isListening {
                            let progress = learned >= 1
                                ? nil : Int(learned * Double(self.clickLearningNeeded))
                            if progress != self.clickLearningProgress { self.clickLearningProgress = progress }
                        }
                        if self.isListening, overloaded != self.clickOverloading {
                            self.clickOverloading = overloaded
                        }
                        if let tickOffset, self.isListening, self.speakerTake {
                            self.tickOffsetMs = tickOffset * 1000
                        }
                        if let tickOffset, self.isListening, self.speakerTake, !self.settling,
                           self.appliedOffsetMs != tickOffset * 1000 {
                            // Where the tick really lands is the grid the player
                            // hears; see `ClickCanceller.tickOffsetSeconds`.
                            self.appliedOffsetMs = tickOffset * 1000
                        }
                        if hostTimeValid {
                            self.placeBuffer(sample: bufferStart, hostTime: bufferHostTime)
                        }
                    }
                    for note in hostTimes { self.register(note) }
                }
            }
        }

        // An engine rebuild would silently throw the tap away — stop instead of
        // staying green with no buffers arriving.
        metronome.onInputTapLost = { [weak self] in
            guard let self, self.isListening else { return }
            self.stop()
            self.failure = "Lost the microphone — start the check again."
        }

        // One engine for click + microphone; two of them fight over the route.
        metronome.shortClick = speakerTake
        guard let rate = metronome.attachInputTap(bufferSize: 1024, block: tap) else {
            print("TimingCoach: microphone input unavailable")
            speakerTake = false
            abandonRecording()
            // Say it out loud: silently not turning green is indistinguishable
            // from a dead button.
            failure = "Couldn't open the microphone. Try again."
            metronome.shortClick = false
            metronome.onInputTapLost = nil
            metronome.sessionOwnedExternally = false   // don't leave the session hostage
            restoreSession()
            return
        }
        // The canceller counts microphone samples against click frames, which
        // only works when both run at one rate. Found out here rather than a
        // second into the take.
        if speakerTake, metronome.tickLayout?.sampleRate != rate {
            speakerTake = false
            abandonRecording()
            failure = Self.speakerUnavailable
            metronome.shortClick = false
            metronome.onInputTapLost = nil
            metronome.detachInputTap()
            metronome.sessionOwnedExternally = false
            restoreSession()
            return
        }
        failure = nil
        clickLearningProgress = speakerTake ? 0 : nil
        if speakerTake, let layout = metronome.tickLayout {
            clickLearningNeeded = ClickCanceller.clicksToLearn(layout)
        }
        if speakerTake { observeVolume() }
        inputSampleRate = rate
        hits.removeAll()
        detectedNotes = 0
        resetTake()
        // A rebuilt loop resets the player's sample time and can change the grid
        // step, so any take spanning one would be scored across two grids.
        metronome.onGridChanged = { [weak self] in
            guard let self, self.isListening else { return }
            self.stop()
            // Tempo, time signature, sound and groove all rebuild the loop, and
            // all four are reachable mid-take, so the message names none of them.
            self.failure = "The click changed, so the grid did too and the take stopped. Start the check again."
        }
        observeInterruptions()
        isListening = true
        // Judge the route only once it has settled — engaging the input is itself
        // a route change, and reading it now would judge the route on its way.
        settling = true
        lastAudioAt = Date()
        watchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.warmUpSeconds))
            guard let self, !Task.isCancelled, self.isListening else { return }
            self.settling = false
            if self.speakerTake ? !Self.clickGoesToPhoneSpeaker() : Self.clickGoesToSpeaker() {
                let message = self.speakerTake ? Self.speakerRouteChanged : Self.needsHeadphones
                self.stop()
                self.failure = message
                return
            }
            self.outputLatencyMs = (self.metronome?.outputLatency).map { $0 * 1000 }
            // The route is final now: pick up its calibrated correction. A
            // calibration run measures without one — it is what it measures.
            self.routeKey = Self.currentRoute()?.key
            // Nor does a speaker take: it measures where the tick lands itself
            // (`ClickCanceller.tickOffsetSeconds`), published with the level.
            // Taken from the last publish rather than left at 0 until the next
            // one: a note graded in between would miss the 44 ms on a Mac.
            self.appliedOffsetMs = self.mode == .take
                ? (self.speakerTake
                    ? (self.tickOffsetMs ?? 0)
                    : (self.routeKey.flatMap { Self.storedOffsets()[$0] } ?? 0))
                : 0
            // The symptom, not a guess at its cause. A device joining the route
            // can stop the engine — but so, at times, does engaging the input,
            // and a Bluetooth headset renegotiates on its own schedule, so no
            // notice says for sure that capture died. Audio no longer arriving
            // does: then the button would stay green over nothing.
            while !Task.isCancelled, self.isListening {
                if Date().timeIntervalSince(self.lastAudioAt) > Self.stallSeconds {
                    self.stop()
                    self.failure = "The microphone stopped sending audio — start the check again."
                    return
                }
                try? await Task.sleep(for: .seconds(0.5))
            }
        }
    }

    // MARK: Route

    static let needsHeadphones =
        "Put on headphones. Over this speaker the microphone hears the click itself and can't tell it from your playing."
    static let speakerNeedsClick =
        "Over the speaker the timing check only works with the Click sound. Switch to Click, or put on headphones."
    static let calibrationNeedsHeadphones =
        "Calibration is for headphones — over the phone's speaker there is nothing to calibrate."
    static let speakerRouteChanged =
        "The sound moved away from the phone's speaker — start the check again."
    static let speakerUnavailable =
        "The microphone can't be lined up with the click over the speaker here. Put on headphones."

    /// Whether the click plays from the phone's own speaker and nowhere else —
    /// the one loud route `ClickCanceller` can handle: same clock as the
    /// microphone, and a delay the system reports to within a millisecond.
    /// Not on the Mac, where none of that has been measured — except with the
    /// debug recording switch on, which is how it gets measured.
    private static func clickGoesToPhoneSpeaker() -> Bool {
        #if os(iOS)
        guard !ProcessInfo.processInfo.isMacCatalystApp
                || UserDefaults.standard.bool(forKey: debugRecordingKey) else { return false }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return !outputs.isEmpty && outputs.allSatisfy { $0.portType == .builtInSpeaker }
        #else
        return false
        #endif
    }

    /// A volume step changes the tick the canceller has learned; have it learn
    /// again (the UI goes back to "don't play yet") instead of ending the take.
    private func observeVolume() {
        #if os(iOS)
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isListening, self.speakerTake else { return }
                self.clickLearningProgress = 0
                self.analysisQueue.async { self.canceller?.reset() }
            }
        }
        #endif
    }

    /// Whether the click is playing out loud, where the microphone hears it.
    /// Any other output — wired, Bluetooth, USB — counts as headphones; a
    /// Bluetooth speaker cannot be told from a Bluetooth headset by port type,
    /// and USB is as often a USB-C headphone adapter as a speaker. Those
    /// speakers are caught once notes arrive, by `hearsClick`.
    private static func clickGoesToSpeaker() -> Bool {
        #if os(iOS)
        let speakers: Set<AVAudioSession.Port> = [.builtInSpeaker, .builtInReceiver, .airPlay,
                                                   .HDMI, .carAudio, .lineOut]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { speakers.contains($0.portType) }
        #else
        // Unreachable in practice: the Mac app is Catalyst, where `os(iOS)` holds
        // and the session reports the Mac's own speakers as `.builtInSpeaker`.
        return false
        #endif
    }

    /// Headphones pulled mid-take, or the sound moved to a speaker (AirPlay,
    /// Control Center): either way the microphone would start hearing the click.
    private func observeRouteChanges() {
        #if os(iOS)
        stopObservingRouteChanges()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.refreshCalibration()
            // Changes while settling are the input being engaged; `watchTask`
            // task judges the route that results.
            guard let self, self.isListening, !self.settling else { return }
            if self.speakerTake {
                // Headphones plugged in mid-take: the tick would go on being
                // subtracted from a microphone that no longer hears it.
                guard !Self.clickGoesToPhoneSpeaker() else { return }
                self.stop()
                self.failure = Self.speakerRouteChanged
                return
            }
            // Only where the sound *went* matters. A device dropping out is not
            // enough on its own: a Bluetooth headset renegotiating reports that
            // too, while still on the player's head. Pulled headphones send the
            // click to the speaker, so they are caught here all the same.
            guard Self.clickGoesToSpeaker() else { return }
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let deviceGone = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable
            self.stop()
            self.failure = deviceGone
                ? "The headphones were disconnected — put them back on and start the check again."
                : "The sound moved to a speaker — switch back to headphones and start the check again."
        }
        #endif
    }

    private func stopObservingRouteChanges() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
    }

    /// A phone call or Siri taking the audio ends the take.
    private func observeInterruptions() {
        #if os(iOS)
        stopObservingInterruptions()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.isListening,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self.stop(afterInterruption: true)
            self.failure = "The audio was interrupted — start the check again."
        }
        #endif
    }

    private func stopObservingInterruptions() {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
    }

    // MARK: Grading

    /// Peak level with a slow fall, so the meter doesn't flicker between buffers.
    private func updateLevel(_ peak: Float) {
        inputLevel = peak > inputLevel ? peak : inputLevel * 0.8 + peak * 0.2
    }

    /// An onset on its way from the analysis queue to grading.
    private struct NoteOnset {
        let hostTime: UInt64
        /// Microphone sample it was found at — the debug WAV's own sample index.
        let fileSample: Int64
        /// Taken from the level left under the tick (`ClickCanceller.isUndetected`),
        /// not from the detector: placed at a fixed offset, not measured.
        let underTick: Bool
    }

    /// Grade one detected note against the metronome grid.
    private func register(_ note: NoteOnset) {
        let hostTime = note.hostTime
        // Onsets reach this hop by hop (analysis queue → main actor), so a note
        // detected just before the stop arrives after it. Grading it would leave
        // the take one or two notes past the summary the user is already reading.
        guard isListening, !settling, clickLearningProgress == nil else { return }
        detectedNotes += 1
        // Calibration is played on the click and measures one offset, which can
        // be large (Bluetooth): a grid of whole beats lets it reach ±half a beat.
        // On a finer grid an offset past half a step would snap every note to
        // the neighbouring step and calibration would never collect a note.
        let stepsPerBeat = mode == .calibration ? 1 : subdivision.rawValue
        guard let grid = metronome?.gridPosition(atHostTime: hostTime,
                                                 stepsPerBeat: stepsPerBeat) else { return }
        let deviation = grid.deviation
        if debugWavURL != nil {
            debugDeviations.append(String(format: "%lld,%.2f,%@,%@", note.fileSample, deviation * 1000,
                                          grid.isOnBeat ? "on" : "off", note.underTick ? "tick" : "det"))
        }
        // Not on a speaker take. There the tick is blanked rather than guessed
        // at, and a note that began under it is placed at one fixed offset — a
        // good player would look exactly like the echo this guard hunts for.
        if !speakerTake, hearsClick(deviation * 1000) {
            stop()
            failure = Self.hearsClickMessage
            return
        }
        // Notes between the clicks are left out when only the clicks are graded.
        if !grid.isOnBeat, gradesBeatsOnly { return }
        if mode == .calibration {
            calibrationSamples.append(deviation * 1000)
            calibrationCount = calibrationSamples.count
            if calibrationSamples.count >= Self.calibrationLeadIn + Self.calibrationNotes {
                finishCalibration()
            }
            return
        }
        // Take off the latency the system doesn't report (calibrated per route).
        let hit = Hit(index: gradedNotes, deviationMs: deviation * 1000 - appliedOffsetMs)
        hits.append(hit)
        if hits.count > Self.historyLimit { hits.removeFirst(hits.count - Self.historyLimit) }

        let ms = hit.deviationMs
        takeMin = gradedNotes == 0 ? ms : min(takeMin, ms)
        takeMax = gradedNotes == 0 ? ms : max(takeMax, ms)
        gradedNotes += 1
        if hit.isOnTime { takeOnTime += 1 }
        takeSum += ms
        takeSumOfSquares += ms * ms
    }

    /// Freeze the take into a summary, or nil if too few notes were measured.
    private func makeSummary() -> Summary? {
        guard gradedNotes >= Self.minimumNotesForSummary else { return nil }
        let mean = takeSum / Double(gradedNotes)
        // Variance from the running sums; clamped because floating-point error
        // can push a near-zero variance slightly negative.
        let variance = max(0, takeSumOfSquares / Double(gradedNotes) - mean * mean)
        return Summary(notes: gradedNotes, onTime: takeOnTime, averageMs: mean,
                       spreadMs: variance.squareRoot(), earliestMs: takeMin,
                       latestMs: takeMax, tape: hits)
    }

    static let hearsClickMessage =
        "The microphone is hearing the click itself (a speaker?). Use headphones and start again."

    /// The port type can't tell a Bluetooth or USB speaker from headphones, so
    /// the click reaching the microphone is caught by what it does instead:
    /// it lands at one fixed delay on every beat. A player spreads by 10 ms or
    /// more; the echo, by about a millisecond.
    private func hearsClick(_ rawMs: Double) -> Bool {
        recentRaw.append(rawMs)
        if recentRaw.count > Self.echoWindow { recentRaw.removeFirst(recentRaw.count - Self.echoWindow) }
        guard recentRaw.count >= Self.echoHits else { return false }
        let sorted = recentRaw.sorted()
        var lo = 0
        for hi in sorted.indices {
            while sorted[hi] - sorted[lo] > Self.echoSpreadMs { lo += 1 }
            if hi - lo + 1 >= Self.echoHits { return true }
        }
        return false
    }

    // MARK: Debug recording

    /// A fresh file for the next take, keeping only the last few takes' files.
    private static func newRecordingURL(speaker: Bool) -> URL {
        let folder = FileManager.default.temporaryDirectory
        let kept = 10
        if let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey]) {
            let takes = files.filter { $0.lastPathComponent.hasPrefix("timing-") }
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    return da > db
                }
            // A take is a WAV and its notes.
            for old in takes.dropFirst(2 * (kept - 1)) { try? FileManager.default.removeItem(at: old) }
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "HHmmss-SSS"   // two takes in one second must not share a file
        return folder.appendingPathComponent(
            "timing-\(speaker ? "speaker" : "headphones")-\(stamp.string(from: Date())).wav")
    }

    /// Append one tap buffer to the take's WAV. Analysis queue only.
    nonisolated private func record(_ samples: [Float], sampleRate: Double, to url: URL) {
        guard debugRecording,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        if debugFile == nil {
            debugFile = try? AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        guard let file = debugFile, (try? file.write(from: buffer)) != nil else { return }
        debugSamplesWritten += Int64(samples.count)
    }

    /// Place one tap buffer on the click track: where the loop stood when
    /// microphone sample `sample` was heard. That is what ties the microphone's
    /// sample count to the click — for the canceller, which counts samples from
    /// the first buffer placed, and for a recording's notes.
    private func placeBuffer(sample: Int64, hostTime: UInt64) {
        guard isListening, speakerTake || debugWavURL != nil,
              let position = metronome?.playbackPosition(
                atHostTime: Self.hostTime(hostTime, plus: -Self.inputLatency)) else { return }
        if debugWavURL != nil { debugAnchors.append("\(sample),\(String(format: "%.6f", position))") }
        guard speakerTake else { return }
        if clickMasking {
            analysisQueue.async { self.canceller?.realign(sample: sample, position: position) }
            return
        }
        guard let layout = metronome?.tickLayout, layout.sampleRate == inputSampleRate,
              let canceller = ClickCanceller(layout: layout, sample: sample, position: position) else {
            // Without the canceller a speaker take would grade the click.
            stop()
            failure = Self.speakerUnavailable
            return
        }
        clickMasking = true
        analysisQueue.async { self.canceller = canceller }
    }

    /// Close the WAV and write the notes that make it readable offline.
    /// A take that failed before it began: stop writing, close the file and
    /// throw it away — it has no notes and nothing in it worth sharing.
    private func abandonRecording() {
        guard let wav = debugWavURL else { return }
        debugWavURL = nil
        debugAnchors = []
        debugDeviations = []
        analysisQueue.sync {
            self.debugRecording = false
            self.debugFile = nil
        }
        try? FileManager.default.removeItem(at: wav)
    }

    private func finishRecording() {
        guard let wav = debugWavURL else { return }
        debugWavURL = nil
        // Buffers still in flight must not reopen (and truncate) the file.
        analysisQueue.sync {
            self.debugRecording = false
            self.debugFile = nil
        }
        var lines = [
            "speakerTake=\(speakerTake)",
            "inputSampleRate=\(inputSampleRate)",
            "bpm=\(metronome?.bpm ?? 0)",
            "beatsPerMeasure=\(metronome?.activeBeatsPerMeasure ?? 0)",
            "stepsPerBeat=\(subdivision.rawValue) beatsOnly=\(gradesBeatsOnly)",
            "measureSeconds=\(metronome?.measureSeconds ?? 0)",
            "sound=\(metronome?.sound.rawValue ?? "?") groove=\(metronome?.groove.rawValue ?? "?")",
            "shortClick=\(metronome?.shortClick ?? false)",
            "clickMasking=\(clickMasking)",
            "appliedOffsetMs=\(appliedOffsetMs)",
            "outputLatency=\(metronome?.outputLatency ?? 0)",
            "inputLatency=\(Self.inputLatency)",
            "detectedNotes=\(detectedNotes)",
            "gradedNotes=\(gradedNotes)",
        ]
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        lines.append("outputVolume=\(session.outputVolume)")
        lines.append("mode=\(session.mode.rawValue)")
        lines.append("outputs=" + session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ";"))
        lines.append("inputs=" + session.currentRoute.inputs
            .map { "\($0.portType.rawValue):\($0.portName):\($0.selectedDataSource?.dataSourceName ?? "-")" }
            .joined(separator: ";"))
        #endif
        lines.append("[notes: fileSample,rawDeviationMs,on|off beat,det|tick (detector or placed under the tick)]")
        lines.append(contentsOf: debugDeviations)
        lines.append("[anchors: fileSample,loopPositionSeconds]")
        lines.append(contentsOf: debugAnchors)
        let notes = wav.deletingPathExtension().appendingPathExtension("txt")
        try? lines.joined(separator: "\n").write(to: notes, atomically: true, encoding: .utf8)
        // No buffer ever reached the file (the take ended before audio came):
        // offering it would share a WAV that doesn't exist.
        lastRecording = FileManager.default.fileExists(atPath: wav.path) ? [wav, notes] : [notes]
        debugAnchors = []
        debugDeviations = []
    }

    // MARK: Calibration

    /// Median of the collected notes = the route's hidden latency (plus the
    /// player's own habit, which is why they are asked to play dead on the click).
    private func finishCalibration() {
        let samples = Array(calibrationSamples.dropFirst(Self.calibrationLeadIn))
        let key = routeKey
        let name = Self.currentRoute()?.name ?? "these headphones"
        stop()
        guard let key, samples.count >= Self.calibrationNotes else {
            failure = "Couldn't identify the headphones — try the calibration again."
            return
        }
        let offset = Self.median(samples)
        let scatter = Self.median(samples.map { abs($0 - offset) })
        guard scatter <= Self.calibrationMaxScatterMs else {
            failure = "The notes were too uneven to measure the delay. Try again, playing short, sharp notes exactly on the click."
            return
        }
        guard abs(offset) <= Self.calibrationMaxOffsetMs else {
            failure = "The delay came out implausibly large. Try again at a slower tempo."
            return
        }
        var offsets = Self.storedOffsets()
        offsets[key] = offset
        UserDefaults.standard.set(offsets, forKey: Self.calibrationStoreKey)
        refreshCalibration()
        let value = Int(offset.rounded())
        calibrationMessage = "Calibrated \(name): \(value > 0 ? "+" : "")\(value) ms will be taken off every note."
    }

    /// Forget the correction for the headphones currently connected.
    func resetCalibration() {
        guard let key = Self.currentRoute()?.key else { return }
        var offsets = Self.storedOffsets()
        offsets[key] = nil
        UserDefaults.standard.set(offsets, forKey: Self.calibrationStoreKey)
        calibrationMessage = nil
        refreshCalibration()
    }

    private func refreshCalibration() {
        let route = Self.currentRoute()
        let offset = route.flatMap { Self.storedOffsets()[$0.key] }
        let updated = route.flatMap { r in offset.map { Calibration(routeName: r.name, offsetMs: $0) } }
        if updated != currentCalibration { currentCalibration = updated }
    }

    private static func storedOffsets() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: calibrationStoreKey) as? [String: Double] ?? [:]
    }

    /// The output the click goes to, identified per device (a Bluetooth
    /// headset's UID is its own), so each pair of headphones keeps its offset.
    private static func currentRoute() -> (key: String, name: String)? {
        #if os(iOS)
        guard let out = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return nil }
        return ("\(out.portType.rawValue)|\(out.uid)", out.portName)
        #else
        return nil
        #endif
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private func resetTake() {
        gradedNotes = 0
        takeOnTime = 0
        takeSum = 0
        takeSumOfSquares = 0
        takeMin = 0
        takeMax = 0
    }

    // MARK: Session + clock

    private func configureSession() {
        metronome?.sessionOwnedExternally = true
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Mode is `.default`, not `.measurement`: measurement mode gives the
        // cleanest transients for detection but drops output level so far that
        // the click all but disappears — and a metronome you can't hear is not a
        // metronome. `.defaultToSpeaker` keeps playback off the earpiece when no
        // headphones are in, so the refusal is about the speaker, not silence.
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setActive(true)
        #endif
    }

    private func restoreSession(afterInterruption: Bool = false) {
        let sounding = (metronome?.isRunning ?? false) || StemMixerEngine.shared.isPlaying
        AudioSessionHandoff.restorePlayback(keepActive: sounding, afterInterruption: afterInterruption)
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

/// Onset detector: short-window energy against a longer one.
///
/// A note attack is a burst of energy well above what was sounding a moment
/// before, so the pre-emphasised magnitude is smoothed twice — over about a
/// millisecond for "now", over about 20 ms for "just before" — and an onset is
/// "now" rising past three times "just before", above the room, outside an
/// 80 ms refractory window.
///
/// It used to compare single *samples* against a 60 ms average, and that is what
/// made it double-trigger: a ringing string, pre-emphasised, is a train of sharp
/// pitch-period peaks, each easily three times its own average, so a held note
/// fired again every refractory period. Measured on synthetic playing — held
/// notes, soft after loud, 8/s tremolo, strummed chords — the sample version
/// found 75 of 98 notes and fired 112 times on nothing; this one finds 98 of 98
/// with no false fires, every onset within 0.6 ms of the attack.
///
/// The room floor is the other half. It follows the signal *down* in 50 ms and
/// up only over seconds, so it settles on the quiet between notes rather than
/// on the notes; a floor that tracked the playing itself was what used to bury
/// soft notes and fast tremolo under the level of the music around them.
nonisolated struct OnsetDetector {

    private var sampleRate: Double
    private var shortCoef: Float
    private var longCoef: Float
    private var roomDownCoef: Float
    private var roomUpCoef: Float
    private var refractory: Int

    private var short: Float = 0
    private var long: Float = 0
    private var room: Float = 0.001
    private var previous: Float = 0
    private var sinceOnset = Int.max
    /// The last sample was blanked: `previous` is from before the blank.
    private var afterBlank = false

    /// "Now" must reach this many times "just before".
    private static let riseFactor: Float = 3
    /// …and this many times the room, so the room cannot trigger itself.
    private static let roomFactor: Float = 6
    /// Absolute floor — below this it is silence, whatever the ratios say.
    private static let silenceFloor: Float = 0.004
    /// The smoothing that defines "now".
    private static let shortSeconds = 0.001

    init(sampleRate: Double = 44_100) {
        self.sampleRate = sampleRate
        shortCoef = Self.coefficient(Self.shortSeconds, sampleRate)
        longCoef = Self.coefficient(0.02, sampleRate)
        roomDownCoef = Self.coefficient(0.05, sampleRate)
        roomUpCoef = Self.coefficient(5.0, sampleRate)
        refractory = Int(0.08 * sampleRate)   // 80 ms — no double-triggering on one attack
    }

    private static func coefficient(_ seconds: Double, _ sampleRate: Double) -> Float {
        Float(1 - exp(-1 / (seconds * sampleRate)))
    }

    /// Offsets, in samples from the start of this buffer, of the onsets found.
    /// The hardware rate is only known once buffers start arriving, so the
    /// detector re-tunes itself the first time it sees a different one.
    mutating func process(_ samples: [Float], sampleRate: Double) -> [Int] {
        if sampleRate != self.sampleRate { self = OnsetDetector(sampleRate: sampleRate) }
        var onsets: [Int] = []
        for (i, sample) in samples.enumerated() {
            // NaN marks a stretch `ClickCanceller` blanked out. The detector
            // holds its state across it instead of reading it as silence: a
            // note ringing through a blank would otherwise come back after it
            // as a step from nothing — an attack on every beat nobody played.
            guard !sample.isNaN else {
                if sinceOnset < Int.max { sinceOnset += 1 }
                afterBlank = true
                continue
            }
            // Pre-emphasis across a blank would difference against a sample
            // from 7–20 ms earlier: a ringing note would come back as a jump.
            if afterBlank {
                previous = sample
                afterBlank = false
            }
            // Pre-emphasis: removes rumble/DC and lifts the attack over the body.
            let magnitude = abs(sample - 0.97 * previous)
            previous = sample
            short += (magnitude - short) * shortCoef

            if sinceOnset < Int.max { sinceOnset += 1 }
            let threshold = max(long * Self.riseFactor, room * Self.roomFactor, Self.silenceFloor)
            if short > threshold, sinceOnset > refractory {
                onsets.append(i)
                sinceOnset = 0
            }

            long += (short - long) * longCoef
            room += (short - room) * (short < room ? roomDownCoef : roomUpCoef)
        }
        return onsets
    }
}

// MARK: - Click cancelling (speaker takes)

/// Takes the metronome's tick back out of the microphone signal, so a take can
/// run over the speaker.
///
/// Two facts measured on an iPhone make this workable where filtering and a
/// one-off learned echo were not. The click and the microphone run off one
/// clock, so the tick lands on the same microphone *sample* every beat (the
/// system's latency figures place it to half a millisecond). And a tick 6 ms
/// long is, at the microphone, 40 dB down within 5 ms — far narrower than the
/// timing tolerance.
///
/// So each tick gets a window. Inside it the median of the last few ticks —
/// the tick itself, its reflections, the phone's rattle — is subtracted. The
/// loudest few milliseconds, where the subtraction leaves most, are blanked
/// outright: a note that starts in there is on the beat by any standard, and is
/// reported as such (see `process`).
///
/// The template is learned only from ticks heard in quiet. Learning from every
/// tick was tried and failed on recordings with an amplifier: eight windows of
/// loud playing do not cancel in a median, the template came out as tick plus
/// guitar-level junk, and subtracting it where the player had since gone quiet
/// *added* that junk — notes on beats nobody played. A window counts as quiet
/// when its tail sits well below its own tick, which needs no threshold tuned
/// to the room. Re-learning is continuous, so a volume change costs a few beats
/// instead of the take.
nonisolated struct ClickCanceller {

    /// A note that began inside the blanked stretch, found by its level after
    /// the tick rather than by its attack.
    struct Candidate {
        /// Microphone sample at which the tick was expected.
        let tick: Int64
        /// Where to place the note: the middle of the stretch it must have
        /// started in.
        let sample: Int64
    }

    private static let windowBefore = 0.002
    private static let windowAfter = 0.080
    /// Blanked stretch, relative to where the tick is expected.
    private static let blankBefore = 0.0015
    private static let blankAfter = 0.006
    /// With no template the blank runs this far, past the tick's first echo.
    private static let blankAfterUnlearned = 0.020
    /// The part of the window used to judge it, and to look for a note that
    /// began under the tick: clear of the microphone's recovery from the tick.
    private static let tailFrom = 0.020
    private static let noteUntil = 0.044
    private static let before = 0.030
    private static let historyLimit = 8
    /// Quiet ticks of each kind needed before it can be subtracted: plain,
    /// accent. The accent comes once a bar, so it settles for fewer — two
    /// ticks heard in quiet already agree to well below the detector's floor.
    private static let historyMinimum = [4, 2]

    /// How many clicks a take has to listen to before it can grade, for the
    /// "don't play yet" count: enough bars to hear both kinds often enough.
    static func clicksToLearn(_ layout: Metronome.TickLayout) -> Int {
        let beats = max(1, layout.ticks.count)
        let plainPerBar = beats - (layout.accentFirst ? 1 : 0)
        guard plainPerBar > 0 else { return historyMinimum[1] * beats }
        let bars = (historyMinimum[0] + plainPerBar - 1) / plainPerBar
        return max(bars, layout.accentFirst ? historyMinimum[1] : 0) * beats
    }

    /// How far learning has got, 0…1.
    var learningProgress: Double {
        guard shift != nil else { return 0 }
        let used = Set(kinds)
        var done = 0, needed = 0
        for kind in used {
            needed += Self.historyMinimum[kind]
            done += templates[kind] != nil || gaveUp[kind]
                ? Self.historyMinimum[kind] : min(history[kind].count, Self.historyMinimum[kind])
        }
        return needed > 0 ? Double(done) / Double(needed) : 1
    }
    /// Whether notes can be measured around every tick: the tick has been
    /// found, and each kind learned — or the room is too loud to learn it and
    /// the short blank is used. Until then a window is blanked whole, so the
    /// take must not grade: a note on the beat would vanish without a trace.
    var isReady: Bool {
        shift != nil && Set(kinds).allSatisfy { templates[$0] != nil || gaveUp[$0] }
    }
    /// How much later the tick arrives than the system's latency figures say,
    /// in seconds; nil until found. The player hears the tick, not the click
    /// track, so this comes off every note. Half a millisecond on an iPhone,
    /// 44 ms on a MacBook.
    var tickOffsetSeconds: Double? { shift.map { Double($0) / sampleRate } }
    /// Whether the tick is driving the microphone into clipping. A clipped tick
    /// is not the same twice, so less of it subtracts away — on a MacBook at
    /// full volume the accent leaked through as a note for exactly this reason.
    var isOverloaded: Bool { overloads >= 2 }
    private var overloads = 0
    private static let fullScale: Float = 0.98
    /// Consecutive beats that must put the tick in the same place.
    private static let beatsToLocate = 3
    /// …to within this.
    private static let locateTolerance = 0.001
    /// The tick's peak sits this long after its start (measured: 1.9 ms).
    private static let peakLag = 0.002
    /// Below this a beat's loudest sample is not a tick at all.
    private static let locateFloor: Float = 0.02
    /// A window is quiet when its tail is this far below its tick's peak
    /// (−36 dB). Measured: −50 dB in silence, −10…−30 dB under an amplifier.
    private static let quietRatio: Float = 0.0158
    /// After this many loud windows in a row with nothing learned, stop
    /// blanking the whole window: the room is loud and the tick's tail is
    /// buried anyway. For good — one quiet window later must not take a take
    /// that is being graded back to "don't play yet" (the template, once two
    /// or four quiet ticks do come, takes over again). Per kind: the accent
    /// comes once a bar, and a player who starts early should not wait eight
    /// bars for it.
    private static let loudWindowsBeforeGivingUp = [8, 3]
    /// A note that began under the tick must leave this much behind it…
    private static let noteFloor: Float = 0.004
    /// …and this many times what was sounding before the tick.
    private static let noteRise: Float = 4
    /// Where such a note is placed, relative to the tick.
    private static let notePlacement = 0.006

    private let sampleRate: Double
    private let period: Int
    /// Frames between two ticks, and where the click track puts each of them.
    private let perBeat: Int
    private let ticks: [Int]
    private let leadIn: Int
    /// Loop sample at which each tick's window opens — empty until the tick has
    /// been found (`shift`) — and which template it uses (0 = plain, 1 = accent).
    private var starts: [Int] = []
    private let kinds: [Int]
    private let windowLength: Int
    private let blank: Range<Int>
    private let blankUnlearnedEnd: Int
    private let tailStart: Int
    private let noteEnd: Int

    /// Microphone sample that sits at loop position 0. Checked against the
    /// click track by `realign`.
    private var origin: Int64

    /// How far behind the click track the tick really arrives, in samples; nil
    /// until found. See `locate`.
    private var shift: Int?
    /// Finding it: the loudest sample of each beat so far, the last few beats'
    /// answers, and the audio they came from (to learn from once it is found).
    private var beatPeak: Float = 0
    private var beatPeakAt = 0
    private var beatStarted = false
    private var peaks: [Int] = []
    private var ring: [Float]
    private var ringCount = 0

    private var history: [[(window: [Float], tail: Float)]] = [[], []]
    private var templates: [[Float]?] = [nil, nil]
    private var loudWindows = [0, 0]
    private var gaveUp = [false, false]
    private var current: [Float]
    private var active: Int?
    private var index = 0

    /// Cleaned signal of the last `before` seconds, squared, as a ring.
    private var recent: [Float]
    private var recentAt = 0
    private var recentSum: Float = 0
    /// Mean square before the open window, and the sum inside it so far.
    private var levelBefore: Float = 0
    private var levelAfter: Float = 0

    init?(layout: Metronome.TickLayout, sample: Int64, position: Double) {
        guard layout.period > 0, let first = layout.ticks.first else { return nil }
        let rate = layout.sampleRate
        let spacing = layout.ticks.count > 1 ? layout.ticks[1] - first : layout.period
        let before = Int(Self.windowBefore * rate)
        // Windows must not run into each other at fast tempos.
        let length = min(Int((Self.windowBefore + Self.windowAfter) * rate), spacing - 1)
        guard length > Int((Self.windowBefore + Self.noteUntil) * rate) + 1 else { return nil }
        sampleRate = rate
        period = layout.period
        perBeat = spacing
        ticks = layout.ticks
        leadIn = before
        ring = [Float](repeating: 0, count: Self.beatsToLocate * spacing + length + before)
        kinds = layout.ticks.indices.map { layout.accentFirst && $0 == 0 ? 1 : 0 }
        windowLength = length
        blank = Int((Self.windowBefore - Self.blankBefore) * rate)..<Int((Self.windowBefore + Self.blankAfter) * rate)
        blankUnlearnedEnd = Int((Self.windowBefore + Self.blankAfterUnlearned) * rate)
        tailStart = Int((Self.windowBefore + Self.tailFrom) * rate)
        noteEnd = Int((Self.windowBefore + Self.noteUntil) * rate)
        origin = sample - Int64((position * rate).rounded())
        current = [Float](repeating: 0, count: length)
        recent = [Float](repeating: 0, count: max(1, Int(Self.before * rate)))
    }

    /// Clean one tap buffer in place. `firstSample` is its position in the
    /// microphone's running sample count. Blanked samples come back as NaN,
    /// which `OnsetDetector` steps over (see there).
    ///
    /// Returns the ticks under which a note seems to have begun. The caller
    /// keeps one only if the onset detector found nothing around that tick.
    mutating func process(_ samples: inout [Float], firstSample: Int64) -> [Candidate] {
        var candidates: [Candidate] = []
        let wide = Int64(period)
        var loop = Int(((firstSample - origin) % wide + wide) % wide)
        for i in samples.indices {
            if shift == nil {
                // Nothing can be told apart from the tick before it is found.
                locate(samples[i], loop: loop)
                samples[i] = .nan
                loop += 1
                if loop == period { loop = 0 }
                continue
            }
            if active == nil, let tick = starts.firstIndex(of: loop) {
                active = tick
                index = 0
                levelBefore = recentSum / Float(recent.count)
                levelAfter = 0
            }
            if let tick = active {
                let kind = kinds[tick]
                let sample = samples[i]
                current[index] = sample
                var cleaned: Float?
                if let template = templates[kind] {
                    if !blank.contains(index) { cleaned = sample - template[index] }
                } else if gaveUp[kind] {
                    if index < blank.lowerBound || index >= blankUnlearnedEnd { cleaned = sample }
                }
                samples[i] = cleaned ?? .nan
                if index >= tailStart, index < noteEnd, let cleaned { levelAfter += cleaned * cleaned }
                index += 1
                if index == noteEnd {
                    let after = (levelAfter / Float(noteEnd - tailStart)).squareRoot()
                    if after > Self.noteFloor, after > Self.noteRise * levelBefore.squareRoot() {
                        let tickSample = firstSample + Int64(i + 1 - noteEnd) + Int64(Self.windowBefore * sampleRate)
                        candidates.append(Candidate(tick: tickSample,
                                                    sample: tickSample + Int64(Self.notePlacement * sampleRate)))
                    }
                }
                if index == windowLength {
                    learn(kind: kind)
                    active = nil
                }
            }
            let squared = samples[i].isNaN ? 0 : samples[i] * samples[i]
            recentSum += squared - recent[recentAt]
            recent[recentAt] = squared
            recentAt += 1
            if recentAt == recent.count {
                recentAt = 0
                // Re-sum once a lap, so rounding cannot accumulate.
                recentSum = recent.reduce(0, +)
            }
            loop += 1
            if loop == period { loop = 0 }
        }
        return candidates
    }

    /// Find where the tick really lands.
    ///
    /// The system's latency figures say when the click should reach the
    /// microphone, and on an iPhone they are right to half a millisecond. On a
    /// MacBook they were 44 ms short — the blank sat on silence and every tick
    /// was graded as a note. So the tick is looked for instead of assumed: it is
    /// by far the loudest thing in each beat, and it is found once the loudest
    /// sample of three beats in a row sits at the same place. Playing is never
    /// that regular.
    private mutating func locate(_ sample: Float, loop: Int) {
        let inBeat = loop % perBeat
        if inBeat == 0 {
            beatStarted = true
            beatPeak = 0
        }
        ring[ringCount % ring.count] = sample
        ringCount += 1
        guard beatStarted else { return }
        if abs(sample) > beatPeak {
            beatPeak = abs(sample)
            beatPeakAt = inBeat
        }
        guard inBeat == perBeat - 1 else { return }
        guard beatPeak > Self.locateFloor else {
            peaks.removeAll()
            return
        }
        peaks.append(beatPeakAt)
        if peaks.count > Self.beatsToLocate { peaks.removeFirst() }
        guard peaks.count == Self.beatsToLocate else { return }
        // Distances around the beat, so a tick straddling its boundary agrees
        // with itself.
        let half = perBeat / 2
        let offsets = peaks.map { (($0 - peaks[0] + half) % perBeat + perBeat) % perBeat - half }
        guard let low = offsets.min(), let high = offsets.max(),
              Double(high - low) <= Self.locateTolerance * sampleRate else { return }
        let peak = peaks[0] + offsets.sorted()[offsets.count / 2]
        var found = ((peak - Int(Self.peakLag * sampleRate)) % perBeat + perBeat) % perBeat
        if found > half { found -= perBeat }
        shift = found
        starts = ticks.map { (($0 + found - leadIn) % period + period) % period }

        // Learn from the beats just heard instead of making the player wait
        // for as many again. `end` is one past the sample just filed.
        let end = ringCount
        let loopAtEnd = (loop + 1) % period
        for back in stride(from: Self.beatsToLocate, through: 1, by: -1) {
            let beatLoop = ((loopAtEnd - back * perBeat) % period + period) % period
            let tick = beatLoop / perBeat
            let start = end - back * perBeat + found - leadIn
            guard tick < kinds.count, start >= 0, start >= end - ring.count,
                  start + windowLength <= end else { continue }
            for n in 0..<windowLength { current[n] = ring[(start + n) % ring.count] }
            learn(kind: kinds[tick])
        }
        // A window already open at this very sample has to be entered midway,
        // or its tick would go by unblanked.
        for tick in starts.indices {
            let into = ((loopAtEnd - starts[tick]) % period + period) % period
            guard into > 0, into < windowLength, into <= ringCount else { continue }
            for n in 0..<into { current[n] = ring[(end - into + n) % ring.count] }
            active = tick
            index = into
            levelBefore = 0
            levelAfter = 0
        }
    }

    /// Forget what the tick sounds like and learn it again (the volume moved).
    /// Where it lands stays: that is the route's delay, not the volume.
    mutating func reset() {
        history = [[], []]
        templates = [nil, nil]
        loudWindows = [0, 0]
        gaveUp = [false, false]
        // Clipping was judged at the old volume; the warning must not outlast
        // the very change it asked for.
        overloads = 0
    }

    /// Check the sample count against the click track: `sample` was heard at
    /// loop `position` (seconds). They drift apart only when buffers went
    /// missing; then line up again. The tick sounds the same as before, so what
    /// was learned stays — forgetting it would take a take that is being graded
    /// back to "don't play yet" (see `loudWindowsBeforeGivingUp`). Comparing
    /// against the click track rather than the host clock is what keeps a
    /// microphone crystal a few ppm off from tripping this mid-take.
    mutating func realign(sample: Int64, position: Double) {
        let expected = sample - Int64((position * sampleRate).rounded())
        guard abs(Double(expected - origin)) > sampleRate * 0.001 else { return }
        origin = expected
        active = nil
    }

    /// File the tick just heard — if it was heard in quiet — and rebuild that
    /// kind's template.
    private mutating func learn(kind: Int) {
        var peak: Float = 0
        for n in blank { peak = max(peak, abs(current[n])) }
        overloads = min(4, max(0, overloads + (peak >= Self.fullScale ? 1 : -1)))
        var sum: Float = 0
        for n in tailStart..<windowLength { sum += current[n] * current[n] }
        let tail = (sum / Float(windowLength - tailStart)).squareRoot()
        guard tail < peak * Self.quietRatio else {
            loudWindows[kind] += 1
            if loudWindows[kind] >= Self.loudWindowsBeforeGivingUp[kind] { gaveUp[kind] = true }
            return
        }
        loudWindows[kind] = 0
        history[kind].append((current, tail))
        if history[kind].count > Self.historyLimit { history[kind].removeFirst() }
        // Keep only the quietest of them: one window with a note ringing
        // through it is enough to leave its mark on a median of eight.
        //
        // Entries are deliberately never aged out. Expiring them was tried so
        // the template could follow a changing room, and it cost the reference
        // that makes this rule work: once the ticks heard in true silence were
        // gone, windows with an unamplified guitar ringing at −45 dB became the
        // quietest on record, were learned, and the template started adding
        // notes on beats nobody played. A volume change, the one thing known to
        // change the tick, is handled by `reset()` instead.
        let quietest = history[kind].map(\.tail).min() ?? tail
        history[kind].removeAll { $0.tail > 2 * quietest }
        let ticks = history[kind]
        guard ticks.count >= Self.historyMinimum[kind] else { return }
        var template = [Float](repeating: 0, count: windowLength)
        var column = [Float](repeating: 0, count: ticks.count)
        let middle = ticks.count / 2
        for n in 0..<windowLength {
            for t in ticks.indices { column[t] = ticks[t].window[n] }
            column.sort()
            template[n] = ticks.count.isMultiple(of: 2) ? (column[middle - 1] + column[middle]) / 2 : column[middle]
        }
        templates[kind] = template
    }

    /// Whether `candidate` is a note the detector missed: nothing detected from
    /// shortly before its tick to the end of the stretch that was examined.
    static func isUndetected(_ candidate: Candidate, onsets: [Int64], sampleRate: Double) -> Bool {
        let from = candidate.tick - Int64(0.080 * sampleRate)
        let to = candidate.tick + Int64(noteUntil * sampleRate)
        return !onsets.contains { $0 >= from && $0 < to }
    }
}
