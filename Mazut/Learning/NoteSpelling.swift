//
//  NoteSpelling.swift
//  Mazut
//
//  How notes are named in a key or a chord: one letter per scale degree, with
//  as many sharps or flats as that takes. Shared by the chord library and the
//  circle of fifths, so a chord's notes and its key's scale are always spelled
//  alike — the seventh of C is B♭, F♯ major has an E♯.
//

enum NoteSpelling {
    static let letters = ["C", "D", "E", "F", "G", "A", "B"]
    private static let naturals = [0, 2, 4, 5, 7, 9, 11]

    /// Index into `letters` of a name's letter: "F#" → 3.
    static func letterIndex(of name: String) -> Int {
        letters.firstIndex(of: String(name.prefix(1))) ?? 0
    }

    /// "F#" → 6, "Bb" → 10: the letter, then each sharp or flat after it.
    static func pitchClass(of name: String) -> Int {
        let shift = name.dropFirst().reduce(0) { $0 + ($1 == "#" ? 1 : $1 == "b" ? -1 : 0) }
        return (naturals[letterIndex(of: name)] + shift + 12) % 12
    }

    /// `pitchClass` written on the given letter: (10, B) → "Bb", (5, E) → "E#".
    static func spell(_ pitchClass: Int, onLetter letter: Int) -> String {
        var shift = (pitchClass - naturals[letter % 7] + 24) % 12
        if shift > 6 { shift -= 12 }
        let accidental = shift > 0 ? String(repeating: "#", count: shift)
                                   : String(repeating: "b", count: -shift)
        return letters[letter % 7] + accidental
    }
}
