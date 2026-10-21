//
//  TimingTapeChart.swift
//  Mazut
//
//  One point per played note: how far it landed from the beat. Used by the live
//  readout on the Metronome tab and by the take summary — the summary is the
//  same picture held still, over the whole take instead of a scrolling window.
//

import Charts
import SwiftUI

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

// MARK: - Previews

// The chart takes plain values and touches no audio, so unlike `ContentView` it
// previews in the canvas. A take that starts ragged, drifts late, then settles.
#Preview("Tape — a whole take") {
    TimingTapeChart(hits: [-48, 12, -31, 5, 18, -9, 22, 41, 35, 52, 44, 28, 16, 31, 9, -14, 20, 33]
        .enumerated()
        .map { TimingCoach.Hit(index: $0.offset, deviationMs: $0.element) })
        .frame(height: 150)
        .padding()
}

#Preview("Tape — first few notes") {
    // Fewer notes than the window: the x domain still has to hold its width, or
    // the first points sit on the plot edge.
    TimingTapeChart(hits: [8, -14, 3, 21]
        .enumerated()
        .map { TimingCoach.Hit(index: $0.offset, deviationMs: $0.element) })
        .frame(height: 150)
        .padding()
}
