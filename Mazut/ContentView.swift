//
//  ContentView.swift
//  Mazut
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var engine = StemMixerEngine()
    @State private var separator = DemucsSeparator()
    @State private var stems: [Stem] = StemKind.allCases.map { Stem(kind: $0) }
    @State private var showImporter = false
    @State private var showSongImporter = false
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if engine.isLoaded {
                    transportBar
                    Divider()
                    stemList
                } else {
                    emptyState
                }
            }
            .navigationTitle("Mazut")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .fileImporter(
                isPresented: $showSongImporter,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    separateSong(url)
                } else if case .failure(let error) = result {
                    loadError = error.localizedDescription
                }
            }
            .alert("Greška", isPresented: .constant(loadError != nil)) {
                Button("U redu") { loadError = nil }
            } message: {
                Text(loadError ?? "")
            }
            .overlay { if separator.isRunning { separationOverlay } }
        }
    }

    private var separationOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView(value: separator.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                Text("Razdvajam stemove… \(Int(separator.progress * 100))%")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Prazno stanje

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Učitaj stemove")
                .font(.title2.bold())
            Text("Izaberi do 6 audio fajlova. Dodeljuju se redom: vokal, bubnjevi, bas, gitara, klavir, ostalo.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                showSongImporter = true
            } label: {
                Label("Razdvoj pesmu", systemImage: "wand.and.stars")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)

            Button {
                showImporter = true
            } label: {
                Label("Učitaj gotove stemove", systemImage: "folder")
                    .font(.subheadline)
            }
            Spacer()
        }
    }

    // MARK: - Transport

    private var transportBar: some View {
        VStack(spacing: 12) {
            Slider(
                value: Binding(
                    get: { engine.currentTime },
                    set: { engine.seek(to: $0) }
                ),
                in: 0...max(engine.duration, 0.01)
            )

            HStack {
                Text(timeString(engine.currentTime))
                Spacer()
                Text(timeString(engine.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            Button {
                engine.togglePlayPause()
            } label: {
                Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
            }
        }
        .padding()
    }

    // MARK: - Stemovi

    private var stemList: some View {
        List(stems) { stem in
            StemRow(stem: stem) {
                engine.applyMixToAllTracks()
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Import

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            // Kopiraj fajlove lokalno (izbegava security-scope probleme) i dodeli redom.
            var assigned: [Stem] = StemKind.allCases.map { Stem(kind: $0) }
            for (index, url) in urls.prefix(StemKind.allCases.count).enumerated() {
                guard let local = copyToTemp(url) else { continue }
                assigned[index].url = local
            }
            stems = assigned
            do {
                try engine.load(stems: stems)
            } catch {
                loadError = error.localizedDescription
            }
        case .failure(let error):
            loadError = error.localizedDescription
        }
    }

    private func separateSong(_ url: URL) {
        guard let local = copyToTemp(url) else { loadError = "Ne mogu da učitam fajl."; return }
        Task {
            do {
                let map = try await separator.separate(url: local)
                let assigned = StemKind.allCases.map { Stem(kind: $0) }
                for stem in assigned { stem.url = map[stem.kind] }
                stems = assigned
                try engine.load(stems: stems)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func copyToTemp(_ url: URL) -> URL? {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stems", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Red jednog stema

private struct StemRow: View {
    @Bindable var stem: Stem
    /// Pozvati kad se promeni bilo koja kontrola da engine osvezi mix.
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: stem.kind.systemImage)
                    .foregroundStyle(stem.kind.color)
                Text(stem.displayName)
                    .font(.headline)
                if stem.url == nil {
                    Text("— prazno")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    stem.isMuted.toggle()
                    onChange()
                } label: {
                    Image(systemName: stem.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(stem.isMuted ? .red : .primary)
                }
                .buttonStyle(.plain)

                Button {
                    stem.isSolo.toggle()
                    onChange()
                } label: {
                    Text("S")
                        .font(.caption.bold())
                        .padding(6)
                        .background(stem.isSolo ? stem.kind.color : Color.clear)
                        .foregroundStyle(stem.isSolo ? .white : .secondary)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.secondary.opacity(0.4)))
                }
                .buttonStyle(.plain)
            }

            Slider(value: $stem.volume, in: 0...1) { _ in
                onChange()
            }
            .tint(stem.kind.color)
            .disabled(stem.url == nil)
        }
        .padding(.vertical, 6)
        .opacity(stem.url == nil ? 0.5 : 1)
    }
}

#Preview {
    ContentView()
}
