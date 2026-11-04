//
//  ScalesView.swift
//  Mazut
//
//  Scale positions, reached from the Learning tab: pick a scale and a key, and
//  every position of it is drawn on its own fretboard, with the whole neck
//  above for how they join up.
//
//  Positions are worked out, not written out, so every key and every scale
//  comes from one rule. Position n starts on the scale's n-th note up from the
//  root on the low E string, then climbs the scale a fixed number of notes per
//  string: two for the pentatonics — which is exactly the five familiar boxes —
//  and three for seven-note scales, the three-notes-per-string system.
//

import SwiftUI

// MARK: - Theory

enum ScaleKind: String, CaseIterable, Identifiable {
    case minorPentatonic = "Minor Pentatonic"
    case majorPentatonic = "Major Pentatonic"
    case blues = "Blues"
    case major = "Major"
    case naturalMinor = "Natural Minor"
    case harmonicMinor = "Harmonic Minor"

    var id: String { rawValue }

    /// Semitones above the root, the letter each is written on (0 = the
    /// root's), and its interval name.
    var degrees: [(step: Int, letter: Int, interval: String)] {
        switch self {
        case .minorPentatonic: [(0, 0, "1"), (3, 2, "♭3"), (5, 3, "4"), (7, 4, "5"), (10, 6, "♭7")]
        case .majorPentatonic: [(0, 0, "1"), (2, 1, "2"), (4, 2, "3"), (7, 4, "5"), (9, 5, "6")]
        case .blues: [(0, 0, "1"), (3, 2, "♭3"), (5, 3, "4"), (6, 4, "♭5"), (7, 4, "5"), (10, 6, "♭7")]
        case .major: [(0, 0, "1"), (2, 1, "2"), (4, 2, "3"), (5, 3, "4"), (7, 4, "5"), (9, 5, "6"), (11, 6, "7")]
        case .naturalMinor: [(0, 0, "1"), (2, 1, "2"), (3, 2, "♭3"), (5, 3, "4"), (7, 4, "5"), (8, 5, "♭6"), (10, 6, "♭7")]
        case .harmonicMinor: [(0, 0, "1"), (2, 1, "2"), (3, 2, "♭3"), (5, 3, "4"), (7, 4, "5"), (8, 5, "♭6"), (11, 6, "7")]
        }
    }

    /// The notes positions are built from. Blues is the minor pentatonic's boxes
    /// with the ♭5 added wherever it falls inside them — that is how it is
    /// taught, and walking all six notes two to a string gives no box anyone plays.
    var boxSteps: [Int] {
        self == .blues ? ScaleKind.minorPentatonic.degrees.map(\.step) : degrees.map(\.step)
    }

    var notesPerString: Int { boxSteps.count == 5 ? 2 : 3 }

    /// Major-sounding scales are named in flats where a key has the choice (D♭,
    /// A♭), minor ones in sharps (C♯, G♯) — whichever key signature exists.
    var isMajorFamily: Bool { self == .major || self == .majorPentatonic }

    static func rootName(_ pitchClass: Int, majorFamily: Bool) -> String {
        majorFamily
            ? ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"][pitchClass]
            : ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "G#", "A", "Bb", "B"][pitchClass]
    }
}

/// One dot on the fretboard.
struct ScaleNote: Hashable {
    /// 0 = low E.
    let string: Int
    let fret: Int
    let name: String
    let interval: String
    var isRoot: Bool { interval == "1" }
}

struct ScalePosition: Identifiable {
    let number: Int
    let notes: [ScaleNote]
    var id: Int { number }
    var lowestFret: Int { notes.map(\.fret).min() ?? 0 }
    var highestFret: Int { notes.map(\.fret).max() ?? 0 }
}

enum ScaleBuilder {
    private static let openStrings = GuitarTuning.standard.strings   // low E → high E
    /// The highest fret drawn; positions reaching past it are taken an octave down.
    static let topFret = 15

    /// Name and interval of a note in the scale, nil if it is not in it.
    private static func describe(_ midi: Int, root: Int, kind: ScaleKind) -> (String, String)? {
        let rootLetter = NoteSpelling.letterIndex(of: ScaleKind.rootName(root, majorFamily: kind.isMajorFamily))
        let step = (midi - root + 120) % 12
        guard let degree = kind.degrees.first(where: { $0.step == step }) else { return nil }
        return (NoteSpelling.spell(midi % 12, onLetter: rootLetter + degree.letter), degree.interval)
    }

    static func positions(root: Int, kind: ScaleKind) -> [ScalePosition] {
        let steps = kind.boxSteps
        let rootFret = (root - openStrings[0] % 12 + 12) % 12
        // The scale as MIDI notes, ascending, from the root on the low E string.
        let base = openStrings[0] + rootFret
        let ladder = (0..<(steps.count * 6)).map { i in
            base + 12 * (i / steps.count) + steps[i % steps.count]
        }

        return steps.indices.map { start in
            var notes: [ScaleNote] = []
            var next = start
            for string in 0..<6 {
                for _ in 0..<kind.notesPerString {
                    let midi = ladder[next]
                    next += 1
                    if let found = describe(midi, root: root, kind: kind) {
                        notes.append(ScaleNote(string: string, fret: midi - openStrings[string],
                                               name: found.0, interval: found.1))
                    }
                }
            }
            if kind == .blues { notes += blueNotes(within: notes, root: root) }
            // Past the top of the drawing, the same shape an octave down; below
            // the nut (a box starting on the open low E reaches back a fret on
            // the A string), an octave up.
            let low = notes.map(\.fret).min() ?? 0
            let high = notes.map(\.fret).max() ?? 0
            let shift = low < 0 ? 12 : (high > topFret && low >= 12 ? -12 : 0)
            if shift != 0 {
                notes = notes.map { ScaleNote(string: $0.string, fret: $0.fret + shift,
                                              name: $0.name, interval: $0.interval) }
            }
            return ScalePosition(number: start + 1, notes: notes)
        }
    }

    /// Every ♭5 on the strings inside a box's fret span.
    private static func blueNotes(within box: [ScaleNote], root: Int) -> [ScaleNote] {
        guard let low = box.map(\.fret).min(), let high = box.map(\.fret).max() else { return [] }
        var added: [ScaleNote] = []
        for string in 0..<6 {
            for fret in low...high where (openStrings[string] + fret - root + 120) % 12 == 6 {
                if let found = describe(openStrings[string] + fret, root: root, kind: .blues) {
                    added.append(ScaleNote(string: string, fret: fret, name: found.0, interval: found.1))
                }
            }
        }
        return added
    }

    /// Every note of the scale from the nut to `topFret`, for the whole-neck view.
    static func wholeNeck(root: Int, kind: ScaleKind) -> [ScaleNote] {
        (0..<6).flatMap { string in
            (0...topFret).compactMap { fret -> ScaleNote? in
                guard let found = describe(openStrings[string] + fret, root: root, kind: kind)
                else { return nil }
                return ScaleNote(string: string, fret: fret, name: found.0, interval: found.1)
            }
        }
    }
}

// MARK: - Screen

struct ScalesView: View {
    @State private var kind: ScaleKind = .minorPentatonic
    @State private var root = 9   // A
    @State private var showIntervals = false

    private var positions: [ScalePosition] { ScaleBuilder.positions(root: root, kind: kind) }
    private var rootName: String {
        KeyTheoryNames.pretty(ScaleKind.rootName(root, majorFamily: kind.isMajorFamily))
    }

    var body: some View {
        ZStack {
            TabBackgroundView()
            ScrollView {
                VStack(spacing: 16) {
                    kindPicker
                    keyPicker
                    Picker("Labels", selection: $showIntervals) {
                        Text("Notes").tag(false)
                        Text("Intervals").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)

                    card("\(rootName) \(kind.rawValue) · whole neck") {
                        ScaleFretboard(notes: ScaleBuilder.wholeNeck(root: root, kind: kind),
                                       frets: 0...ScaleBuilder.topFret, showIntervals: showIntervals)
                            .frame(height: 140)
                    }

                    ForEach(positions) { position in
                        card(title(position)) {
                            ScaleFretboard(notes: position.notes, frets: window(position),
                                           showIntervals: showIntervals)
                                .frame(height: 150)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("Scales")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var kindPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ScaleKind.allCases) { k in
                    chip(k.rawValue, on: k == kind) { kind = k }
                }
            }
        }
    }

    private var keyPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
            ForEach(0..<12, id: \.self) { pc in
                chip(KeyTheoryNames.pretty(ScaleKind.rootName(pc, majorFamily: kind.isMajorFamily)),
                     on: pc == root, fill: true) { root = pc }
            }
        }
    }

    private func chip(_ text: String, on: Bool, fill: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: fill ? .infinity : nil)
                .padding(.horizontal, fill ? 0 : 14)
                .padding(.vertical, 8)
                .background(on ? Color.accentColor : Color.primary.opacity(0.08), in: Capsule())
                .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    private func title(_ position: ScalePosition) -> String {
        let low = position.lowestFret, high = position.highestFret
        let place = low == 0 ? "open – \(high)" : "frets \(low)–\(high)"
        return "Position \(position.number) · \(place)"
    }

    /// The frets a position's drawing shows: its own span, at least five wide,
    /// from the nut when it starts low enough to need it.
    private func window(_ position: ScalePosition) -> ClosedRange<Int> {
        let low = position.lowestFret <= 1 ? 0 : position.lowestFret
        return low...max(position.highestFret, low + 4)
    }
}

/// The ♯/♭ display, shared with the circle of fifths.
enum KeyTheoryNames {
    /// "F#" → "F♯", "Bb" → "B♭". Only a lowercase b after the letter is a flat.
    static func pretty(_ name: String) -> String {
        guard let first = name.first else { return name }
        return String(first) + name.dropFirst()
            .replacingOccurrences(of: "#", with: "♯")
            .replacingOccurrences(of: "b", with: "♭")
    }
}

// MARK: - Fretboard

/// A stretch of the neck as tab reads it — high E on top — with the scale's
/// notes as dots, the root filled in the accent colour.
private struct ScaleFretboard: View {
    let notes: [ScaleNote]
    let frets: ClosedRange<Int>
    let showIntervals: Bool

    var body: some View {
        Canvas { context, size in
            let numbers: CGFloat = 16          // fret numbers underneath
            let height = size.height - numbers
            let rowGap = height / 6
            let columns = CGFloat(frets.count)
            let columnWidth = size.width / columns
            let y = { (string: Int) in rowGap * (CGFloat(5 - string) + 0.5) }
            let x = { (fret: Int) in columnWidth * (CGFloat(fret - frets.lowerBound) + 0.5) }
            let hasNut = frets.lowerBound == 0

            FretboardDrawing.drawInlays(in: context, frets: frets, x: x,
                                        centerY: height / 2, rowGap: rowGap, diameter: 6)

            // Fret wires sit on the right edge of each fret's column; the nut is
            // the right edge of the open-string column.
            for fret in frets {
                let fx = x(fret) + columnWidth / 2
                guard fx < size.width - 0.5 else { continue }
                var wire = Path()
                wire.move(to: CGPoint(x: fx, y: y(5)))
                wire.addLine(to: CGPoint(x: fx, y: y(0)))
                let isNut = hasNut && fret == 0
                context.stroke(wire, with: .color(.primary.opacity(isNut ? 0.75 : 0.25)),
                               lineWidth: isNut ? 3 : 1)
            }
            for string in 0..<6 {
                var line = Path()
                let startX = hasNut ? x(0) + columnWidth / 2 : 0
                line.move(to: CGPoint(x: startX, y: y(string)))
                line.addLine(to: CGPoint(x: size.width, y: y(string)))
                context.stroke(line, with: .color(.primary.opacity(0.35)), lineWidth: 1)
            }

            // Fret numbers.
            for fret in frets where fret > 0 && (fret == frets.lowerBound || [3, 5, 7, 9, 12, 15].contains(fret)) {
                context.draw(Text("\(fret)").font(.caption2).foregroundStyle(.secondary),
                             at: CGPoint(x: x(fret), y: size.height - numbers / 2))
            }

            // Notes.
            let dotSize = min(rowGap * 0.9, columnWidth * 0.8)
            for note in notes where frets.contains(note.fret) {
                let center = CGPoint(x: x(note.fret), y: y(note.string))
                let rect = CGRect(x: center.x - dotSize / 2, y: center.y - dotSize / 2,
                                  width: dotSize, height: dotSize)
                let blue = note.interval == "♭5"
                let fill: Color = note.isRoot ? .accentColor : blue ? .blue : Color(white: 0.85)
                context.fill(Path(ellipseIn: rect), with: .color(fill))
                let label = showIntervals ? note.interval : KeyTheoryNames.pretty(note.name)
                context.draw(Text(label)
                                .font(.system(size: dotSize * 0.45, weight: .bold, design: .rounded))
                                .foregroundStyle(note.isRoot || blue ? Color.white : Color.black),
                             at: center)
            }
        }
    }
}

#Preview {
    NavigationStack { ScalesView() }
        .preferredColorScheme(.dark)
}
