//
//  ChordsView.swift
//  Mazut
//
//  Chord reference, reached from the Learning tab: pick a chord by name and the
//  diagram below shows how to play it — fingers, barre, muted and open strings,
//  and the note each string sounds. The dots are positioned views rather than a
//  drawing, so switching chords moves the fingers to their new places.
//

import SwiftUI

// MARK: - Chord data

enum ChordQuality: String, CaseIterable, Identifiable {
    case major = "Major"
    case minor = "Minor"
    case seventh = "7"
    case minorSeventh = "m7"
    case majorSeventh = "maj7"
    case suspended = "sus"

    var id: String { rawValue }

    /// (semitones above the root, scale degree 0-based) for each chord tone.
    func intervals(suffix: String) -> [(semitones: Int, degree: Int)] {
        switch self {
        case .major: [(0, 0), (4, 2), (7, 4)]
        case .minor: [(0, 0), (3, 2), (7, 4)]
        case .seventh: [(0, 0), (4, 2), (7, 4), (10, 6)]
        case .minorSeventh: [(0, 0), (3, 2), (7, 4), (10, 6)]
        case .majorSeventh: [(0, 0), (4, 2), (7, 4), (11, 6)]
        case .suspended: suffix == "sus2" ? [(0, 0), (2, 1), (7, 4)] : [(0, 0), (5, 3), (7, 4)]
        }
    }
}

/// The five open chord shapes every chord can be played in, moved up the neck.
/// Named after the open chord they come from; in order along the neck they
/// repeat C → A → G → E → D, which is what lets one chord be found anywhere.
enum CagedShape: String, Hashable {
    case c = "C", a = "A", g = "G", e = "E", d = "D"

    /// Pitch class of the open chord the shape comes from: moved up `n` frets,
    /// the shape plays the chord whose root is this plus `n`.
    var openRoot: Int {
        switch self {
        case .c: 0
        case .a: 9
        case .g: 7
        case .e: 4
        case .d: 2
        }
    }
}

/// One way of fretting a chord, in standard tuning.
struct ChordShape: Hashable {
    /// Low E → high E. −1 = muted, 0 = open, otherwise the fret (absolute).
    let frets: [Int]
    /// Low E → high E. 0 = no finger; 1 = index … 4 = little finger.
    let fingers: [Int]
    /// Which CAGED shape this is, nil for the odd open voicing outside the system.
    let family: CagedShape?

    /// Where on the neck it sits: 0 for anything using open strings, otherwise
    /// the lowest fret pressed. Versions are listed in this order.
    var position: Int {
        frets.contains(0) ? 0 : frets.filter { $0 > 0 }.min() ?? 0
    }

    /// "A shape · 3rd fret", for under the version picker.
    var caption: String {
        let place = position == 0 ? "open position" : "\(NoteTrainer.ordinal(position)) fret"
        guard let family else { return place.prefix(1).uppercased() + place.dropFirst() }
        return "\(family.rawValue) shape · \(place)"
    }

    struct Barre: Hashable {
        let fret: Int
        let finger: Int
        /// String indices, low E = 0.
        let from: Int
        let to: Int
    }

    /// One finger pressing several strings on one fret.
    var barre: Barre? {
        for finger in 1...4 {
            let strings = fingers.indices.filter { fingers[$0] == finger }
            guard strings.count >= 2, let first = strings.first,
                  strings.allSatisfy({ frets[$0] == frets[first] }) else { continue }
            return Barre(fret: frets[first], finger: finger, from: first, to: strings.last ?? first)
        }
        return nil
    }

    /// The fret the diagram starts at: the nut when the shape fits in the first
    /// five frets, otherwise the lowest fretted note, labelled "5fr" and so on.
    var baseFret: Int {
        let fretted = frets.filter { $0 > 0 }
        guard let low = fretted.min(), let high = fretted.max(), high > ChordDiagram.fretsShown else { return 1 }
        return low
    }

    /// MIDI note each string sounds, nil where muted.
    var midiNotes: [Int?] {
        zip(GuitarTuning.standard.strings, frets).map { open, fret in fret < 0 ? nil : open + fret }
    }

    init(frets: [Int], fingers: [Int], family: CagedShape?) {
        self.frets = frets
        self.fingers = fingers
        self.family = family
    }

    /// Shorthand: "x32010" with fingers "032010".
    init(_ frets: String, _ fingers: String, _ family: CagedShape? = nil) {
        self.init(frets: frets.map { $0 == "x" ? -1 : Int(String($0)) ?? 0 },
                  fingers: fingers.map { Int(String($0)) ?? 0 },
                  family: family)
    }
}

struct Chord: Identifiable, Hashable {
    let root: String
    let rootPitchClass: Int
    let quality: ChordQuality
    let suffix: String
    let shapes: [ChordShape]

    var name: String { root + suffix }
    var id: String { name }

    /// The chord's notes from theory, root first: "C · E · G · Bb". Not read off
    /// the shape — the usual C7 leaves out its G — and spelled by letter, so a
    /// seventh of C is Bb, not A#.
    var tones: [(pitchClass: Int, name: String)] {
        let rootLetter = NoteSpelling.letterIndex(of: root)
        return quality.intervals(suffix: suffix).map { semitones, degree in
            let pc = (rootPitchClass + semitones) % 12
            return (pc, NoteSpelling.spell(pc, onLetter: rootLetter + degree))
        }
    }

    /// A sounding note's name as this chord spells it.
    func spelled(midi: Int) -> String {
        tones.first { $0.pitchClass == midi % 12 }?.name ?? Tuner.noteName(forMidi: midi)
    }
}

enum ChordLibrary {

    /// A CAGED shape as offsets from where its nut would be; nil = muted.
    private struct Movable {
        let family: CagedShape
        let offsets: [Int?]
        let fingers: [Int]
    }

    private static func movable(_ family: CagedShape, _ offsets: [Int?], _ fingers: String) -> Movable {
        Movable(family: family, offsets: offsets, fingers: fingers.map { Int(String($0)) ?? 0 })
    }

    /// The movable form of each shape, per chord type. Not every type has all
    /// five — some (a C-shape m7, a G-shape sus2) would take more stretch than a
    /// hand has, and nobody plays them.
    private static func movables(_ quality: ChordQuality, _ suffix: String) -> [Movable] {
        switch (quality, suffix) {
        case (.major, _): [
            movable(.c, [nil, 3, 2, 0, 1, 0], "043121"),
            movable(.a, [nil, 0, 2, 2, 2, 0], "013331"),
            movable(.g, [3, 2, 0, 0, 0, 3], "321114"),
            movable(.e, [0, 2, 2, 1, 0, 0], "134211"),
            movable(.d, [nil, nil, 0, 2, 3, 2], "001243"),
        ]
        case (.minor, _): [
            movable(.c, [nil, 3, 1, 0, 1, nil], "042130"),
            movable(.a, [nil, 0, 2, 2, 1, 0], "013421"),
            movable(.g, [3, 1, 0, 0, 3, 3], "321144"),
            movable(.e, [0, 2, 2, 0, 0, 0], "134111"),
            movable(.d, [nil, nil, 0, 2, 3, 1], "001342"),
        ]
        case (.seventh, _): [
            movable(.c, [nil, 3, 2, 3, 1, nil], "032410"),
            movable(.a, [nil, 0, 2, 0, 2, 0], "013141"),
            movable(.g, [3, 2, 0, 0, 0, 1], "431112"),
            movable(.e, [0, 2, 0, 1, 0, 0], "131211"),
            movable(.d, [nil, nil, 0, 2, 1, 2], "001324"),
        ]
        case (.minorSeventh, _): [
            movable(.a, [nil, 0, 2, 0, 1, 0], "013121"),
            movable(.e, [0, 2, 0, 0, 0, 0], "131111"),
            movable(.d, [nil, nil, 0, 2, 1, 1], "001322"),
        ]
        case (.majorSeventh, _): [
            movable(.c, [nil, 3, 2, 0, 0, 0], "043111"),
            movable(.a, [nil, 0, 2, 1, 2, 0], "013241"),
            movable(.g, [3, 2, 0, 0, 0, 2], "431112"),
            movable(.e, [0, nil, 1, 1, 0, nil], "103420"),
            movable(.d, [nil, nil, 0, 2, 2, 2], "001333"),
        ]
        case (.suspended, "sus2"): [
            movable(.a, [nil, 0, 2, 2, 0, 0], "013411"),
            movable(.d, [nil, nil, 0, 2, 3, 0], "001341"),
        ]
        case (.suspended, _): [
            movable(.a, [nil, 0, 2, 2, 3, 0], "012341"),
            movable(.e, [0, 2, 2, 2, 0, 0], "123411"),
            movable(.d, [nil, nil, 0, 2, 3, 3], "001234"),
        ]
        }
    }

    /// Every version of a chord: the open voicings written out by hand, plus each
    /// CAGED shape moved to where it plays this root. A shape that lands on fret
    /// 0 *is* an open chord, which is fingered differently from its movable form
    /// (no barre to hold), so there the hand-written one stands in for it.
    private static func chord(_ root: String, _ quality: ChordQuality, _ suffix: String,
                              _ open: ChordShape...) -> Chord {
        let rootPC = NoteSpelling.pitchClass(of: root)
        var shapes = open
        for shape in movables(quality, suffix) {
            let nut = (rootPC - shape.family.openRoot + 12) % 12
            guard nut > 0 else { continue }
            let frets = shape.offsets.map { $0.map { nut + $0 } ?? -1 }
            shapes.append(ChordShape(frets: frets, fingers: shape.fingers, family: shape.family))
        }
        var seen = Set<[Int]>()
        let versions = shapes.filter { seen.insert($0.frets).inserted }
            .enumerated()
            .sorted { ($0.element.position, $0.offset) < ($1.element.position, $1.offset) }
            .map(\.element)
        return Chord(root: root, rootPitchClass: rootPC, quality: quality, suffix: suffix, shapes: versions)
    }

    /// Hand-written: open-position voicings only. Everything barred is generated.
    static let all: [Chord] = [
        chord("C", .major, "", .init("x32010", "032010", .c)),
        chord("D", .major, "", .init("xx0232", "000132", .d)),
        chord("E", .major, "", .init("022100", "023100", .e)),
        chord("F", .major, "", .init("xx3211", "003211")),
        chord("G", .major, "", .init("320003", "210003", .g)),
        chord("A", .major, "", .init("x02220", "001230", .a)),
        chord("B", .major, ""),

        chord("C", .minor, "m"),
        chord("D", .minor, "m", .init("xx0231", "000231", .d)),
        chord("E", .minor, "m", .init("022000", "023000", .e)),
        chord("F", .minor, "m"),
        chord("G", .minor, "m"),
        chord("A", .minor, "m", .init("x02210", "002310", .a)),
        chord("B", .minor, "m"),

        chord("C", .seventh, "7", .init("x32310", "032410", .c)),
        chord("D", .seventh, "7", .init("xx0212", "000213", .d)),
        chord("E", .seventh, "7", .init("020100", "020100", .e)),
        chord("F", .seventh, "7"),
        chord("G", .seventh, "7", .init("320001", "320001", .g)),
        chord("A", .seventh, "7", .init("x02020", "002030", .a)),
        chord("B", .seventh, "7", .init("x21202", "021304")),

        chord("C", .minorSeventh, "m7"),
        chord("D", .minorSeventh, "m7", .init("xx0211", "000211", .d)),
        chord("E", .minorSeventh, "m7", .init("020000", "020000", .e)),
        chord("F", .minorSeventh, "m7"),
        chord("G", .minorSeventh, "m7"),
        chord("A", .minorSeventh, "m7", .init("x02010", "002010", .a)),
        chord("B", .minorSeventh, "m7"),

        chord("C", .majorSeventh, "maj7", .init("x32000", "032000", .c)),
        chord("D", .majorSeventh, "maj7", .init("xx0222", "000111", .d)),
        chord("E", .majorSeventh, "maj7", .init("021100", "031200", .e)),
        chord("F", .majorSeventh, "maj7", .init("xx3210", "003210")),
        chord("G", .majorSeventh, "maj7", .init("320002", "320001", .g)),
        chord("A", .majorSeventh, "maj7", .init("x02120", "002130", .a)),
        chord("B", .majorSeventh, "maj7"),

        chord("C", .suspended, "sus4", .init("x33011", "034011")),
        chord("D", .suspended, "sus2", .init("xx0230", "000130", .d)),
        chord("D", .suspended, "sus4", .init("xx0233", "000134", .d)),
        chord("E", .suspended, "sus4", .init("022200", "023400", .e)),
        chord("A", .suspended, "sus2", .init("x02200", "001200", .a)),
        chord("A", .suspended, "sus4", .init("x02230", "001230", .a)),
    ]

    /// Any chord by root and type — from the library when it is there, with its
    /// open voicings, otherwise built from the movable shapes alone. So a key
    /// like E♭ can still show how its chords are played.
    static func chord(root: String, _ quality: ChordQuality, suffix: String) -> Chord? {
        if let known = all.first(where: { $0.root == root && $0.quality == quality && $0.suffix == suffix }) {
            return known
        }
        let made = chord(root, quality, suffix)
        return made.shapes.isEmpty ? nil : made
    }

    static func chords(_ quality: ChordQuality) -> [Chord] {
        all.filter { $0.quality == quality }
    }
}

// MARK: - Screen

struct ChordsView: View {
    @State private var quality: ChordQuality = .major
    @State private var selected: Chord = ChordLibrary.all[0]
    @State private var shapeIndex = 0

    private var shape: ChordShape {
        selected.shapes[min(shapeIndex, selected.shapes.count - 1)]
    }

    var body: some View {
        ZStack {
            TabBackgroundView()
            ScrollView {
                VStack(spacing: 18) {
                    qualityPicker
                    chordGrid
                    diagramCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("Chords")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var qualityPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ChordQuality.allCases) { q in
                    Button {
                        switchQuality(to: q)
                    } label: {
                        Text(q.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(q == quality ? Color.accentColor : Color.primary.opacity(0.08),
                                        in: Capsule())
                            .foregroundStyle(q == quality ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var chordGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
            ForEach(ChordLibrary.chords(quality)) { chord in
                Button {
                    select(chord)
                } label: {
                    Text(chord.name)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(chord == selected ? Color.accentColor : Color.primary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(chord == selected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var diagramCard: some View {
        VStack(spacing: 14) {
            Text(selected.name)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .contentTransition(.interpolate)

            if selected.shapes.count > 1 {
                ChordVersionPicker(count: selected.shapes.count, selection: $shapeIndex)
            }
            Text(shape.caption)
                .font(.caption)
                .foregroundStyle(.secondary)

            ChordDiagram(shape: shape, noteName: selected.spelled(midi:))
                .frame(height: 280)
                .frame(maxWidth: 300)

            Text(selected.tones.map(\.name).joined(separator: " · "))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func select(_ chord: Chord) {
        withAnimation(.spring(duration: 0.35)) {
            selected = chord
            shapeIndex = 0
        }
    }

    /// Keeps the root when it can: Em → 7 lands on E7, so the change of one
    /// finger between related chords is what moves on the diagram.
    private func switchQuality(to newQuality: ChordQuality) {
        let chords = ChordLibrary.chords(newQuality)
        quality = newQuality
        guard let next = chords.first(where: { $0.root == selected.root }) ?? chords.first else { return }
        select(next)
    }
}

// MARK: - Version picker

/// v1, v2, … for a chord's versions, in order up the neck. Shared by the chord
/// reference and the circle of fifths, so both pick versions the same way.
struct ChordVersionPicker: View {
    let count: Int
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                let on = i == selection
                Button {
                    withAnimation(.spring(duration: 0.35)) { selection = i }
                } label: {
                    Text("v\(i + 1)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .frame(minWidth: 40)
                        .padding(.vertical, 6)
                        .background(on ? Color.accentColor : Color.primary.opacity(0.08),
                                    in: Capsule())
                        .foregroundStyle(on ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Diagram

/// A chord box: strings upright with low E on the left, the nut on top.
struct ChordDiagram: View {
    let shape: ChordShape
    /// How to name a sounding note — the chord's own spelling.
    var noteName: (Int) -> String = { Tuner.noteName(forMidi: $0) }
    static let fretsShown = 5

    var body: some View {
        GeometryReader { geo in
            let top: CGFloat = 30        // room for × and ○
            let bottom: CGFloat = 26     // room for the note names
            let side: CGFloat = 34       // room for the "5fr" label
            let width = geo.size.width - side * 2
            let height = geo.size.height - top - bottom
            let stringGap = width / 5
            let fretGap = height / CGFloat(Self.fretsShown)
            let dot = min(stringGap, fretGap) * 0.7
            let base = shape.baseFret

            let x = { (string: Int) in side + stringGap * CGFloat(string) }
            let lineY = { (row: Int) in top + fretGap * CGFloat(row) }
            let fretY = { (fret: Int) in top + fretGap * (CGFloat(fret - base) + 0.5) }

            ZStack {
                Path { path in
                    for string in 0..<6 {
                        path.move(to: CGPoint(x: x(string), y: lineY(0)))
                        path.addLine(to: CGPoint(x: x(string), y: lineY(Self.fretsShown)))
                    }
                    for row in 0...Self.fretsShown {
                        path.move(to: CGPoint(x: x(0), y: lineY(row)))
                        path.addLine(to: CGPoint(x: x(5), y: lineY(row)))
                    }
                }
                .stroke(Color.primary.opacity(0.45), lineWidth: 1.5)

                if base == 1 {
                    Capsule()
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: width + 4, height: 6)
                        .position(x: side + width / 2, y: lineY(0))
                } else {
                    Text("\(base)fr")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .position(x: side / 2 - 2, y: fretY(base))
                }

                if let barre = shape.barre {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: x(barre.to) - x(barre.from) + dot, height: dot)
                        .overlay(fingerLabel(barre.finger, size: dot))
                        .position(x: (x(barre.from) + x(barre.to)) / 2, y: fretY(barre.fret))
                }

                ForEach(0..<6, id: \.self) { string in
                    let fret = shape.frets[string]
                    let finger = shape.fingers[string]

                    Text(fret < 0 ? "×" : fret == 0 ? "○" : "")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .position(x: x(string), y: top / 2 - 2)

                    if fret > 0, !isUnderBarre(string) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: dot, height: dot)
                            .overlay(fingerLabel(finger, size: dot))
                            .position(x: x(string), y: fretY(fret))
                            .transition(.scale.combined(with: .opacity))
                    }

                    Text(shape.midiNotes[string].map(noteName) ?? "")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .position(x: x(string), y: geo.size.height - bottom / 2)
                }
            }
        }
    }

    /// The barre is drawn as one bar; its strings get no dot of their own.
    private func isUnderBarre(_ string: Int) -> Bool {
        guard let barre = shape.barre else { return false }
        return shape.fingers[string] == barre.finger && shape.frets[string] == barre.fret
    }

    private func fingerLabel(_ finger: Int, size: CGFloat) -> some View {
        Text(finger > 0 ? "\(finger)" : "")
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
    }
}

#Preview {
    NavigationStack { ChordsView() }
        .preferredColorScheme(.dark)
}
