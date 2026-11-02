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
//  This used to be fought by *filtering*: notches on the click's tones, and a
//  sound check counting onsets to prove the filter held. Both failed on a real
//  phone, and the reasons are worth keeping. The click does not reach the
//  microphone as two tones; it arrives through the body of the phone as a thump,
//  a cabinet ring and a rattle, none of which sit at the notches. And counting
//  onsets cannot measure that leak, because the detector is adaptive: during the
//  check its noise tracker settles on the periodic click and goes partly deaf to
//  it, the count comes out low, the check passes — and the click comes back the
//  moment the player pauses. On a device it showed up as a dead-flat row of
//  "notes" at +49 ms.
//
//  So the leak is now *learned*, not modelled. The click is a loop: every bar is
//  bit-identical, and so is everything the room does to it. While the player
//  stays quiet the coach records two bars and averages them sample by sample in
//  the microphone's own clock, which yields the exact echo — thump, ring, rattle,
//  distortion, drums included. During the take that echo is subtracted before the
//  detector sees anything. See `ClickLearner` and `ClickCanceller`.
//
//  The same recording measures the latency. The echo is a note played perfectly in
//  time by the phone itself, so wherever it lands against the grid is the error of
//  the whole loop — output, air, microphone, buffering — that the system's own
//  latency figures leave out. That was the flat +49 ms, and it biased every note
//  the player played by the same amount. It comes off every measurement. See
//  `measureEcho`.
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
        /// Whether the click's echo was subtracted from the recording — i.e. the
        /// click was reaching the microphone. The sheet says so, since it is the
        /// one thing about how a take was measured that a reader could not see.
        let clickRemoved: Bool

        var accuracy: Double { notes > 0 ? Double(onTime) / Double(notes) : 0 }
    }

    /// Why listening ended. Only a take the user ended themselves earns a
    /// verdict; everything else is an interruption.
    enum StopReason { case user, interrupted }

    /// What the microphone is doing. Every take opens with `soundCheck`, where the
    /// click's echo is recorded and learned and nothing is graded — on every route,
    /// since whether the click reaches the microphone is measured, never guessed
    /// from a port type.
    enum Phase { case idle, soundCheck, grading }

    /// A note inside this window counts as on the beat.
    static let toleranceMs = 25.0
    /// Seconds before recording starts, for the route and the session to settle.
    private static let warmUpSeconds = 1
    /// Where to look for each beat's echo, around the beat. Mostly after it —
    /// that is where the uncompensated latency puts it — and a little before, in
    /// case the system over-reports its latency instead. Not further back than
    /// this: at a fast 16th-note groove the previous step's echo would be in reach.
    private static let echoSearchBefore = 0.02
    private static let echoSearchAfter = 0.15
    /// An echo counts as heard when its peak stands this far above the peak of
    /// the two bars' *difference* in the same window. The difference is the room
    /// noise and nothing else, at the same level as the noise left in the average,
    /// so in silence the ratio sits near 1. Peaks rather than the window's energy:
    /// a 30 ms echo in a 170 ms window is diluted by everything around it, and in
    /// a noisier room an echo plain to see failed an energy test. Measured: no
    /// echo invented in 240 silent recordings across four noise levels.
    private static let echoOverNoise: Float = 2.5
    private static let echoMinimum: Float = 0.002
    /// Beats' echoes must agree on the latency to within this. A real echo is the
    /// same physical path every beat; scatter means there was no echo to measure.
    private static let echoConsistency = 0.003
    /// How long, and how quiet relative to the echo's peak, the moment before an
    /// echo's rise must be. See `measureEcho`.
    private static let echoQuietBefore = 0.003
    private static let echoQuietLevel: Float = 0.15
    /// How far the output volume may move from where the echo was learned before
    /// the take is stopped. Either way matters now: the subtracted echo is fixed,
    /// so the room getting louder leaves some of the click behind, and getting
    /// quieter subtracts more than is there — a negative echo of the same shape.
    /// One hardware step is 1/16, so this is a nudge.
    private static let volumeTolerance: Float = 0.05
    /// Below this a take is too short to say anything about.
    private static let minimumNotesForSummary = 4
    /// How many notes the chart keeps.
    static let historyLimit = 32
    /// How many of the most recent notes the score is computed over — shorter
    /// than the chart, so the percentage reacts to what is being played now.
    private static let scoreWindow = 16

    // MARK: Public state (observed by the UI)

    private(set) var phase: Phase = .idle
    /// The microphone is open — in either phase.
    var isListening: Bool { phase != .idle }
    /// Seconds left of the sound check, for the "stay quiet" countdown.
    private(set) var soundCheckSecondsLeft = 0
    /// The round-trip latency measured off the click's echo, in ms, or nil when
    /// no echo reached the microphone (headphones, a very quiet speaker) and there
    /// was nothing to measure it with. Shown, because it is the number that says
    /// whether the readings can be trusted.
    private(set) var measuredLatencyMs: Double?
    /// Whether the click's echo is being subtracted from the microphone.
    private(set) var clickIsCancelled = false
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

    // Running totals for the whole take (`hits` only keeps the last 32).
    @ObservationIgnored private var takeOnTime = 0
    @ObservationIgnored private var takeSum = 0.0
    @ObservationIgnored private var takeSumOfSquares = 0.0
    @ObservationIgnored private var takeMin = 0.0
    @ObservationIgnored private var takeMax = 0.0

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
    /// Set between the button tap and `beginCapture()`; cleared by `stop()` so a
    /// cancel during the permission prompt doesn't start capturing afterwards.
    @ObservationIgnored private var startRequested = false
    /// The output ports the sound check passed for. Notes are graded only while
    /// the route still matches — the check says nothing about any other one.
    @ObservationIgnored private var checkedOutputs: Set<String> = []
    /// Until when a route change counts as the session still settling.
    @ObservationIgnored private var routeSettlesAt = Date.distantPast
    /// Output volume the check was passed at, and the watch that enforces it.
    ///
    /// The route was pinned from the start, but volume is the variable that
    /// actually governs leakage — the refusal message says "turn the volume down"
    /// in as many words. Nothing posts a route change when the volume keys are
    /// pressed, so without this a take that passed quietly could be turned up
    /// afterwards and go straight back to grading the metronome's own click as a
    /// flawless performance.
    @ObservationIgnored private var checkedVolume: Float = 0
    @ObservationIgnored private var volumeObserver: NSKeyValueObservation?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    /// Taken off every deviation; see `measureEcho`.
    @ObservationIgnored private var latencyCorrection: Double = 0
    /// Touched ONLY from `analysisQueue`: the recording in progress, and the
    /// learned echo once there is one.
    @ObservationIgnored nonisolated(unsafe) private var learner: ClickLearner?
    @ObservationIgnored nonisolated(unsafe) private var canceller: ClickCanceller?
    @ObservationIgnored private var soundCheckTask: Task<Void, Never>?
    private weak var metronome: Metronome?

    init() {
        observeRouteChanges()
    }

    deinit {
        stopObservingRouteChanges()
        stopObservingInterruptions()
    }

    // MARK: Control

    func start(metronome: Metronome) {
        guard !isListening else { return }
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
    /// here rather than at the call site: `stop()` runs on four paths (button,
    /// tab change, unplugged headphones, lost tap) and only one of them is a
    /// finished take.
    @discardableResult
    func stop(reason: StopReason = .interrupted) -> Summary? {
        startRequested = false   // cancels a start still waiting on the permission prompt
        soundCheckTask?.cancel()
        soundCheckTask = nil
        soundCheckSecondsLeft = 0
        latencyCorrection = 0
        measuredLatencyMs = nil
        clickIsCancelled = false
        analysisQueue.async { [weak self] in
            self?.learner = nil
            self?.canceller = nil
        }
        guard isListening else { return nil }
        // A take that never got past the sound check has nothing to report.
        let summary = reason == .user && phase == .grading ? makeSummary() : nil
        phase = .idle   // stops grading notes still in flight on the analysis queue
        inputLevel = 0
        inputSampleRate = 0
        stopObservingVolume()
        stopObservingInterruptions()
        metronome?.onRenderDisrupted = nil
        metronome?.onInputTapLost = nil
        metronome?.onGridChanged = nil
        metronome?.detachInputTap()
        // Hand the session back: the metronome sets its own category again.
        metronome?.sessionOwnedExternally = false
        restoreSession()
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
            self.learner = nil
            self.canceller = nil
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
            guard time.isHostTimeValid else { return }
            let bufferHostTime = time.hostTime
            // The input's own sample count, which is what the learned echo is
            // aligned by. Host time is good enough to grade a note, but it jitters
            // by fractions of a sample, and cancelling a 1.5 kHz tone needs better.
            let sampleTime: Int64? = time.isSampleTimeValid ? time.sampleTime : nil
            self.analysisQueue.async {
                self.learn(samples, sampleTime: sampleTime, hostTime: bufferHostTime,
                           sampleRate: sampleRate)
                var input = samples
                var guardLevels: [Float]?
                // Whether this buffer had the echo taken out. The canceller is
                // installed on this queue a moment after the main actor has
                // already switched to grading, so buffers in that gap — the one
                // that completed the recording among them — still carry the
                // click. Tagging each batch lets `register` drop exactly those.
                let cancelled = self.canceller != nil
                if let canceller = self.canceller {
                    // Without a sample position the echo cannot be lined up, and
                    // the raw signal still has the click in it. Skipping the
                    // buffer costs a note at worst; grading it could cost the take.
                    guard let sampleTime else { return }
                    (input, guardLevels) = canceller.cancel(samples, at: sampleTime)
                }
                let onsets = self.detector.process(input, sampleRate: sampleRate,
                                                   guardLevels: guardLevels)
                self.pendingPeak = samples.reduce(self.pendingPeak) { max($0, abs($1)) }
                let hostTimes = onsets.map { offset -> UInt64 in
                    Self.hostTime(bufferHostTime, plus: Double(offset) / sampleRate - Self.inputLatency)
                }
                let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                let peak = self.pendingPeak
                let publishLevel = now - self.lastLevelUpdate > 0.05
                if publishLevel {
                    self.lastLevelUpdate = now
                    self.pendingPeak = 0
                }
                guard !hostTimes.isEmpty || publishLevel else { return }
                Task { @MainActor in
                    if publishLevel { self.updateLevel(peak) }
                    for t in hostTimes { self.register(hostTime: t, cancelled: cancelled) }
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
            // The route-change path says why; this one used to end the take with
            // the readout simply vanishing and no sheet, which reads as a bug.
            // Tempo, time signature, sound and groove all rebuild the loop, and
            // all four are reachable mid-take, so the message names none of them.
            self.failure = "The click changed, so the grid did too and the take stopped. Start the check again."
        }
        // Read the route only now. Engaging the input is itself a route-changing
        // event — an A2DP route has no input side, so iOS renegotiates when the
        // engine touches `inputNode` — and capturing it beforehand would have the
        // observer kill the take the moment the new route settled.
        checkedOutputs = Self.outputPorts()
        observeVolume()
        observeDisruptions(metronome)
        // No separate "route still valid" flag guards `register`: the observer
        // stops the take, `stop()` sets `phase = .idle`, and `register` already
        // returns on that.
        phase = .soundCheck
        startSoundCheck(metronome)
    }

    /// Learn the click's echo while the player stays quiet: a second for the route
    /// to settle, then `ClickLearner.bars` bars recorded. The countdown is only the
    /// instruction; the recording finishes on the audio's clock, in `learn`, and
    /// the verdict is `finishLearning`.
    private func startSoundCheck(_ metronome: Metronome) {
        // One bar in the microphone's samples. Equal to the loop when the two run
        // at one rate — the only case where cancelling is allowed — and otherwise
        // rounded, which is plenty to tell whether there is an echo at all.
        let micRate = inputSampleRate
        let period = Int((Double(metronome.loopFrames) * micRate / metronome.loopSampleRate).rounded())
        guard period > 0, micRate > 0 else {
            stop()
            failure = "Lost track of the click. Start the metronome again."
            return
        }
        let learnSeconds = Int((Double(period * ClickLearner.bars) / micRate).rounded(.up))
        let total = Self.warmUpSeconds + learnSeconds
        // The route may still be settling from activating the session and engaging
        // the input; let it, right up to the moment recording starts.
        routeSettlesAt = Date().addingTimeInterval(Double(Self.warmUpSeconds))
        // Set before the task, or the first rendered frame shows a countdown of 0
        // and then animates upwards under a label saying how long to stay quiet.
        soundCheckSecondsLeft = total
        soundCheckTask = Task { @MainActor [weak self] in
            for remaining in stride(from: total, through: 1, by: -1) {
                guard let self, self.phase == .soundCheck else { return }
                self.soundCheckSecondsLeft = remaining
                if remaining == learnSeconds {
                    self.analysisQueue.async { [weak self] in
                        self?.learner = ClickLearner(period: period)
                    }
                }
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            // A little past the countdown, in case the recording is running a
            // buffer behind. Still learning after that means the audio stopped.
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.phase == .soundCheck else { return }
            self.stop()
            self.failure = "Lost the audio while learning the click. Start the check again."
        }
    }

    /// Feed the recording, on the analysis queue, and hand it over when complete.
    nonisolated private func learn(_ samples: [Float], sampleTime: Int64?, hostTime: UInt64,
                                   sampleRate: Double) {
        guard var recording = learner else { return }
        recording.consume(samples, sampleTime: sampleTime, hostTime: hostTime)
        guard recording.isComplete else {
            learner = recording
            return
        }
        learner = nil
        let learned = recording.finish(sampleRate: sampleRate)
        Task { @MainActor [weak self] in self?.finishLearning(learned) }
    }

    private func finishLearning(_ learned: LearnedClick) {
        guard phase == .soundCheck, let metronome else { return }
        soundCheckTask?.cancel()
        soundCheckTask = nil
        soundCheckSecondsLeft = 0
        if let why = verdict(learned, metronome) {
            stop()
            failure = why
            return
        }
        phase = .grading
    }

    /// Why the take cannot start, or nil once it is set up to.
    ///
    /// No leakage threshold anywhere in here, and that is the change. The old
    /// check asked whether the click was quiet enough to ignore; this one does not
    /// need it to be — it subtracts what it heard. What can still stop a take is a
    /// recording that cannot be trusted, or an echo that cannot be lined up.
    private func verdict(_ learned: LearnedClick, _ metronome: Metronome) -> String? {
        guard !learned.broken else {
            return "Lost the audio while learning the click. Start the check again."
        }
        guard learned.sawSignal else {
            return "The microphone isn't picking anything up. Check that nothing is covering it and that no other app is using it."
        }
        guard learned.strayBursts == 0 else {
            return "Heard something besides the click while it was listening. Stay completely still for the countdown, then play."
        }
        let latency = measureEcho(learned, metronome)
        // Subtracting sample by sample needs the loop and the microphone on one
        // clock at one rate. The phone's own speaker and wired headphones share the
        // microphone's; a Bluetooth or AirPlay speaker runs its own and drifts away
        // from it within seconds. This is a different question from "can it leak",
        // which no port type answers.
        if learned.period == metronome.loopFrames, Self.routeSharesOneClock() {
            // Cancelled whenever it *can* be, whether or not an echo was found.
            // Finding the echo is a test with a threshold, and a threshold can
            // miss — a quiet click in a noisy room — while the subtraction does
            // not care: if there is no echo it takes out the averaged room noise
            // and costs a fifth more noise, and if there is one it takes it out.
            // So the one way left for a leak to reach the grader is closed by not
            // asking. The echo test only decides the latency, where an invented
            // echo would do real harm.
            let canceller = ClickCanceller(learned)
            analysisQueue.async { [weak self] in self?.canceller = canceller }
            clickIsCancelled = true
            if let latency {
                latencyCorrection = latency
                measuredLatencyMs = latency * 1000
            }
            return nil
        }
        // Nothing to cancel with, so the take may only start if the click is not
        // reaching the microphone at all — and that is judged over the *whole*
        // bar, not the window around each beat that `measureEcho` searches. A
        // Bluetooth speaker's echo arrives 150-300 ms late, outside that window;
        // asking only there would find nothing and start grading the click.
        guard !Self.echoAnywhere(learned) else {
            #if os(iOS)
            return "The click is coming back from a speaker that can't be kept in step with the microphone. Use the phone's own speaker, or headphones."
            #else
            return "The click is reaching the microphone and can't be removed on this setup. Use headphones."
            #endif
        }
        // No echo anywhere: headphones on their own clock, or a speaker turned well
        // down. Nothing to remove, and readings stay uncorrected.
        return nil
    }

    /// Whether the click reaches the microphone anywhere in the bar, at whatever
    /// delay. The same comparison as the per-beat test — the averaged bars' peak
    /// against their difference's — over the whole loop. Measured: an echo is
    /// found at 49, 180 and 300 ms of delay, faint or loud, and none is invented
    /// in 240 silent recordings across four noise levels.
    private static func echoAnywhere(_ learned: LearnedClick) -> Bool {
        let peak = learned.envelope.max() ?? 0
        let noisePeak = learned.noiseEnvelope.max() ?? 0
        return peak >= max(noisePeak * echoOverNoise, echoMinimum)
    }

    /// Where each beat's echo starts, relative to the beat as heard — the latency
    /// the system's own figures leave out. Nil if there is no echo to measure.
    ///
    /// The recording is indexed by the microphone's sample count, the beats by the
    /// loop's; one buffer's host time ties the two together. That tie jitters by a
    /// fraction of a millisecond, which is fine here — this only has to find where
    /// an echo starts, not cancel it.
    private func measureEcho(_ learned: LearnedClick, _ metronome: Metronome) -> Double? {
        let period = learned.period
        let rate = learned.sampleRate
        let beats = metronome.activeBeatsPerMeasure
        guard beats > 0,
              let anchorFrame = metronome.loopFrame(
                  atHostTime: Self.hostTime(learned.anchorHost, plus: -Self.inputLatency))
        else { return nil }
        let micPerLoopFrame = rate / metronome.loopSampleRate
        let anchorIndex = Self.wrap(Int(learned.anchorSample % Int64(period)), period)

        let before = Int(Self.echoSearchBefore * rate)
        // Bounded by the beat as well as by time: at 1/1 and 240 bpm a bar is
        // 250 ms, and a fixed 170 ms window would reach round the loop into the
        // previous beat's ringing.
        let beatSpacing = Double(metronome.beatFrames) * micPerLoopFrame
        let after = min(Int(Self.echoSearchAfter * rate), Int(0.6 * beatSpacing) - before)
        guard after > 0 else { return nil }
        let window = before + after
        var offsets: [Double] = []
        for beat in 0..<beats {
            let frame = Double(beat * metronome.beatFrames)
            let beatIndex = anchorIndex + Int(((frame - anchorFrame) * micPerLoopFrame).rounded())
            let start = Self.wrap(beatIndex - before, period)
            var peak: Float = 0
            var noisePeak: Float = 0
            for k in 0..<window {
                let p = (start + k) % period
                peak = max(peak, learned.envelope[p])
                noisePeak = max(noisePeak, learned.noiseEnvelope[p])
            }
            // The echo's start is where it first passes 30% of its peak — not where
            // the onset detector would fire on it. Both were tried. The detector
            // fires about half a millisecond later on the click's softer attack
            // than on a plucked string, so measuring the latency with it leaves a
            // −0.6 ms bias on every graded note; the 30% point leaves none.
            guard peak >= max(noisePeak * Self.echoOverNoise, Self.echoMinimum),
                  let rise = (0..<window).first(where: {
                      learned.envelope[(start + $0) % period] > 0.3 * peak
                  })
            else { continue }
            // The rise has to be a rise: quiet for a few milliseconds before it.
            // Otherwise the window opened inside something already ringing —
            // in a fast 16th-note groove, the previous step's echo, which arrives
            // a whole latency after that step and can still be sounding at the
            // window's start. Every beat then "rises" at sample 0, the offsets
            // agree perfectly, and a wrong latency comes off every note. Such a
            // beat is skipped; if too few are left, the latency is not measured
            // at all, which leaves readings uncorrected rather than wrong.
            let quiet = Int(Self.echoQuietBefore * rate)
            guard rise >= quiet,
                  (rise - quiet..<rise).allSatisfy({
                      learned.envelope[(start + $0) % period] < Self.echoQuietLevel * peak
                  })
            else { continue }
            offsets.append(Double(rise - before) / rate)
        }
        // Grooves rest on some beats; the click never does. Half the beats is
        // enough, as long as they agree.
        guard offsets.count >= max(1, (beats + 1) / 2) else { return nil }
        let median = offsets.sorted()[offsets.count / 2]
        guard offsets.allSatisfy({ abs($0 - median) < Self.echoConsistency }) else { return nil }
        return median
    }

    /// Whether the output and the microphone run off the device's own clock.
    private static func routeSharesOneClock() -> Bool {
        #if os(iOS)
        let route = AVAudioSession.sharedInstance().currentRoute
        let ownOutputs: Set<AVAudioSession.Port> = [.builtInSpeaker, .builtInReceiver, .headphones]
        let ownInputs: Set<AVAudioSession.Port> = [.builtInMic, .headsetMic]
        return !route.outputs.isEmpty
            && route.outputs.allSatisfy { ownOutputs.contains($0.portType) }
            && route.inputs.allSatisfy { ownInputs.contains($0.portType) }
        #else
        // No route information to go on. Without it the clocks cannot be vouched
        // for, and a template sliding against a drifting echo adds an inverted
        // click beside the real one — so no cancelling here.
        return false
        #endif
    }

    nonisolated private static func wrap(_ index: Int, _ period: Int) -> Int {
        ((index % period) + period) % period
    }

    /// Tracks the output route: it decides whether measuring is possible at all,
    /// and headphones pulled mid-session take the tap and the click's connections
    /// with them without anything else reporting it.
    ///
    /// Watching the *route* rather than the engine's configuration is deliberate:
    /// engaging the microphone reconfigures the engine ourselves, so an
    /// engine-level observer tears down the setup it has just seen created.
    private func observeRouteChanges() {
        #if os(iOS)
        stopObservingRouteChanges()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.isListening else { return }
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let deviceGone = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable
            // Any change of output port invalidates the take: the sound check
            // was run for the route it started on and says nothing about this one.
            // Compared as a port set: a port type alone cannot tell a Bluetooth
            // headset from a Bluetooth speaker.
            let ports = Self.outputPorts()
            guard deviceGone || ports != self.checkedOutputs else { return }
            // Settling, not a switch. `deviceGone` is deliberately not excluded:
            // the A2DP renegotiation this window exists for drops the old output
            // port, so iOS reports it as exactly that, and excluding it skipped
            // the grace in the one case it was added for. Nothing has been
            // counted yet — the window closes when the tally starts — so re-pinning
            // is sound and the verdict is reached entirely on the settled route.
            if Date() < self.routeSettlesAt {
                self.checkedOutputs = ports
                self.checkedVolume = Self.currentVolume()
                return
            }
            self.stop()
            self.failure = "The audio output changed — start the check again."
        }
        #endif
    }

    /// Watch the output volume for the life of the take — see `volumeTolerance`.
    private func observeVolume() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        checkedVolume = session.outputVolume
        volumeObserver = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let volume = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                // While the echo is being learned, or subtracted, any change spoils
                // it. Otherwise nothing is fixed to the old level, and only turning
                // it *up* matters — that can push a click the microphone could not
                // hear into one it can. Headphones, nudged quieter, keep going.
                let learnedEcho = self.phase == .soundCheck || self.clickIsCancelled
                let change = volume - self.checkedVolume
                if learnedEcho, abs(change) > Self.volumeTolerance {
                    self.stop()
                    self.failure = "The volume changed, so the click has to be learned again. Start the check again."
                } else if !learnedEcho, change > Self.volumeTolerance {
                    self.stop()
                    self.failure = "The volume went up, so the click may reach the microphone now. Start the check again."
                }
            }
        }
        #endif
    }

    private func stopObservingVolume() {
        volumeObserver?.invalidate()
        volumeObserver = nil
    }

    /// Anything that can shift the loop against the microphone's sample clock
    /// ends the take: a phone call or Siri taking the audio, or the engine
    /// reconfiguring itself. The learned echo is lined up by sample count, so
    /// after such a jump it is subtracted in the wrong place — the real click
    /// stays in, and an inverted copy is added beside it.
    ///
    /// The engine's own notice is ignored until the warm-up is over: engaging the
    /// microphone reconfigures it on purpose, and reacting to that is exactly the
    /// self-inflicted teardown this file learned to avoid once already.
    private func observeDisruptions(_ metronome: Metronome) {
        metronome.onRenderDisrupted = { [weak self] in
            guard let self, self.isListening, Date() >= self.routeSettlesAt else { return }
            self.stop()
            self.failure = "The audio was interrupted, so the click has to be learned again. Start the check again."
        }
        #if os(iOS)
        stopObservingInterruptions()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.isListening,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self.stop()
            self.failure = "The audio was interrupted, so the click has to be learned again. Start the check again."
        }
        #endif
    }

    private func stopObservingInterruptions() {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
    }

    private static func currentVolume() -> Float {
        #if os(iOS)
        AVAudioSession.sharedInstance().outputVolume
        #else
        0
        #endif
    }

    /// The current output ports, by type. The sound check is pinned to this set.
    private static func outputPorts() -> Set<String> {
        #if os(iOS)
        Set(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue))
        #else
        []
        #endif
    }

    private func stopObservingRouteChanges() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
    }

    /// Peak level with a slow fall, so the meter doesn't flicker between buffers.
    private func updateLevel(_ peak: Float) {
        inputLevel = peak > inputLevel ? peak : inputLevel * 0.8 + peak * 0.2
    }

    /// Grade one detected note against the metronome grid.
    private func register(hostTime: UInt64, cancelled: Bool) {
        // Onsets reach this hop by hop (analysis queue → main actor), so a note
        // detected just before the stop arrives after it. Grading it would leave
        // the take one or two notes past the summary the user is already reading.
        // Only while grading. Not while the echo is being learned: onsets then are
        // not evidence of anything — the recording speaks for itself, in `verdict`.
        guard phase == .grading else { return }
        // Once the echo is being cancelled, an onset from a buffer that was not is
        // the click itself, landing near 0 ms and scoring as a perfect note.
        guard cancelled || !clickIsCancelled else { return }
        detectedNotes += 1
        guard let deviation = metronome?.deviation(atHostTime: hostTime,
                                                   latency: latencyCorrection) else { return }
        let hit = Hit(index: gradedNotes, deviationMs: deviation * 1000)
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
                       latestMs: takeMax, tape: hits, clickRemoved: clickIsCancelled)
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
        // metronome. `.defaultToSpeaker` keeps playback off the earpiece, which
        // is where plain `.playAndRecord` would put it.
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setActive(true)
        #endif
    }

    private func restoreSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
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
///
/// The metronome is not filtered here — it is subtracted before this sees the
/// signal (`ClickCanceller`). What remains is an optional per-sample floor, the
/// guard against whatever the subtraction leaves behind.
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
    static let silenceFloor: Float = 0.004
    /// The smoothing that defines "now". Shared with `ClickCanceller`, whose guard
    /// has to be on exactly this scale.
    static let shortSeconds = 0.001

    init(sampleRate: Double = 44_100) {
        self.sampleRate = sampleRate
        shortCoef = Self.coefficient(Self.shortSeconds, sampleRate)
        longCoef = Self.coefficient(0.02, sampleRate)
        roomDownCoef = Self.coefficient(0.05, sampleRate)
        roomUpCoef = Self.coefficient(5.0, sampleRate)
        refractory = Int(0.08 * sampleRate)   // 80 ms — no double-triggering on one attack
    }

    static func coefficient(_ seconds: Double, _ sampleRate: Double) -> Float {
        Float(1 - exp(-1 / (seconds * sampleRate)))
    }

    /// Offsets, in samples from the start of this buffer, of the onsets found.
    /// The hardware rate is only known once buffers start arriving, so the
    /// detector re-tunes itself the first time it sees a different one.
    ///
    /// `guardLevels`, when given, is a per-sample floor one-for-one with `samples`,
    /// on the scale of the short-window energy.
    mutating func process(_ samples: [Float], sampleRate: Double,
                          guardLevels: [Float]? = nil) -> [Int] {
        if sampleRate != self.sampleRate { self = OnsetDetector(sampleRate: sampleRate) }
        var onsets: [Int] = []
        for (i, sample) in samples.enumerated() {
            // Pre-emphasis: removes rumble/DC and lifts the attack over the body.
            let magnitude = abs(sample - 0.97 * previous)
            previous = sample
            short += (magnitude - short) * shortCoef

            if sinceOnset < Int.max { sinceOnset += 1 }
            let floor = max(Self.silenceFloor, guardLevels?[i] ?? 0)
            let threshold = max(long * Self.riseFactor, room * Self.roomFactor, floor)
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

// MARK: - Learning the click's echo

/// Records the microphone over two whole bars while the player is quiet.
///
/// Everything rests on one fact: the metronome plays a loop, so every bar is
/// bit-identical, and so is everything the room adds to it. Recorded in the
/// microphone's own sample clock and averaged position by position, the two bars
/// give the exact echo; their difference gives everything that was *not* the loop.
/// Recorded any other way they give mush — hence the strict contiguity check: a
/// dropped buffer shifts every later sample against the loop.
nonisolated struct ClickLearner {
    /// Two is the least that works: their average is the echo, and their
    /// difference is everything that was not the loop, which is how a spoiled
    /// recording is caught instead of being subtracted from every bar of the take.
    /// More bars would average the room down further, at a cost in seconds of
    /// silence the player has to keep.
    static let bars = 2
    let period: Int
    private var raw: [Float]
    private var filled = 0
    private var expectedSample: Int64?
    private var startSample: Int64 = 0
    private var anchor: (host: UInt64, sample: Int64)?
    private var sawSignal = false
    private var broken = false

    var isComplete: Bool { broken || filled == raw.count }

    init(period: Int) {
        self.period = period
        raw = [Float](repeating: 0, count: period * Self.bars)
    }

    mutating func consume(_ samples: [Float], sampleTime: Int64?, hostTime: UInt64) {
        guard !isComplete else { return }
        guard let sampleTime, expectedSample == nil || sampleTime == expectedSample else {
            broken = true
            return
        }
        if expectedSample == nil {
            startSample = sampleTime
            anchor = (hostTime, sampleTime)
        }
        expectedSample = sampleTime + Int64(samples.count)
        let count = min(samples.count, raw.count - filled)
        for i in 0..<count {
            raw[filled + i] = samples[i]
            // Any real microphone has a noise floor; only a dead one is
            // bit-exact silent. Not a loudness test, which would refuse the best
            // setup there is — a working microphone in a quiet room.
            if samples[i] != 0 { sawSignal = true }
        }
        filled += count
    }

    func finish(sampleRate: Double) -> LearnedClick {
        guard !broken, let anchor else {
            return LearnedClick(template: [], envelope: [], noiseEnvelope: [], period: period,
                                sampleRate: sampleRate, anchorHost: 0, anchorSample: 0,
                                strayBursts: 0, sawSignal: sawSignal, broken: true)
        }
        // Average and half-difference of the two bars, indexed by the microphone's
        // sample count modulo the bar — which is how `ClickCanceller` looks it up.
        let base = Int(((startSample % Int64(period)) + Int64(period)) % Int64(period))
        var template = [Float](repeating: 0, count: period)
        var halfDifference = [Float](repeating: 0, count: period)
        for j in 0..<period {
            let p = (base + j) % period
            template[p] = (raw[j] + raw[j + period]) * 0.5
            halfDifference[p] = (raw[j] - raw[j + period]) * 0.5
        }

        // Something that was not the loop — a cough, a creak, a touched string —
        // stands out of the bars' difference as a burst far above its own typical
        // level. Judged against the difference's median, not by the onset detector:
        // that one adapts, and on a cold start it fires on peaks of plain room
        // noise, which in this test meant refusing a silent room.
        var difference = [Float](repeating: 0, count: period)
        for j in 0..<period {
            let d = raw[j] - raw[j + period]
            let previous = j > 0 ? raw[j - 1] - raw[j - 1 + period] : 0
            difference[j] = abs(d - 0.97 * previous)
        }
        let typical = stride(from: 0, to: period, by: 7).map { difference[$0] }.sorted()
        let threshold = max(OnsetDetector.silenceFloor, 10 * typical[typical.count / 2])
        let refractory = Int(0.08 * sampleRate)
        var strayBursts = 0
        var lastBurst = -refractory - 1
        for j in 0..<period where difference[j] > threshold {
            if j - lastBurst > refractory { strayBursts += 1 }
            lastBurst = j
        }

        // Both as the detector would see them: pre-emphasised magnitude, read round
        // the loop so the bar's first sample follows its last.
        func emphasised(_ x: [Float]) -> [Float] {
            (0..<period).map { abs(x[$0] - 0.97 * x[($0 + period - 1) % period]) }
        }
        return LearnedClick(template: template, envelope: emphasised(template),
                            noiseEnvelope: emphasised(halfDifference), period: period,
                            sampleRate: sampleRate, anchorHost: anchor.host,
                            anchorSample: anchor.sample, strayBursts: strayBursts,
                            sawSignal: sawSignal, broken: false)
    }
}

/// What a recording produced. The arrays are indexed by the microphone's sample
/// count modulo `period`.
nonisolated struct LearnedClick {
    let template: [Float]
    /// The echo as the detector sees it.
    let envelope: [Float]
    /// The same for the bars' half-difference: the room noise left in the average.
    let noiseEnvelope: [Float]
    let period: Int
    let sampleRate: Double
    /// One buffer's host time and sample count: the tie between the recording's
    /// clock and the loop's, used to find the beats in it.
    let anchorHost: UInt64
    let anchorSample: Int64
    let strayBursts: Int
    let sawSignal: Bool
    let broken: Bool
}

/// Subtracts the learned echo from the live microphone signal.
nonisolated struct ClickCanceller {
    private let template: [Float]
    private let guardLevels: [Float]
    private let period: Int

    /// What is left after subtracting is the echo's *change* since it was learned
    /// — the volume nudged, the phone shifted on the table. So the detector also
    /// gets a floor of this much of the echo's own energy wherever the echo is.
    /// Measured with the volume 3 dB either way: no leftovers fire, and notes
    /// landing exactly on the click are still found.
    private static let guardFraction: Float = 0.5

    init(_ learned: LearnedClick) {
        template = learned.template
        period = learned.period
        let rate = learned.sampleRate
        // On the detector's own scale: the echo's envelope smoothed exactly as
        // "now" is, twice round the loop so it wraps across the bar line…
        let smoothing = OnsetDetector.coefficient(OnsetDetector.shortSeconds, rate)
        var energy = [Float](repeating: 0, count: period)
        var level: Float = 0
        for pass in 0..<2 {
            for p in 0..<period {
                level += (learned.envelope[p] - level) * smoothing
                if pass == 1 { energy[p] = level }
            }
        }
        // …then held for a millisecond or so each way, so the floor still covers
        // the echo if it is a sample or two off.
        let hold = Float(exp(-1 / (0.001 * rate)))
        var levels = energy
        for forward in [true, false] {
            var held: Float = 0
            for pass in 0..<2 {
                for k in 0..<period {
                    let p = forward ? k : period - 1 - k
                    held = max(energy[p], held * hold)
                    if pass == 1 { levels[p] = max(levels[p], held) }
                }
            }
        }
        guardLevels = levels.map { $0 * Self.guardFraction }
    }

    /// The buffer with the echo taken out, and the floor to go with it.
    func cancel(_ samples: [Float], at sampleTime: Int64) -> ([Float], [Float]) {
        var clean = samples
        var floor = [Float](repeating: 0, count: samples.count)
        var p = Int(((sampleTime % Int64(period)) + Int64(period)) % Int64(period))
        for i in samples.indices {
            clean[i] = samples[i] - template[p]
            floor[i] = guardLevels[p]
            p += 1
            if p == period { p = 0 }
        }
        return (clean, floor)
    }
}
