//
//  CircleOfFifthsView.swift
//  Mazut
//
//  The circle of fifths, reached from the Learning tab. Major keys round the
//  outside, each a fifth above the last; their relative minors inside. Picking
//  a key turns it to the top and lights the six chords that belong to it — the
//  three neighbours outside and the three inside — which is the thing the
//  circle is for. Below: the key signature, the scale, and the chords with
//  their numerals, each of which shows how it is played.
//

import SwiftUI

// MARK: - Theory

private enum KeyTheory {
    /// Clockwise from the top, a fifth apart. Position 6 is F♯ = G♭; the
    /// sharp spelling is used for the scale, both are shown on the wheel.
    static let majors = ["C", "G", "D", "A", "E", "B", "F#", "Db", "Ab", "Eb", "Bb", "F"]
    static let minors = ["A", "E", "B", "F#", "C#", "G#", "D#", "Bb", "F", "C", "G", "D"]
    static let majorAlternates = [6: "Gb"]
    static let minorAlternates = [6: "Eb"]

    static let majorSteps = [0, 2, 4, 5, 7, 9, 11]
    static let minorSteps = [0, 2, 3, 5, 7, 8, 10]

    /// (numeral, chord suffix, library type) per degree; nil type = diminished,
    /// which the chord library has no shapes for.
    static let majorChords: [(String, String, ChordQuality?)] = [
        ("I", "", .major), ("ii", "m", .minor), ("iii", "m", .minor), ("IV", "", .major),
        ("V", "", .major), ("vi", "m", .minor), ("vii°", "dim", nil),
    ]
    static let minorChords: [(String, String, ChordQuality?)] = [
        ("i", "m", .minor), ("ii°", "dim", nil), ("III", "", .major), ("iv", "m", .minor),
        ("v", "m", .minor), ("VI", "", .major), ("VII", "", .major),
    ]

    /// Sharps (positions 0…6) or flats (7…11) in the key signature, in the order
    /// they are written.
    static func signature(_ position: Int) -> [String] {
        position <= 6
            ? Array(["F#", "C#", "G#", "D#", "A#", "E#", "B#"].prefix(position))
            : Array(["Bb", "Eb", "Ab", "Db", "Gb", "Cb", "Fb"].prefix(12 - position))
    }

    static func signatureLabel(_ position: Int) -> String {
        switch position {
        case 0: "0"
        case 6: "6♯ / 6♭"
        case ..<6: "\(position)♯"
        default: "\(12 - position)♭"
        }
    }

    /// Seven notes, one per letter — so F♯ major has an E♯, not an F.
    static func scale(root: String, steps: [Int]) -> [String] {
        let rootLetter = NoteSpelling.letterIndex(of: root)
        let rootPC = NoteSpelling.pitchClass(of: root)
        return steps.enumerated().map { degree, step in
            NoteSpelling.spell((rootPC + step) % 12, onLetter: rootLetter + degree)
        }
    }

    /// "F#" → "F♯", "Bbm" → "B♭m".
    static func pretty(_ name: String) -> String { KeyTheoryNames.pretty(name) }
}

// MARK: - Screen

struct CircleOfFifthsView: View {
    @State private var position = 0
    @State private var isMinor = false
    /// Accumulated, not derived from `position`: turning from F to C is one step
    /// clockwise, not eleven back.
    @State private var rotation = 0.0
    @State private var shownChord: String?
    /// Which version of the shown chord — back to v1 whenever the chord changes.
    @State private var shownVersion = 0

    private var root: String { (isMinor ? KeyTheory.minors : KeyTheory.majors)[position] }
    private var scale: [String] {
        KeyTheory.scale(root: root, steps: isMinor ? KeyTheory.minorSteps : KeyTheory.majorSteps)
    }

    private struct DiatonicChord: Identifiable {
        let numeral: String
        let root: String
        let suffix: String
        let quality: ChordQuality?
        var name: String { root + suffix }
        var id: String { numeral }
    }

    private var chords: [DiatonicChord] {
        let degrees = isMinor ? KeyTheory.minorChords : KeyTheory.majorChords
        return zip(scale, degrees).map { note, degree in
            DiatonicChord(numeral: degree.0, root: note, suffix: degree.1, quality: degree.2)
        }
    }

    var body: some View {
        ZStack {
            TabBackgroundView()
            ScrollView {
                VStack(spacing: 20) {
                    FifthsWheel(position: position, isMinor: isMinor, rotation: rotation, select: select)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 380)
                        .padding(.top, 8)
                    keyCard
                    chordsCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Circle of Fifths")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var keyCard: some View {
        let signature = KeyTheory.signature(position)
        let relative = isMinor ? KeyTheory.majors[position] + " major" : KeyTheory.minors[position] + " minor"
        return VStack(spacing: 10) {
            Text("\(KeyTheory.pretty(root)) \(isMinor ? "minor" : "major")")
                .font(.title.bold())
            Text("Relative \(isMinor ? "major" : "minor"): \(KeyTheory.pretty(relative))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Divider()
            row("Key signature", signature.isEmpty
                ? "no sharps or flats"
                : signature.map(KeyTheory.pretty).joined(separator: " "))
            row("Scale", scale.map(KeyTheory.pretty).joined(separator: " "))
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private var chordsCard: some View {
        VStack(spacing: 14) {
            Text("Chords in this key")
                .font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 8) {
                ForEach(chords) { chord in
                    let on = chord.name == shownChord
                    Button {
                        withAnimation(.spring(duration: 0.35)) {
                            shownChord = on ? nil : chord.name
                            shownVersion = 0
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Text(chord.numeral)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(on ? Color.white.opacity(0.8) : Color.secondary)
                            Text(KeyTheory.pretty(chord.name))
                                .font(.headline)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(on ? Color.accentColor : Color.primary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(on ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let name = shownChord, let chord = chords.first(where: { $0.name == name }) {
                chordDiagram(chord)
            } else {
                Text("Tap a chord to see how it is played.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func chordDiagram(_ diatonic: DiatonicChord) -> some View {
        if let quality = diatonic.quality,
           let chord = ChordLibrary.chord(root: diatonic.root, quality, suffix: diatonic.suffix),
           !chord.shapes.isEmpty {
            let shape = chord.shapes[min(shownVersion, chord.shapes.count - 1)]
            VStack(spacing: 10) {
                if chord.shapes.count > 1 {
                    ChordVersionPicker(count: chord.shapes.count, selection: $shownVersion)
                }
                ChordDiagram(shape: shape, noteName: chord.spelled(midi:))
                    .frame(height: 240)
                    .frame(maxWidth: 260)
                Text(shape.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("\(KeyTheory.pretty(diatonic.name)) is diminished — no shape for it in the chord library yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func select(_ newPosition: Int, minor: Bool) {
        var step = (newPosition - position + 12) % 12
        if step > 6 { step -= 12 }
        withAnimation(.spring(duration: 0.5)) {
            rotation -= Double(step) * 30
            position = newPosition
            isMinor = minor
            shownChord = nil
            shownVersion = 0
        }
    }
}

// MARK: - Wheel

private struct FifthsWheel: View {
    let position: Int
    let isMinor: Bool
    /// Degrees; the wheel turns so the chosen key sits at the top.
    let rotation: Double
    let select: (Int, Bool) -> Void

    private static let outer: ClosedRange<CGFloat> = 0.68...1.0
    private static let inner: ClosedRange<CGFloat> = 0.40...0.68

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                ForEach(0..<12, id: \.self) { i in
                    sector(i, ring: Self.outer, minor: false)
                    sector(i, ring: Self.inner, minor: true)
                    label(i, minor: false, radius: radius, center: center)
                    label(i, minor: true, radius: radius, center: center)
                }
            }
            .rotationEffect(.degrees(rotation))
            .overlay {
                VStack(spacing: 2) {
                    Text(KeyTheory.signatureLabel(position))
                        .font(.title2.bold())
                    Text("key signature")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: radius * Self.inner.lowerBound * 1.8)
                .position(center)
            }
        }
    }

    /// Lit if it is one of the key's six chords: the chosen spot and its two
    /// neighbours, outside and inside. The tonic itself is brightest.
    private func fill(_ i: Int, minor: Bool) -> Color {
        if i == position && minor == isMinor { return .accentColor }
        let distance = min((i - position + 12) % 12, (position - i + 12) % 12)
        return distance <= 1 ? Color.accentColor.opacity(0.32) : Color.primary.opacity(0.07)
    }

    private func sector(_ i: Int, ring: ClosedRange<CGFloat>, minor: Bool) -> some View {
        WheelSector(index: i, inner: ring.lowerBound, outer: ring.upperBound)
            .fill(fill(i, minor: minor))
            .overlay(WheelSector(index: i, inner: ring.lowerBound, outer: ring.upperBound)
                .stroke(Color.black.opacity(0.35), lineWidth: 1))
            .onTapGesture { select(i, minor) }
    }

    private func label(_ i: Int, minor: Bool, radius: CGFloat, center: CGPoint) -> some View {
        let ring = minor ? Self.inner : Self.outer
        let mid = radius * (ring.lowerBound + ring.upperBound) / 2
        let angle = Angle.degrees(Double(i) * 30 - 90).radians
        let names = minor ? KeyTheory.minors : KeyTheory.majors
        let alternate = (minor ? KeyTheory.minorAlternates : KeyTheory.majorAlternates)[i]
        let suffix = minor ? "m" : ""
        let lit = i == position && minor == isMinor
        return VStack(spacing: 0) {
            Text(KeyTheory.pretty(names[i]) + suffix)
                .font(minor ? .subheadline.weight(.semibold) : .title3.bold())
            if let alternate {
                Text(KeyTheory.pretty(alternate) + suffix)
                    .font(.caption2.weight(.medium))
                    .opacity(0.75)
            }
        }
        .foregroundStyle(lit ? Color.white : Color.primary)
        // Counter-turned, so names stay upright as the wheel spins.
        .rotationEffect(.degrees(-rotation))
        .position(x: center.x + mid * cos(angle), y: center.y + mid * sin(angle))
        .allowsHitTesting(false)
    }
}

/// One twelfth of a ring, centred on its key's angle (index 0 at the top).
private struct WheelSector: Shape {
    let index: Int
    /// Radii as fractions of the wheel's radius.
    let inner: CGFloat
    let outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let start = Angle.degrees(Double(index) * 30 - 90 - 15)
        let end = Angle.degrees(Double(index) * 30 - 90 + 15)
        var path = Path()
        path.addArc(center: center, radius: radius * outer, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: radius * inner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

#Preview {
    NavigationStack { CircleOfFifthsView() }
        .preferredColorScheme(.dark)
}
