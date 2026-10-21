//
//  TimingSummarySheet.swift
//  Mazut
//
//  Shown when a timing check ends: the tape held still, plus the numbers that
//  only make sense once the take is over — the score counts every note of the
//  take, not the live rolling window.
//

import SwiftUI

// MARK: - Summary sheet

/// Shown when a timing check ends: how the whole take went.
struct TimingSummarySheet: View {
    let summary: TimingCoach.Summary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    score
                    // The live chart scrolls, keeping the newest `window` notes
                    // in the x domain; here the tape is static, so the window
                    // has to be the whole tape or the oldest notes fall outside
                    // the domain and are silently not drawn.
                    TimingTapeChart(hits: summary.tape, window: max(1, summary.tape.count))
                        .frame(height: 150)
                    stats
                }
                .padding()
            }
            .navigationTitle("How that take went")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Hero number: the one figure worth remembering from the take.
    private var score: some View {
        VStack(spacing: 4) {
            Text("\(Int((summary.accuracy * 100).rounded()))%")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(summary.accuracy >= 0.75 ? Color.green : Color.orange)
            Text("\(summary.onTime) of \(summary.notes) notes within ±\(Int(TimingCoach.toleranceMs)) ms")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(verdict)
                .font(.headline)
        }
    }

    private var stats: some View {
        VStack(spacing: 0) {
            statRow("Tendency", tendency,
                    note: "Where the notes sat on average.")
            Divider()
            statRow("Consistency", "±\(Int(summary.spreadMs.rounded())) ms",
                    note: "Spread around that average — the smaller, the steadier.")
            Divider()
            statRow("Range", "\(Self.signed(summary.earliestMs)) … \(Self.signed(summary.latestMs)) ms",
                    note: "Earliest and latest note of the take.")
            if summary.overSpeaker {
                Divider()
                // The take passed a sound check, so the numbers are real — but
                // headphones are the cleaner setup and the sheet shouldn't let
                // the figure above stand as if the two were equivalent.
                statRow("Measured over", "speaker",
                        note: "Headphones give the detector a cleaner signal to work from.")
            }
        }
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func statRow(_ title: String, _ value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(value).font(.subheadline.monospacedDigit().weight(.semibold))
            }
            Text(note)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Signed milliseconds with a typographic minus, so the two ends of the
    /// range read as a pair rather than as a subtraction.
    private static func signed(_ ms: Double) -> String {
        let value = Int(ms.rounded())
        return value < 0 ? "−\(abs(value))" : "+\(value)"
    }

    private var verdict: String {
        switch summary.accuracy {
        case 0.9...:   return "Locked in."
        case 0.75...:  return "Solid."
        case 0.5...:   return "Getting there."
        default:       return "Worth another take."
        }
    }

    /// The systematic part, phrased the way a teacher would say it.
    private var tendency: String {
        let ms = summary.averageMs
        guard abs(ms) > 8 else { return "steady" }
        return ms < 0 ? "rushing \(Int(-ms.rounded())) ms" : "dragging \(Int(ms.rounded())) ms"
    }
}

// MARK: - Previews

private extension TimingCoach.Summary {
    /// A take built from deviations alone, so a preview reads like real playing
    /// rather than like numbers picked to fill the fields.
    static func preview(_ ms: [Double], overSpeaker: Bool = false) -> TimingCoach.Summary {
        let mean = ms.reduce(0, +) / Double(ms.count)
        let variance = ms.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(ms.count)
        return TimingCoach.Summary(
            notes: ms.count,
            onTime: ms.filter { abs($0) <= TimingCoach.toleranceMs }.count,
            averageMs: mean,
            spreadMs: variance.squareRoot(),
            earliestMs: ms.min() ?? 0,
            latestMs: ms.max() ?? 0,
            tape: ms.enumerated().map { TimingCoach.Hit(index: $0.offset, deviationMs: $0.element) },
            overSpeaker: overSpeaker)
    }
}

#Preview("Getting there") {
    TimingSummarySheet(summary: .preview(
        [-48, 12, -31, 5, 18, -9, 22, 41, 35, 52, 44, 28, 16, 31, 9, -14, 20, 33]))
}

#Preview("Locked in") {
    TimingSummarySheet(summary: .preview([3, -6, 1, 9, -4, 12, 2, -8, 5, 7, -2, 11]))
}

// Dragging hard but evenly: a large average with a small spread is a different
// problem from a small average with a large one, and the sheet has to show that.
#Preview("Dragging, but steady") {
    TimingSummarySheet(summary: .preview(
        [38, 44, 41, 36, 47, 39, 43, 40, 45, 37, 42, 46], overSpeaker: true))
}
