//
//  OnboardingView.swift
//  Mazut
//
//  First-launch intro: a paged walkthrough of every tab and what it does.
//  Shown once (gated by `@AppStorage("hasSeenIntro")` in `MazutApp`).
//

import SwiftUI

/// One feature line on an intro page.
private struct IntroFeature: Identifiable {
    let id = UUID()
    let systemImage: String
    let title: String
    let detail: String
}

/// One intro page.
private struct IntroPage: Identifiable {
    let id = UUID()
    let systemImage: String
    let tint: Color
    let title: String
    let subtitle: String
    let features: [IntroFeature]
}

private let introPages: [IntroPage] = [
    IntroPage(
        systemImage: "waveform",
        tint: Color("mazut_red"),
        title: "Welcome to Mazut",
        subtitle: "Split any song into its instruments and practice along with exactly the parts you need.",
        features: [
            IntroFeature(systemImage: "wand.and.stars", title: "6 stems",
                         detail: "Vocals, drums, bass, guitar, piano and everything else — each on its own track."),
            IntroFeature(systemImage: "lock.iphone", title: "100% on your device",
                         detail: "Separation runs locally on your iPhone. Your music never leaves it."),
            IntroFeature(systemImage: "graduationcap", title: "Built for practice",
                         detail: "A metronome with timing feedback, music theory drills and your own lessons."),
        ]
    ),
    IntroPage(
        systemImage: "plus.circle.fill",
        tint: .blue,
        title: "Songs",
        subtitle: "Your library of separated songs.",
        features: [
            IntroFeature(systemImage: "wand.and.stars", title: "Separate a song",
                         detail: "Tap + and choose an audio file. It's split into 6 stems."),
            IntroFeature(systemImage: "internaldrive", title: "Separated only once",
                         detail: "Every song is saved, so next time it opens instantly — even if you import it again."),
            IntroFeature(systemImage: "text.badge.plus", title: "Add to playlist",
                         detail: "Swipe a song to the right to put it in a playlist."),
            IntroFeature(systemImage: "arrow.up.arrow.down", title: "Sort",
                         detail: "Order the library by date, title, artist or duration."),
        ]
    ),
    IntroPage(
        systemImage: "slider.vertical.3",
        tint: .orange,
        title: "Stem Mixer",
        subtitle: "Open a song to get a mixer with one channel per instrument.",
        features: [
            IntroFeature(systemImage: "speaker.wave.2", title: "Volume",
                         detail: "Turn each stem up or down — e.g. lower the guitar and play its part yourself."),
            IntroFeature(systemImage: "speaker.slash", title: "Mute",
                         detail: "Tap the speaker icon to silence a stem completely."),
            IntroFeature(systemImage: "headphones", title: "Solo (S)",
                         detail: "Hear only the soloed stems — great for learning a part by ear."),
            IntroFeature(systemImage: "repeat", title: "Repeat & shuffle",
                         detail: "Loop the current song, or jump to a random one."),
            IntroFeature(systemImage: "lock.iphone", title: "Lock screen",
                         detail: "Playback continues in the background, and you can toggle stems right from the lock screen."),
        ]
    ),
    IntroPage(
        systemImage: "music.note.list",
        tint: .purple,
        title: "Playlists",
        subtitle: "Group songs for a rehearsal, a gig or a practice session.",
        features: [
            IntroFeature(systemImage: "plus", title: "New playlist",
                         detail: "Create a playlist, then add songs from the Songs tab."),
            IntroFeature(systemImage: "play.circle", title: "Play in order",
                         detail: "Songs play one after another automatically."),
            IntroFeature(systemImage: "timer", title: "Pause between songs",
                         detail: "Set a break between songs so you have time to get ready."),
            IntroFeature(systemImage: "slider.horizontal.3", title: "Mixer carries over",
                         detail: "Your stem settings stay the same when the next song starts."),
        ]
    ),
    IntroPage(
        systemImage: "metronome",
        tint: .green,
        title: "Metronome",
        subtitle: "Keep time — and find out how well you actually do.",
        features: [
            IntroFeature(systemImage: "dial.medium", title: "Tempo & time signature",
                         detail: "Set the BPM (40–240) and how many beats are in a measure."),
            IntroFeature(systemImage: "music.note", title: "Click or drums",
                         detail: "Choose a plain click or a drum groove: rock, shuffle, funk, waltz, bossa…"),
            IntroFeature(systemImage: "mic", title: "Check my timing",
                         detail: "Put on headphones and play along. The microphone measures every note against the click."),
            IntroFeature(systemImage: "chart.bar", title: "Take summary",
                         detail: "See what percent of notes were on the beat and whether you tend to rush or drag."),
        ]
    ),
    IntroPage(
        systemImage: "graduationcap",
        tint: .teal,
        title: "Learning",
        subtitle: "Music theory drills and your own lesson library.",
        features: [
            IntroFeature(systemImage: "hand.raised.fingers.spread", title: "Chords",
                         detail: "Tap a chord to see how it's fingered on the fretboard."),
            IntroFeature(systemImage: "circle.circle", title: "Circle of Fifths",
                         detail: "Keys, their signatures and the chords that belong to each."),
            IntroFeature(systemImage: "chart.bar.xaxis", title: "Scales",
                         detail: "Every position of a scale in any key, as notes or intervals."),
            IntroFeature(systemImage: "guitars", title: "Find the Note",
                         detail: "The app names a note and a string — play it, and the microphone checks it."),
            IntroFeature(systemImage: "folder", title: "Your lessons",
                         detail: "Make folders of videos, photos, documents and YouTube links with +."),
        ]
    ),
]

struct OnboardingView: View {
    /// Called when the user skips or finishes the intro.
    var onFinish: () -> Void

    @State private var selection = 0

    private var isLastPage: Bool { selection == introPages.count - 1 }

    var body: some View {
        ZStack {
            TabBackgroundView()

            VStack(spacing: 0) {
                TabView(selection: $selection) {
                    ForEach(Array(introPages.enumerated()), id: \.element.id) { index, page in
                        IntroPageView(page: page)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                PageDots(count: introPages.count, selection: $selection)
                    .padding(.top, 12)

                Button {
                    onFinish()
                } label: {
                    Text(isLastPage ? "Get started" : "Skip")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentTransition(.opacity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isLastPage ? Color("mazut_red") : Color.white.opacity(0.15))
                .padding(.horizontal, 32)
                .padding(.top, 20)
                .padding(.bottom, 24)
                .animation(.easeInOut(duration: 0.2), value: isLastPage)
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// A single page: big icon, title, subtitle and a list of features.
private struct IntroPageView: View {
    let page: IntroPage

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(page.tint.opacity(0.25))
                        .frame(width: 104, height: 104)
                    Image(systemName: page.systemImage)
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(page.tint)
                }
                .padding(.top, 40)

                VStack(spacing: 8) {
                    Text(page.title)
                        .font(.largeTitle.bold())
                    Text(page.subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 18) {
                    ForEach(page.features) { feature in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: feature.systemImage)
                                .font(.title3)
                                .foregroundStyle(page.tint)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.title)
                                    .font(.headline)
                                Text(feature.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 520, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }
}

/// Dot indicator for the page count; tapping a dot jumps to that page.
private struct PageDots: View {
    let count: Int
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == selection ? Color.white : Color.white.opacity(0.3))
                    .frame(width: index == selection ? 22 : 8, height: 8)
                    .onTapGesture { withAnimation { selection = index } }
            }
        }
        .animation(.spring(duration: 0.3), value: selection)
        .accessibilityElement()
        .accessibilityLabel("Page \(selection + 1) of \(count)")
    }
}

#Preview {
    OnboardingView(onFinish: {})
}
