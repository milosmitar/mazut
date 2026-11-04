//
//  NoteTrainerView.swift
//  Mazut
//
//  "Find the note" drill, reached from the Learning tab: the app names a note
//  and a string, the player finds it on the fretboard and plays it, and the
//  tuner's pitch detection says whether it was right.
//
//  The microphone hears pitch, not strings — A3 on the 4th string's 7th fret is
//  the same 220 Hz as the 3rd string's 2nd fret. So a target is accepted on the
//  exact note *and octave* that string can give within the chosen fret range,
//  and the fretboard then shows where it was, which is the part being learned.
//

import SwiftUI
import Observation

// MARK: - Game logic

@Observable
final class NoteTrainer {

    struct Settings: Equatable {
        /// Guitar numbering: 1 = high E … 6 = low E.
        var strings: Set<Int> = Set(1...6)
        var maxFret = 12
        var includeSharps = false
        var notesPerRound = 10
        var tuning: GuitarTuning = .standard
    }

    struct Target: Equatable {
        let string: Int
        let pitchClass: Int
        /// Frets on that string, within the range, that give this note. Usually
        /// one; two when the range reaches past the 12th fret.
        let frets: [Int]
        let openMidi: Int

        var name: String { Tuner.noteName(forMidi: pitchClass) }
        var acceptedMidi: Set<Int> { Set(frets.map { openMidi + $0 }) }
    }

    /// How one target went, for the round summary.
    struct Attempt {
        let target: Target
        let seconds: Double
        let wrongNotes: Int
    }

    struct Summary {
        let attempts: [Attempt]
        let totalSeconds: Double

        var firstTry: Int { attempts.filter { $0.wrongNotes == 0 }.count }
        var wrongNotes: Int { attempts.map(\.wrongNotes).reduce(0, +) }
        /// From the attempts themselves: the round's wall time also holds the
        /// pause after every found note.
        var averageSeconds: Double {
            attempts.isEmpty ? 0 : attempts.map(\.seconds).reduce(0, +) / Double(attempts.count)
        }
        /// The notes that took longest — what to practise next.
        var toughest: [Attempt] {
            Array(attempts.sorted { $0.seconds > $1.seconds }.prefix(3))
        }
    }

    enum Phase: Equatable {
        case setup
        case playing
        /// Found, on this fret; the next target follows after a moment.
        case solved(fret: Int)
        case finished
    }

    /// Readings in a row (~85 ms each) a note must hold to count: about a
    /// quarter second, so a note passed through on the way is not an answer.
    private static let holdReadings = 3
    /// Further out of tune than this is not taken as that note.
    private static let centsTolerance = 35.0
    /// How long a found note stays on screen before the next one.
    private static let solvedPause = 0.9
    /// A buffer this much louder than the last is a new pluck, not the string
    /// still ringing. A decaying string only ever gets quieter.
    private static let attackRise: Float = 1.8
    private static let attackFloor: Float = 0.02

    var settings = Settings()
    private(set) var phase: Phase = .setup
    private(set) var target: Target?
    private(set) var targetNumber = 0
    /// The last held note that was not the target, for "Heard G3".
    private(set) var heardWrong: Int?
    private(set) var summary: Summary?

    let tuner = Tuner()

    @ObservationIgnored private var heldMidi: Int?
    @ObservationIgnored private var heldCount = 0
    /// A wrong note is counted once while it is held, not once per reading.
    @ObservationIgnored private var countedWrong: Int?
    /// The previous answer's notes, still ringing when the next target appears.
    /// They count for nothing — not as a find, not as a mistake — until the
    /// string goes quiet, is plucked again, or another note is held. Otherwise a
    /// next target on the same pitch (A3 is on the 3rd string *and* the 4th)
    /// solves itself.
    @ObservationIgnored private var ringing: Set<Int> = []
    @ObservationIgnored private var lastLevel: Float = 0
    /// When the microphone stopped on its own, so the clock can skip the gap.
    @ObservationIgnored private var pausedAt: Date?
    @ObservationIgnored private var targetShownAt = Date()
    @ObservationIgnored private var roundStartedAt = Date()
    @ObservationIgnored private var wrongForTarget = 0
    @ObservationIgnored private var attempts: [Attempt] = []
    @ObservationIgnored private var advanceTask: Task<Void, Never>?

    init() {
        tuner.onReading = { [weak self] midi, cents, level in
            self?.handle(midi: midi, cents: cents, level: level)
        }
        tuner.onFailure = { [weak self] in self?.pausedAt = Date() }
    }

    /// The microphone stopped mid-round (a call, Siri) and can be restarted.
    var isPaused: Bool { tuner.failure != nil && (phase == .playing || phase.isSolved) }

    /// Pick the round up where it stopped. The time the microphone was off is
    /// not counted against the note being looked for.
    func resume() {
        if let pausedAt {
            let gap = Date().timeIntervalSince(pausedAt)
            // A target shown during the pause (the one after a find) was not
            // being looked for before it either.
            targetShownAt = targetShownAt < pausedAt ? targetShownAt + gap : Date()
            roundStartedAt += gap
        }
        pausedAt = nil
        heldMidi = nil
        heldCount = 0
        tuner.start()
    }

    /// Every (string, note) pair the settings allow, with the frets giving it.
    var candidates: [Target] {
        let open = settings.tuning.strings
        guard open.count == 6 else { return [] }
        var targets: [Target] = []
        for string in settings.strings.sorted() {
            let openMidi = open[6 - string]
            var fretsByNote: [Int: [Int]] = [:]
            for fret in 0...settings.maxFret {
                let pc = (openMidi + fret) % 12
                if !settings.includeSharps, Self.isSharp(pc) { continue }
                fretsByNote[pc, default: []].append(fret)
            }
            for (pc, frets) in fretsByNote {
                targets.append(Target(string: string, pitchClass: pc, frets: frets, openMidi: openMidi))
            }
        }
        return targets
    }

    var canStart: Bool { !settings.strings.isEmpty && settings.tuning.strings.count == 6 }

    func startRound() {
        guard canStart else { return }
        advanceTask?.cancel()
        attempts.removeAll()
        summary = nil
        targetNumber = 0
        ringing = []
        pausedAt = nil
        roundStartedAt = Date()
        tuner.start()
        nextTarget()
    }

    /// Back to the settings, abandoning the round.
    func endRound() {
        advanceTask?.cancel()
        tuner.stop()
        target = nil
        phase = .setup
    }

    /// Leaving the screen: the microphone goes off, whatever the phase.
    func suspend() {
        advanceTask?.cancel()
        tuner.stop()
        if phase == .playing || phase.isSolved { phase = .setup }
    }

    private func nextTarget() {
        let all = candidates
        guard let next = all.filter({ $0 != target }).randomElement() ?? all.randomElement()
        else { return endRound() }
        target = next
        targetNumber += 1
        heardWrong = nil
        countedWrong = nil
        heldMidi = nil
        heldCount = 0
        wrongForTarget = 0
        targetShownAt = Date()
        phase = .playing
    }

    private func handle(midi: Int?, cents: Double, level: Float) {
        let attack = level > Self.attackFloor && level > lastLevel * Self.attackRise
        lastLevel = level
        guard phase == .playing, let target else { return }
        if attack, !ringing.isEmpty {
            // Plucked again: whatever sounds now is a fresh answer, and has to be
            // held like one.
            ringing = []
            heldMidi = nil
            heldCount = 0
        }
        guard let midi, abs(cents) <= Self.centsTolerance else {
            heldMidi = nil
            heldCount = 0
            // Silence ends the wrong note — playing it again is a new mistake —
            // and the last answer's ring.
            if midi == nil {
                countedWrong = nil
                ringing = []
            }
            return
        }
        if midi == heldMidi { heldCount += 1 } else { heldMidi = midi; heldCount = 1 }
        guard heldCount >= Self.holdReadings else { return }
        guard !ringing.contains(midi) else { return }
        ringing = []   // a different note held: the last answer has stopped sounding

        if target.acceptedMidi.contains(midi) {
            solve(target, fret: midi - target.openMidi)
        } else if midi != countedWrong {
            countedWrong = midi
            heardWrong = midi
            wrongForTarget += 1
        }
    }

    private func solve(_ target: Target, fret: Int) {
        attempts.append(Attempt(target: target,
                                seconds: Date().timeIntervalSince(targetShownAt),
                                wrongNotes: wrongForTarget))
        ringing = target.acceptedMidi
        heardWrong = nil
        phase = .solved(fret: fret)
        advanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.solvedPause))
            guard let self, !Task.isCancelled else { return }
            if self.targetNumber >= self.settings.notesPerRound {
                self.finish()
            } else {
                self.nextTarget()
            }
        }
    }

    private func finish() {
        tuner.stop()
        // The last find can land just before the microphone stops (a call): the
        // round then ended at the pause, not now.
        let end = pausedAt ?? Date()
        summary = Summary(attempts: attempts,
                          totalSeconds: end.timeIntervalSince(roundStartedAt))
        target = nil
        phase = .finished
    }

    static func isSharp(_ pitchClass: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(pitchClass)
    }

    static func ordinal(_ n: Int) -> String {
        switch n {
        case 1: "1st"
        case 2: "2nd"
        case 3: "3rd"
        default: "\(n)th"
        }
    }
}

extension NoteTrainer.Phase {
    var isSolved: Bool {
        if case .solved = self { return true }
        return false
    }
}

// MARK: - Screen

struct NoteTrainerView: View {
    /// Made on appear, not with the view. A `NavigationLink` builds its
    /// destination every time the list holding it refreshes, and a trainer made
    /// in a `@State` initializer is made — tuner, audio engine and all — on each
    /// of those, then thrown away unopened.
    @State private var trainer: NoteTrainer?

    var body: some View {
        Group {
            if let trainer {
                NoteTrainerScreen(trainer: trainer)
            } else {
                TabBackgroundView()
            }
        }
        .onAppear { if trainer == nil { trainer = NoteTrainer() } }
    }
}

private struct NoteTrainerScreen: View {
    @Bindable var trainer: NoteTrainer
    /// Optional so the screen still works where nobody provided one (previews).
    @Environment(Metronome.self) private var metronome: Metronome?

    var body: some View {
        ZStack {
            TabBackgroundView()
            switch trainer.phase {
            case .setup:
                setup
            case .playing, .solved:
                drill
            case .finished:
                results
            }
        }
        .navigationTitle("Find the Note")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { trainer.suspend() }
        // Play from the lock screen mid-drill switches the session to playback,
        // which has no input — and the song would be heard as wrong notes anyway.
        // `suspend` only abandons a round in progress — results already on
        // screen stay there.
        .onChange(of: StemMixerEngine.shared.isPlaying) { _, playing in
            if playing { trainer.suspend() }
        }
    }

    // MARK: Setup

    private var setup: some View {
        Form {
            Section {
                Text("The app names a note and a string. Find it on the fretboard and play it — the microphone listens for the right note in the right octave.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Strings") {
                HStack(spacing: 8) {
                    ForEach(1...6, id: \.self) { string in
                        let on = trainer.settings.strings.contains(string)
                        Button {
                            if on { trainer.settings.strings.remove(string) }
                            else { trainer.settings.strings.insert(string) }
                        } label: {
                            VStack(spacing: 2) {
                                Text("\(string)").font(.headline)
                                Text(openName(string)).font(.caption2)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(on ? Color.accentColor : Color.primary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(on ? Color.white : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Range") {
                Picker("Up to fret", selection: $trainer.settings.maxFret) {
                    ForEach([5, 7, 12, 15], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Sharps too", isOn: $trainer.settings.includeSharps)
            }

            Section("Round") {
                Picker("Notes", selection: $trainer.settings.notesPerRound) {
                    ForEach([10, 20, 30], id: \.self) { Text("\($0) notes").tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Tuning", selection: $trainer.settings.tuning) {
                    ForEach(GuitarTuning.all.filter { !$0.isChromatic }) { Text($0.name).tag($0) }
                }
            }

        }
        .scrollContentBackground(.hidden)
        // Out of the form and pinned just above the tab bar, styled like the
        // metronome's Start: the one thing to press once the settings are right.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                if !trainer.canStart {
                    Text("Pick at least one string.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    begin()
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .disabled(!trainer.canStart)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    /// The metronome and the song stems go quiet first. The microphone would hear
    /// them as wrong notes, and the tuner's session switch to recording would cut
    /// them off anyway, without the UI knowing they had stopped. (When the tuner
    /// stops it deactivates the session only if nothing of Mazut's is playing —
    /// see `AudioSessionHandoff`.)
    private func begin() {
        metronome?.stop()
        if StemMixerEngine.shared.isPlaying { StemMixerEngine.shared.pause() }
        trainer.startRound()
    }

    private func openName(_ string: Int) -> String {
        let open = trainer.settings.tuning.strings
        return open.count == 6 ? Tuner.noteName(forMidi: open[6 - string]) : ""
    }

    // MARK: Drill

    private var drill: some View {
        VStack(spacing: 20) {
            Text("\(trainer.targetNumber) / \(trainer.settings.notesPerRound)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            if let target = trainer.target {
                VStack(spacing: 4) {
                    Text(target.name)
                        .font(.system(size: 96, weight: .bold, design: .rounded))
                        .foregroundStyle(trainer.phase.isSolved ? Color.green : .primary)
                        .contentTransition(.numericText())
                    Text("on the \(NoteTrainer.ordinal(target.string)) string (\(openName(target.string)))")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .animation(.easeOut(duration: 0.15), value: target)

                FretboardView(tuning: trainer.settings.tuning,
                              maxFret: trainer.settings.maxFret,
                              highlightedString: target.string,
                              dotFret: solvedFret)
                    .frame(height: 150)
                    .padding(.horizontal, 16)
            }

            feedback
                .frame(height: 30)

            if let problem = trainer.tuner.permissionDenied
                ? "Microphone access is off — turn it on in Settings › Mazut."
                : trainer.tuner.failure {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if trainer.isPaused {
                Button {
                    trainer.resume()
                } label: {
                    Label("Resume", systemImage: "mic.fill")
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()

            Button(role: .cancel) {
                trainer.endRound()
            } label: {
                Text("End round")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    private var solvedFret: Int? {
        if case .solved(let fret) = trainer.phase { return fret }
        return nil
    }

    @ViewBuilder
    private var feedback: some View {
        if let fret = solvedFret {
            Label(fret == 0 ? "Open string" : "\(NoteTrainer.ordinal(fret)) fret",
                  systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
        } else if let wrong = trainer.heardWrong {
            Label("Heard \(Tuner.noteName(forMidi: wrong, withOctave: true)) — try again",
                  systemImage: "xmark.circle")
                .font(.headline)
                .foregroundStyle(.orange)
        } else {
            Label(trainer.tuner.hasSignal ? trainer.tuner.noteNameWithOctave : "Listening…",
                  systemImage: "ear")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Results

    private var results: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let summary = trainer.summary {
                    VStack(spacing: 6) {
                        Text("\(summary.firstTry) of \(summary.attempts.count)")
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                        Text("found on the first try")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 24)

                    VStack(spacing: 0) {
                        resultRow("Time", Self.seconds(summary.totalSeconds))
                        Divider()
                        resultRow("Per note", Self.seconds(summary.averageSeconds))
                        Divider()
                        resultRow("Wrong notes", "\(summary.wrongNotes)")
                    }
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

                    if !summary.toughest.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Took the longest")
                                .font(.headline)
                            ForEach(Array(summary.toughest.enumerated()), id: \.offset) { _, attempt in
                                HStack {
                                    Text("\(attempt.target.name) · \(NoteTrainer.ordinal(attempt.target.string)) string")
                                    Spacer()
                                    Text(Self.seconds(attempt.seconds))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                .font(.subheadline)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    }
                }

                Button {
                    begin()
                } label: {
                    Label("Play again", systemImage: "arrow.clockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)

                Button("Change settings") { trainer.endRound() }
            }
            .padding(.horizontal, 20)
        }
    }

    private func resultRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().fontWeight(.semibold)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private static func seconds(_ s: Double) -> String {
        s < 60 ? String(format: "%.1f s", s) : String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

// MARK: - Fretboard

/// The neck as tab reads it: 1st string (high E) on top. The target string is
/// highlighted; once the note is found, a dot marks the fret it was on.
private struct FretboardView: View {
    let tuning: GuitarTuning
    let maxFret: Int
    let highlightedString: Int
    let dotFret: Int?

    var body: some View {
        Canvas { context, size in
            let labelWidth: CGFloat = 22
            let width = size.width - labelWidth
            let rowHeight = size.height / 7
            let fretWidth = width / CGFloat(maxFret + 1)
            func y(_ string: Int) -> CGFloat { rowHeight * CGFloat(string) }
            // Fret 0 is the open string, drawn left of the nut.
            func x(_ fret: Int) -> CGFloat { labelWidth + fretWidth * (CGFloat(fret) + 0.5) }

            FretboardDrawing.drawInlays(in: context, frets: 0...maxFret, x: x,
                                        centerY: size.height / 2, rowGap: rowHeight, diameter: 8)

            // Frets; the nut heavier.
            for fret in 0...maxFret {
                let fx = labelWidth + fretWidth * CGFloat(fret + 1)
                var line = Path()
                line.move(to: CGPoint(x: fx, y: y(1)))
                line.addLine(to: CGPoint(x: fx, y: y(6)))
                context.stroke(line, with: .color(.primary.opacity(fret == 0 ? 0.7 : 0.25)),
                               lineWidth: fret == 0 ? 3 : 1)
            }

            // Strings, with their open note on the left.
            for string in 1...6 {
                let on = string == highlightedString
                var line = Path()
                line.move(to: CGPoint(x: labelWidth, y: y(string)))
                line.addLine(to: CGPoint(x: size.width, y: y(string)))
                context.stroke(line, with: .color(on ? .accentColor : .primary.opacity(0.35)),
                               lineWidth: on ? 3 : 1)
                if tuning.strings.count == 6 {
                    let name = Tuner.noteName(forMidi: tuning.strings[6 - string])
                    context.draw(Text(name).font(.caption2.bold())
                                    .foregroundStyle(on ? Color.accentColor : Color.secondary),
                                 at: CGPoint(x: labelWidth / 2, y: y(string)))
                }
            }

            if let dotFret {
                let dot = CGRect(x: x(dotFret) - 9, y: y(highlightedString) - 9, width: 18, height: 18)
                context.fill(Path(ellipseIn: dot), with: .color(.green))
            }
        }
    }
}

#Preview {
    NavigationStack { NoteTrainerView() }
        .preferredColorScheme(.dark)
}
