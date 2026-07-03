//
//  StemLiveActivity.swift
//  MazutWidget
//
//  Live Activity kartica na zaključanom ekranu: naslov pesme + 6 dugmića za
//  paljenje/gašenje kanala dok pesma svira. Dugme okida ToggleStemIntent koji
//  se izvršava u procesu aplikacije (živa je jer svira u pozadini).
//

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct StemLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StemActivityAttributes.self) { context in
            StemActivityView(state: context.state)
                .padding(14)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    StemActivityView(state: context.state)
                }
            } compactLeading: {
                Image(systemName: "waveform")
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "play.fill" : "pause.fill")
            } minimal: {
                Image(systemName: "waveform")
            }
        }
    }
}

/// Boje kanala — iste kao `StemKind.color` u aplikaciji.
private func bojaKanala(_ ch: StemChannel) -> Color {
    switch ch {
    case .vocals: return .pink
    case .drums:  return .orange
    case .bass:   return .purple
    case .guitar: return .red
    case .piano:  return .teal
    case .other:  return .blue
    }
}

struct StemActivityView: View {
    let state: StemActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: state.isPlaying ? "play.fill" : "pause.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(state.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer()
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                ForEach(StemChannel.allCases, id: \.rawValue) { ch in
                    let upaljen = ch.rawValue < state.audible.count && state.audible[ch.rawValue]
                    Button(intent: ToggleStemIntent(stemIndex: ch.rawValue)) {
                        VStack(spacing: 3) {
                            Image(systemName: ch.simbol)
                                .font(.system(size: 16))
                            Text(ch.naziv)
                                .font(.system(size: 8))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(upaljen ? Color.white : Color.secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(upaljen ? bojaKanala(ch).opacity(0.85)
                                              : Color.secondary.opacity(0.15))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
