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
