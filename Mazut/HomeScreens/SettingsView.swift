//
//  SettingsView.swift
//  Mazut
//
//  App menu (opened from the gear button on the Songs tab): replay the intro,
//  privacy policy, app version. Add new rows/sections here as needed.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showIntro = false

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Help") {
                    Button {
                        showIntro = true
                    } label: {
                        HStack(spacing: 18){
                            Image(systemName:"sparkles.rectangle.stack")
                            Text("Show intro" )
                                .foregroundStyle(.white)
                        }
                       
                    }
                }

                Section("Legal") {
                    NavigationLink {
                        PrivacyPolicyView()
                    } label: {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: versionText)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .foregroundStyle(.white)
                        
                    }
                }
            }
            .fullScreenCover(isPresented: $showIntro) {
                OnboardingView { showIntro = false }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// In-app privacy policy. Describes what the app actually does with data —
/// keep it in sync when adding anything that touches the network or user data.
struct PrivacyPolicyView: View {
    private struct Item: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }

    private let items: [Item] = [
        Item(title: "Summary",
             body: "Mazut has no accounts, no ads and no analytics. Your music, recordings and lessons stay on your device. We do not collect, sell or share any personal data."),
        Item(title: "Your music",
             body: "Songs you import are separated into stems entirely on your device. Audio files and stems are stored only in the app's private storage and are never uploaded anywhere. Deleting a song, or the app, removes them."),
        Item(title: "Microphone",
             body: "The microphone is used only while you use the timing check in the Metronome or the Find the Note drill. Sound is analyzed in real time on your device and is never recorded to a file or sent anywhere. You can turn microphone access off at any time in Settings › Mazut."),
        Item(title: "Photos and files",
             body: "Videos, photos and documents you add to the Learning tab are copied into the app's private storage on your device. Mazut only sees the items you pick yourself."),
        Item(title: "YouTube",
             body: "YouTube links you add are played with YouTube's standard embedded player, and their titles and thumbnails are loaded from YouTube. When you do this, YouTube receives the request just as it would in a browser, and its own privacy policy applies (policies.google.com/privacy)."),
        Item(title: "Links to other websites",
             body: "\"Download songs\" opens an external website in your browser. Mazut is not responsible for the content or privacy practices of other sites."),
        Item(title: "Children",
             body: "Mazut does not knowingly collect any data from anyone, including children."),
        Item(title: "Changes",
             body: "If this policy changes, the updated version will be shown here in the app."),
    ]

    var body: some View {
        List {
            Section {
                Text("Last updated: November 3, 2026")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                Section(item.title) {
                    Text(item.body)
                        .font(.subheadline)
                }
            }
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    SettingsView()
}
