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
//  There is no echo cancellation. The hazard it would guard against is not noise
//  but flattery: the metronome's click arrives exactly on the beat, so a
//  detector that can hear it reports a flawless performance to someone who
//  played nothing at all. Two things stand in its place.
//
//  *Separation by frequency.* The detector notches out `Metronome.clickTones` —
//  the click's own two frequencies — which leaves it at a twentieth of the
//  detector's threshold. The guitar is untouched: measured across every pitch
//  from the low E to a bend whose fundamental sits inside one of the notches,
//  detection is unchanged and the delay stays under 0.04 ms, because an onset
//  rides on the broadband attack rather than on the fundamental. The click is not
//  altered or substituted while measuring; it only needed its attack ramped, for
//  the reason given in `Metronome.renderClick`. Drums get no such treatment —
//  their voices are filtered noise across the same range as a pick attack, and
//  there is no tone to notch out.
//
//  *Proof, per room.* The filter handles the tone, but a phone speaker also
//  radiates a broadband thump through the body of the device, and whether that
//  clears the threshold depends on the volume, the surface the phone is lying on
//  and how close it is to the guitar — none of which is knowable in advance. So
//  every take opens with a sound check: the click runs with the microphone open
//  while the player stays quiet, and the take begins only if nothing was heard.
//  See `startSoundCheck`.
//
//  The check runs on *every* route, not only the built-in speaker. Route types do
//  not divide into "can leak" and "cannot": `.bluetoothA2DP` and `.airPlay` are a
//  Bluetooth speaker or a HomePod as readily as headphones, and guessing from the
//  port type is exactly the reasoning this feature cannot afford. Measuring costs
//  a few seconds and needs no guess.
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
        /// Measured with the click coming out of the speaker rather than
        /// headphones. It passed a sound check, but it is the weaker of the two
        /// setups and the sheet says so rather than letting the number stand
        /// unqualified.
        let overSpeaker: Bool

        var accuracy: Double { notes > 0 ? Double(onTime) / Double(notes) : 0 }
    }

    /// Why listening ended. Only a take the user ended themselves earns a
    /// verdict; everything else is an interruption.
    enum StopReason { case user, interrupted }

    /// What the microphone is doing. Every take opens with `soundCheck`, where
    /// onsets are counted but nothing is graded — every take, on every route, for
    /// the reason the file header gives: a port type cannot say whether the thing
    /// on the other end is in someone's ears or across the room.
    enum Phase { case idle, soundCheck, grading }

    /// A note inside this window counts as on the beat.
    static let toleranceMs = 25.0
    /// The sound check sorts what it hears by *phase within the beat*, in this
    /// many bins, and asks whether any one bin is busier than scatter explains.
    ///
    /// Phase, rather than a window around the grid, because a window assumes the
    /// latency compensation is exact. Over a speaker it is not — the sound still
    /// has to cross the room, and the tap's own buffer is 21 ms at 48 kHz — so
    /// every leaked click fell outside a ±8 ms window, was filed as room noise,
    /// and a silent room got reported as too noisy to measure in. A constant
    /// offset, however large, only moves which bin the clicks share.
    ///
    /// A bin, rather than the overall phase lock (the Rayleigh resultant), because
    /// lock is a property of the whole set and a few leaked clicks among scattered
    /// noise do not raise it: measured, eight leaked clicks mixed with six room
    /// onsets scored 0.67, well under any usable threshold, and would have been
    /// waved through. A busy bin survives the mixture — the same case is caught
    /// 100% of the time.
    private static let soundCheckBins = 16
    /// How far above chance the busiest bin has to stand. With `n` onsets scattered
    /// at random each bin holds about n/bins, give or take its own square root, so
    /// this many deviations clear of the mean is not scatter.
    ///
    /// Nominal, not exact: the bar is the tail of a single histogram, while
    /// `peakPhaseCount` takes the larger of two offset binnings and so gets about
    /// twice the chances — the effective significance is nearer 3 than 3.5. Left
    /// as it is on purpose. Widening it to restore the nominal figure would cost
    /// leak detection, and the number that matters was measured end to end rather
    /// than derived: refusals run at 0% for up to four onsets in a quiet room,
    /// 2.5-3% at eight, while a leak is caught 100% of the time at every tempo.
    private static let soundCheckPeakSigma = 3.5
    /// …and never fewer than this many in the bin, so a handful of onsets cannot
    /// clear the bar just by landing together.
    private static let soundCheckMinimumOnsets = 4
    /// Onsets per second of listening above which the room is refused outright
    /// rather than warned about.
    private static let soundCheckNoiseCeiling = 2.0
    /// …and above which it is worth warning about. Both are rates, so the verdict
    /// does not depend on how long the window happened to be.
    private static let soundCheckQuietRate = 0.5
    /// How far the output volume may rise above what the check passed at before
    /// the take is stopped. One hardware step is 1/16, so this is a nudge.
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
    /// Set when the check passed but the room was not quiet: measuring still
    /// works, it just picks up more than the player.
    private(set) var roomIsNoisy = false
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

    /// True when the output route is a built-in speaker. Advice for the UI only —
    /// it no longer gates anything, because the sound check measures the thing
    /// this used to be a proxy for, and measures it on every route. Stored rather
    /// than computed: the UI has to re-render when the route changes, and a
    /// computed property reading `AVAudioSession` is outside the observation graph.
    private(set) var hearsMetronomeOverSpeaker = true

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
    /// Whether any non-zero audio reached the detector during the check.
    ///
    /// Not a count of level publishes: those run off a 50 ms timer that fires
    /// whenever a buffer arrives, regardless of what is in it, so an input the
    /// system has muted or a microphone under a case delivers zeros at the normal
    /// rate and satisfies a counter. Not a loudness threshold either — that
    /// refuses the best setup there is, a working microphone in a quiet room. Any
    /// real microphone has a noise floor orders above this; only a dead one is
    /// bit-exact silent.
    @ObservationIgnored private var soundCheckSawSignal = false
    /// Whether the click track could be read at all, probed once after the warm-up.
    @ObservationIgnored private var soundCheckGridReadable = true
    /// Length of the counting part of the check, for the onset rate.
    @ObservationIgnored private var soundCheckListenSeconds: Double = 1
    /// Phase within the beat of everything heard during the sound check. Leakage
    /// from the speaker is locked to the beat by construction; a chair creak or a
    /// breath is not, and telling them apart is what keeps a quiet room from being
    /// reported as a speaker problem the player cannot fix by turning the volume
    /// down.
    @ObservationIgnored private var soundCheckPhases: [Double] = []
    /// Onsets the click track could not be read for — an engine that has stopped
    /// rendering. Nothing can be judged from those.
    @ObservationIgnored private var soundCheckUnreadable = 0
    @ObservationIgnored private var soundCheckTask: Task<Void, Never>?
    private weak var metronome: Metronome?

    init() {
        // Observed for the whole lifetime, not just while listening: the button
        // is enabled off this state, so it has to be right before the first tap.
        observeRouteChanges()
        refreshRoute()
    }

    deinit { stopObservingRouteChanges() }

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
        roomIsNoisy = false
        guard isListening else { return nil }
        // A take that never got past the sound check has nothing to report.
        let summary = reason == .user && phase == .grading ? makeSummary() : nil
        phase = .idle   // stops grading notes still in flight on the analysis queue
        inputLevel = 0
        inputSampleRate = 0
        stopObservingVolume()
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
            // Carried over, these hand the new take the previous one's last
            // 50 ms: the meter flashes at a level nothing is producing, and the
            // sound check's liveness evidence starts out already satisfied.
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
            self.analysisQueue.async {
                let onsets = self.detector.process(samples, sampleRate: sampleRate)
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
        refreshRoute()
        checkedOutputs = Self.outputPorts()
        observeVolume()
        // No separate "route still valid" flag guards `register`: the observer
        // stops the take, `stop()` sets `phase = .idle`, and `register` already
        // returns on that. A second guard there was unreachable.
        phase = .soundCheck
        startSoundCheck(metronome)
    }

    /// Prove, on this device and in this room, that the microphone cannot make
    /// out the click — the one thing no filter can promise by itself. The tone is
    /// notched out by construction, but a phone speaker also radiates a broadband
    /// thump through the case, and whether that clears the threshold depends on
    /// the volume, the surface under the phone and the distance to the guitar. So
    /// measure it instead of assuming it.
    ///
    /// Failing closed is the point. A click the detector can hear is not noise in
    /// the result — it lands on the beat, so it would quietly turn the take into
    /// a perfect score.
    private func startSoundCheck(_ metronome: Metronome) {
        resetSoundCheck()
        // Nothing is counted for the first second. `OnsetDetector`'s noise tracker
        // starts cold at 0.001 and has a 2 s time constant, so during that window
        // its threshold is the bare `silenceFloor` — far lower than it will be
        // once the room is learned. Counting there would hold the take to a
        // stricter standard than the grading it is supposed to gate, and refuse
        // setups that work.
        let warmUp = 1
        // The route may still be settling from activating the session and engaging
        // the input; let it, right up to the moment the tally starts.
        routeSettlesAt = Date().addingTimeInterval(Double(warmUp))
        // Twice `soundCheckMinimumOnsets` beats, not exactly that many. Sized to
        // the minimum, the window holds precisely as many leaked clicks as the bar
        // demands, so any room noise at all raises the bar past what the window can
        // physically contain and real leakage passes as merely noisy. Doubling
        // gives the leak somewhere to stand. Measured in beats and not seconds
        // because a fixed window holds too few beats at slow tempos.
        let needed = 2 * Double(Self.soundCheckMinimumOnsets) * metronome.beatSeconds
        // 10 s is reached at 48 bpm, so the cap is real: without it the slowest
        // tempo on the slider would ask for 12 s of silence.
        let listen = Int(min(10, max(2, needed.rounded(.up))))
        soundCheckListenSeconds = Double(listen)
        // Set before the task, or the first rendered frame shows a countdown of 0
        // and then animates upwards under a label saying how long to stay quiet.
        soundCheckSecondsLeft = warmUp + listen
        soundCheckTask = Task { @MainActor [weak self] in
            for remaining in stride(from: warmUp + listen, through: 1, by: -1) {
                guard let self, self.phase == .soundCheck else { return }
                self.soundCheckSecondsLeft = remaining
                if remaining == listen {
                    // Warm-up over: start counting from a settled detector, and
                    // ask the click track once whether it can be read at all. In a
                    // quiet room over headphones nothing fires, so without a
                    // positive probe here an engine that renders into nothing
                    // passes the check and then grades every note as unreadable
                    // for the rest of the session with no message.
                    self.resetSoundCheck()
                    self.soundCheckGridReadable =
                        metronome.beatPhase(atHostTime: mach_absolute_time()) != nil
                }
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            guard let self, self.phase == .soundCheck else { return }
            self.soundCheckSecondsLeft = 0
            switch self.soundCheckVerdict() {
            case .refuse(let why):
                self.stop()
                self.failure = why
                return
            case .pass(let noisy):
                self.roomIsNoisy = noisy
            }
            // The check's own onsets are not the take's: leaving them in would
            // show "notes 3 · measured 0" before a note is played, which is the
            // published signature of a grid that can't be read.
            self.detectedNotes = 0
            self.phase = .grading
        }
    }

    /// What the sound check concluded.
    private enum SoundCheckVerdict {
        case pass(noisy: Bool)
        case refuse(String)
    }

    /// Read the check. A value rather than a predicate with a side effect: the
    /// room-noise warning and the verdict are one decision, and splitting them
    /// meant the warning could only be produced by asking why the check failed.
    ///
    /// Only two things are worth refusing over. A click the microphone can hear
    /// lands on the beat, so it would be graded as a flawless note and inflate the
    /// take — wrong, and looking right. And a room loud enough to bury the click
    /// in its own clutter, because then neither this check nor the take can tell
    /// one from the other. Everything between is a warning: notes the player did
    /// not play drag the score *down* and show up in the readout, and blocking
    /// someone out of a usable feature over a humming fridge is the worse mistake.
    private func soundCheckVerdict() -> SoundCheckVerdict {
        // Liveness is "did buffers arrive", not "was it loud enough". A level
        // threshold refuses the best setup there is — a quiet room over
        // headphones, where the microphone is working and has nothing to report.
        guard soundCheckSawSignal else {
            return .refuse("The microphone isn't picking anything up. Check that nothing is covering it and that no other app is using it.")
        }
        guard soundCheckGridReadable, soundCheckUnreadableRatio < 0.5 else {
            return .refuse("Lost track of the click while checking. Start the metronome again.")
        }
        let heard = soundCheckPhases.count
        let rate = Double(heard) / max(1, soundCheckListenSeconds)
        guard heard >= Self.soundCheckMinimumOnsets else {
            return .pass(noisy: rate > Self.soundCheckQuietRate)
        }

        let expected = Double(heard) / Double(Self.soundCheckBins)
        let bar = max(Double(Self.soundCheckMinimumOnsets),
                      expected + Self.soundCheckPeakSigma * expected.squareRoot())
        let peak = Self.peakPhaseCount(soundCheckPhases)
        if Double(peak) >= bar {
            // Phase alone cannot separate a leaked click from the player keeping
            // time — a tapped foot is on the beat by definition, and it is close
            // to a reflex while a metronome is running. So the message names both
            // and offers a remedy for each, rather than sending someone to turn
            // down a volume that was never the problem.
            return .refuse("Something is landing right on the beat — \(peak) times. That is either the click coming back through the speaker or you keeping time. Stay completely still, turn the volume down, or use headphones.")
        }
        // Above this rate the bar itself outgrows the number of clicks the window
        // can hold, so leakage could hide behind the noise. Refusing closes that,
        // and a room this busy was not going to give a usable take anyway.
        if rate > Self.soundCheckNoiseCeiling {
            return .refuse("Too much going on in the room to tell your playing from the click. Somewhere quieter, or headphones.")
        }
        return .pass(noisy: rate > Self.soundCheckQuietRate)
    }

    /// The most onsets sharing a point in the beat. Counted over two binnings a
    /// half-bin apart, so a cluster sitting on a bin edge is not split in two and
    /// read as scatter.
    private static func peakPhaseCount(_ phases: [Double]) -> Int {
        let bins = soundCheckBins
        var best = 0
        for shift in [0, 0.5 / Double(bins)] {
            var counts = [Int](repeating: 0, count: bins)
            for phase in phases {
                let shifted = (phase + shift).truncatingRemainder(dividingBy: 1)
                counts[min(bins - 1, Int(shifted * Double(bins)))] += 1
            }
            best = max(best, counts.max() ?? 0)
        }
        return best
    }

    private func resetSoundCheck() {
        soundCheckPhases.removeAll()
        soundCheckUnreadable = 0
        soundCheckSawSignal = false
    }

    /// Share of onsets whose grid position could not be read. A ratio and not a
    /// count: a single unreadable onset is a transient, and everything else in the
    /// verdict is tolerant.
    private var soundCheckUnreadableRatio: Double {
        let total = soundCheckPhases.count + soundCheckUnreadable
        return total == 0 ? 0 : Double(soundCheckUnreadable) / Double(total)
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
            guard let self else { return }
            self.refreshRoute()
            guard self.isListening else { return }
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let deviceGone = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable
            // Any change of output port invalidates the take: the sound check
            // was run for the route it started on and says nothing about this one.
            // Compared as a port set rather than by `hearsMetronomeOverSpeaker`,
            // which cannot tell a Bluetooth headset from a Bluetooth speaker.
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

    /// Watch the output volume for the life of the take. Only a rise matters:
    /// turning it down can only reduce what the microphone hears.
    private func observeVolume() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        checkedVolume = session.outputVolume
        volumeObserver = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let volume = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isListening,
                      volume > self.checkedVolume + Self.volumeTolerance else { return }
                self.stop()
                self.failure = "The volume went up, so the check no longer holds. Start it again."
            }
        }
        #endif
    }

    private func stopObservingVolume() {
        volumeObserver?.invalidate()
        volumeObserver = nil
    }

    /// The current output ports, by type. The sound check is pinned to this set.
    private static func currentVolume() -> Float {
        #if os(iOS)
        AVAudioSession.sharedInstance().outputVolume
        #else
        0
        #endif
    }

    private static func outputPorts() -> Set<String> {
        #if os(iOS)
        Set(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue))
        #else
        []
        #endif
    }

    /// Re-read the output route. Public so the UI can ask before the session has
    /// ever been activated, when the route is still unknown.
    func refreshRoute() {
        #if os(iOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        // Unknown counts as a speaker: it only drives advice now, and advising
        // headphones is the harmless side of that guess.
        hearsMetronomeOverSpeaker = outputs.isEmpty || outputs.contains { $0.portType == .builtInSpeaker }
        #else
        hearsMetronomeOverSpeaker = false
        #endif
    }

    private func stopObservingRouteChanges() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
    }

    /// Peak level with a slow fall, so the meter doesn't flicker between buffers.
    private func updateLevel(_ peak: Float) {
        inputLevel = peak > inputLevel ? peak : inputLevel * 0.8 + peak * 0.2
        if phase == .soundCheck, peak > 1e-6 { soundCheckSawSignal = true }
    }

    /// Grade one detected note against the metronome grid.
    private func register(hostTime: UInt64) {
        // Onsets reach this hop by hop (analysis queue → main actor), so a note
        // detected just before the stop arrives after it. Grading it would leave
        // the take one or two notes past the summary the user is already reading.
        guard phase != .idle else { return }
        detectedNotes += 1
        if phase == .soundCheck {
            // Heard while the player was asked to stay quiet. Only the phase is
            // recorded; what it means is decided once, over all of them, in
            // `soundCheckVerdict()`.
            // `beat`, not `phase`: the branch is selected by the `phase` property
            // two lines up, and a Double shadowing that enum is the same hazard the
            // notch loop carries a warning about.
            if let beat = metronome?.beatPhase(atHostTime: hostTime) {
                soundCheckPhases.append(beat)
            } else {
                soundCheckUnreadable += 1
            }
            return
        }
        guard let deviation = metronome?.deviation(atHostTime: hostTime) else { return }
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
                       latestMs: takeMax, tape: hits, overSpeaker: hearsMetronomeOverSpeaker)
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

/// Time-domain transient detector.
///
/// A note attack is a short burst well above the level just before it, so the
/// rectified, pre-emphasised signal is compared against two trackers: a fast one
/// (~60 ms) that represents "what was already sounding", and a slow one (~2 s)
/// that represents room noise. A rise above both, outside the refractory window,
/// is an onset. Both trackers are updated *after* the test so an attack never
/// raises the bar it has to clear.
///
/// The only thing between this and the metronome's own click is a notch on each of
/// `Metronome.clickTones`. Notches and not a low-pass, which was tried and
/// measured: the click is two known frequencies while a pick attack is broadband,
/// so cutting a region of the spectrum to remove the tones takes the attack with
/// it. A 2.2 kHz low-pass found 2 of 16 tremolo notes, missed half of eight
/// well-spaced single notes and missed quiet playing entirely — what survives a
/// low-pass is the ringing fundamental, which keeps the `fast` tracker high, and
/// the next attack can no longer clear it.
///
/// They cost nothing measurable: every pitch still fires within 0.02 ms, including
/// a bend whose fundamental sits inside a notch, and fast tremolo actually stops
/// double-triggering (22 onsets for 16 notes without them, 16 with). Five narrow
/// slices out of an attack that spans the whole spectrum is not much to lose.
struct OnsetDetector {

    /// Notch width. A section's -3 dB bandwidth is its centre frequency divided by
    /// this, so Q = 1 means a notch at 1 kHz is a kilohertz wide — and cascaded
    /// two and three deep across five frequencies, that is not five slices but a
    /// band-stop. Measured against pre-emphasis alone, Q = 1 threw away 23.9 dB
    /// across 300 Hz-6 kHz, the band a pick attack lives in. Q = 2 halves that to
    /// 10 dB and still rejects the click at every level; Q = 3 and above stops
    /// rejecting it, because the notches then only remove the carrier and not the
    /// broadband splash of the click's own attack, which is what actually fires
    /// the detector.
    ///
    /// The loss that remains is roughly flat over the band, and every test here
    /// but `silenceFloor` is a ratio, so it costs no detection: 10 of 10 pitches
    /// at full level and at -26 dB, with or without the notches. Lowering
    /// `silenceFloor` to "compensate" recovers nothing and only lifts the click
    /// back towards the threshold — measured, not assumed.
    private static let notchQ = 2.0

    /// Which frequencies to notch, and how hard.
    ///
    /// The click's own tones are the obvious half. The other half is their
    /// harmonics, because a small speaker driven hard distorts, and distortion of
    /// a 1 kHz tone comes out at 2 and 3 kHz where nothing was notching it. That
    /// is not a rounding error: on the tones alone the click survives 10%
    /// distortion at 3.6x `silenceFloor` and fires. With the harmonics covered it
    /// stays at 0.03x even at 20%, which is further than a phone speaker goes.
    ///
    /// Three sections on the tones and two on each harmonic, since the distortion
    /// products start far weaker than the fundamental they come from.
    private static var notchPlan: [(frequency: Double, sections: Int)] {
        let tones = Metronome.clickTones
        // Every 2nd and 3rd harmonic of both tones, merged by nearness rather
        // than by equality. With the current tones the beat's 3rd and the accent's
        // 2nd are both 3 kHz and collapse to one entry — but that is bit-equality
        // between two independently computed Doubles, so listing only one of them
        // would leave the other uncovered the moment the tones are retuned, and an
        // uncovered harmonic is what lets a distorting speaker through.
        var plan: [(frequency: Double, sections: Int)] = [(tones.beat, 3), (tones.accent, 3)]
        for harmonic in [tones.beat * 2, tones.beat * 3, tones.accent * 2, tones.accent * 3] {
            guard !plan.contains(where: { abs($0.frequency - harmonic) < 1 }) else { continue }
            plan.append((harmonic, 2))
        }
        return plan
    }

    /// One RBJ notch section, direct form I.
    private struct Notch {
        private let b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        init(frequency: Double, q: Double, sampleRate: Double) {
            let w = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(w) / (2 * q)
            let cosW = cos(w)
            let a0 = 1 + alpha
            b0 = Float(1 / a0)
            b1 = Float(-2 * cosW / a0)
            b2 = Float(1 / a0)
            a1 = Float(-2 * cosW / a0)
            a2 = Float((1 - alpha) / a0)
        }

        mutating func process(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            return y
        }
    }

    private var sampleRate: Double
    private var fastCoef: Float
    private var noiseCoef: Float
    private var refractory: Int
    /// `notchSections` sections per click tone, in series.
    private var notches: [Notch]

    private var fast: Float = 0
    private var noise: Float = 0.001
    private var previous: Float = 0
    private var sinceOnset = Int.max

    /// A note must stand this far above what was already sounding.
    private static let riseFactor: Float = 3
    /// …and this far above the room noise, so a quiet room doesn't self-trigger.
    private static let noiseFactor: Float = 8
    /// Absolute floor — below this it is silence, whatever the ratios say.
    private static let silenceFloor: Float = 0.006

    init(sampleRate: Double = 44_100) {
        self.sampleRate = sampleRate
        fastCoef = Float(1 - exp(-1 / (0.06 * sampleRate)))
        noiseCoef = Float(1 - exp(-1 / (2.0 * sampleRate)))
        refractory = Int(0.08 * sampleRate)   // 80 ms — no double-triggering on one attack
        // A frequency at or above Nyquist cannot be notched — the coefficients
        // would be nonsense — but it cannot be captured either, so dropping its
        // sections loses nothing. This only ever bites the upper harmonics on a
        // narrowband telephony route; both click tones are well inside even 8 kHz.
        notches = Self.notchPlan
            .filter { $0.frequency < sampleRate * 0.45 }
            .flatMap { entry in
                (0..<entry.sections).map { _ in
                    Notch(frequency: entry.frequency, q: Self.notchQ, sampleRate: sampleRate)
                }
            }
    }

    /// Offsets, in samples from the start of this buffer, of the onsets found.
    /// The hardware rate is only known once buffers start arriving, so the
    /// detector re-tunes itself the first time it sees a different one.
    mutating func process(_ samples: [Float], sampleRate: Double) -> [Int] {
        if sampleRate != self.sampleRate { self = OnsetDetector(sampleRate: sampleRate) }
        var onsets: [Int] = []
        for (i, sample) in samples.enumerated() {
            // Pre-emphasis: removes rumble/DC and lifts the attack over the body.
            var value = sample - 0.97 * previous
            previous = sample
            // `k`, not `i`: `i` is the sample offset this loop's caller appends
            // to `onsets`, and a shadow here would turn a filter index into an
            // onset timestamp at the head of the buffer.
            for k in notches.indices { value = notches[k].process(value) }
            let magnitude = abs(value)

            if sinceOnset < Int.max { sinceOnset += 1 }
            let threshold = max(fast * Self.riseFactor, noise * Self.noiseFactor, Self.silenceFloor)
            if magnitude > threshold, sinceOnset > refractory {
                onsets.append(i)
                sinceOnset = 0
            }

            fast += (magnitude - fast) * fastCoef
            noise += (magnitude - noise) * noiseCoef
        }
        return onsets
    }
}
