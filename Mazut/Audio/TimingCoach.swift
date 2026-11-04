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
//  Headphones only. Over a speaker the microphone hears the click, and a
//  detector that can hear it reports a flawless performance to someone who
//  played nothing — the click lands on the beat by construction. Two ways of
//  telling it apart from the player were tried and dropped after failing on a
//  real phone: notch filters on the click's tones (the click reaches the
//  microphone through the phone's body as a thump and a rattle, nowhere near the
//  notches), and learning the click's echo during a quiet countdown and
//  subtracting it (too fragile in practice — every volume step, route settle or
//  stray sound in the countdown ended the take). With headphones there is nothing
//  to remove, so the coach refuses to start when the click goes to a speaker.
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
        guard !Self.clickGoesToSpeaker() else {
            failure = Self.needsHeadphones
            return
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
        let summary = reason == .user ? makeSummary() : nil
        isListening = false   // stops grading notes still in flight on the analysis queue
        inputLevel = 0
        inputSampleRate = 0
        outputLatencyMs = nil
        appliedOffsetMs = 0
        routeKey = nil
        calibrationSamples = []
        calibrationCount = 0
        recentRaw = []
        stopObservingInterruptions()
        metronome?.onInputTapLost = nil
        metronome?.onGridChanged = nil
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
        configureSession()

        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.detector = OnsetDetector()
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
                let onsets = self.detector.process(samples, sampleRate: sampleRate)
                self.pendingPeak = samples.reduce(self.pendingPeak) { max($0, abs($1)) }
                let hostTimes = hostTimeValid ? onsets.map { offset -> UInt64 in
                    Self.hostTime(bufferHostTime, plus: Double(offset) / sampleRate - Self.inputLatency)
                } : []
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
                    }
                    for t in hostTimes { self.register(hostTime: t) }
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
            if Self.clickGoesToSpeaker() {
                self.stop()
                self.failure = Self.needsHeadphones
                return
            }
            self.outputLatencyMs = (self.metronome?.outputLatency).map { $0 * 1000 }
            // The route is final now: pick up its calibrated correction. A
            // calibration run measures without one — it is what it measures.
            self.routeKey = Self.currentRoute()?.key
            self.appliedOffsetMs = self.mode == .take
                ? (self.routeKey.flatMap { Self.storedOffsets()[$0] } ?? 0)
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
        "Put on headphones. Over the speaker the microphone hears the click itself and can't tell it from your playing."

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

    /// Grade one detected note against the metronome grid.
    private func register(hostTime: UInt64) {
        // Onsets reach this hop by hop (analysis queue → main actor), so a note
        // detected just before the stop arrives after it. Grading it would leave
        // the take one or two notes past the summary the user is already reading.
        guard isListening, !settling else { return }
        detectedNotes += 1
        guard let deviation = metronome?.deviation(atHostTime: hostTime) else { return }
        if hearsClick(deviation * 1000) {
            stop()
            failure = Self.hearsClickMessage
            return
        }
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
