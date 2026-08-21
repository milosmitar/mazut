//
//  StemLiveActivity.swift
//  MazutWidget
//
//  Live Activity card on the lock screen: song title + 6 buttons to toggle
//  channels on/off while a song plays. The button triggers ToggleStemIntent,
//  which executes in the app's process (it's alive because it plays in the background).
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

/// Channel colors — same as `StemKind.color` in the app.
private func channelColor(_ ch: StemChannel) -> Color {
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
                    let isOn = ch.rawValue < state.audible.count && state.audible[ch.rawValue]
                    Button(intent: ToggleStemIntent(stemIndex: ch.rawValue)) {
                        VStack(spacing: 3) {
                            Image(systemName: ch.systemImage)
                                .font(.system(size: 16))
                            Text(ch.displayName)
                                .font(.system(size: 8))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(isOn ? Color.white : Color.secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isOn ? channelColor(ch).opacity(0.85)
                                              : Color.secondary.opacity(0.15))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
