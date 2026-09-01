//
//  TimingSummarySheet.swift
//  Mazut
//
//  The timing tape chart, and the take summary shown when a timing check ends.
//
//  Both live in one file because the summary is mostly the same picture as the
//  live readout, held still: the same tape, plus the numbers that only make
//  sense once the take is over (score over every note, not the rolling window).
//

import Charts
import SwiftUI

// MARK: - Tape chart

/// One point per played note, left to right; height is how far it sat from the
/// beat. Above the zero line the note was late, below it early, and the shaded
/// band is the tolerance window.
///
/// Colour carries only in/out of tolerance — the direction is read off the
/// labelled axis, so it never depends on telling green from orange.
struct TimingTapeChart: View {
    let hits: [TimingCoach.Hit]
    /// Notes visible before the tape starts scrolling.
    var window = 24

    var body: some View {
        let bound = yBound
        let last = hits.last?.index ?? 0
        let firstX = Double(max(0, last - window + 1))
        let lastX = Double(max(window - 1, last))

        Chart {
            RectangleMark(
                yStart: .value("Tolerance low", -TimingCoach.toleranceMs),
                yEnd: .value("Tolerance high", TimingCoach.toleranceMs)
            )
            .foregroundStyle(Color.green.opacity(0.12))

            RuleMark(y: .value("On the beat", 0))
                .lineStyle(StrokeStyle(lineWidth: 1))
                // `Color.primary`, not the bare `.primary` shape style: inside a
                // Chart the latter resolves to the default *series* colour, so
                // the ink lines come out blue.
                .foregroundStyle(Color.primary.opacity(0.35))

            ForEach(hits) { hit in
                LineMark(
                    x: .value("Note", Double(hit.index)),
                    y: .value("Deviation", hit.deviationMs)
                )
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(Color.primary.opacity(0.55))
                // The smoothest of the options — monotone flattens the curve at
                // each point and cardinal turns the peaks into near-corners. It
                // can overshoot slightly between notes, which is fine here: the
                // line is the trend, the points on top of it are the measurements.
                .interpolationMethod(.catmullRom)
            }

            ForEach(hits) { hit in
                PointMark(
                    x: .value("Note", Double(hit.index)),
                    y: .value("Deviation", hit.deviationMs)
                )
                .symbolSize(56)
                .foregroundStyle(hit.isOnTime ? Color.green : Color.orange)
            }
        }
        .chartLegend(.hidden)
        // Half a step of padding on each side, or the newest note is drawn
        // half-clipped by the plot edge.
        .chartXScale(domain: (firstX - 0.5)...(lastX + 0.5))
        .chartYScale(domain: -bound...bound)
        .chartXAxis(.hidden)
        .chartYAxis {
            // Three labels only — the two edges name the direction so up/down is
            // never a guess, and the middle marks the beat itself.
            AxisMarks(position: .leading, values: [-bound, 0, bound]) { value in
                AxisValueLabel {
                    Text(Self.axisLabel(value.as(Double.self) ?? 0))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .chartPlotStyle { plot in
            plot.background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Symmetric range, rounded up to a readable step and never tighter than
    /// ±60 ms, so small errors don't get magnified into alarming swings.
    private var yBound: Double {
        let peak = hits.map { abs($0.deviationMs) }.max() ?? 0
        return max(60, (peak / 20).rounded(.up) * 20)
    }

    static func axisLabel(_ value: Double) -> String {
        if value == 0 { return "beat" }
        return value > 0 ? "+\(Int(value)) late" : "−\(Int(abs(value))) early"
    }
}

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
                    TimingTapeChart(hits: summary.tape)
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
