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
    /// true = „Razdvoj pesmu" (jedan fajl → separacija), false = „Učitaj gotove stemove" (više fajlova).
    @State private var importSongMode = false
    @State private var loadError: String?
    @State private var separationTask: Task<Void, Never>?
    @State private var library: [CachedSong] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if engine.isLoaded {
                    transportBar
                    Divider()
                    stemList
                } else if library.isEmpty {
                    emptyState
                } else {
                    libraryView
                }
            }
            .navigationTitle("Mazut")
            .onAppear { library = StemCache.library() }
            .toolbar {
                if engine.isLoaded {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            engine.unload()
                            stems = StemKind.allCases.map { Stem(kind: $0) }
                            library = StemCache.library()
                        } label: {
                            Label("Nova pesma", systemImage: "chevron.left")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        importSongMode = false
                        showImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
            // Jedan jedini .fileImporter: dva na istom view-u se u SwiftUI-ju
            // poništavaju (radi samo poslednji). Režim biramo preko importSongMode.
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: !importSongMode
            ) { result in
                if importSongMode {
                    if case .success(let urls) = result, let url = urls.first {
                        separateSong(url)
                    } else if case .failure(let error) = result {
                        loadError = error.localizedDescription
                    }
                } else {
                    handleImport(result)
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

                Button(role: .cancel) {
                    separationTask?.cancel()
                } label: {
                    Text("Odustani")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(.white)
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
                importSongMode = true
                showImporter = true
            } label: {
                Label("Razdvoj pesmu", systemImage: "wand.and.stars")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)

            Button {
                importSongMode = false
                showImporter = true
            } label: {
                Label("Učitaj gotove stemove", systemImage: "folder")
                    .font(.subheadline)
            }
            Spacer()
        }
    }

    // MARK: - Biblioteka keširanih pesama

    private var libraryView: some View {
        VStack(spacing: 0) {
            List {
                Section("Ranije razdvojeno") {
                    ForEach(library) { song in
                        Button {
                            openCached(song)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "music.note")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text(song.date, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { StemCache.delete(key: library[i].id) }
                        library = StemCache.library()
                    }
                }
            }
            .listStyle(.insetGrouped)

            Menu {
                Button {
                    importSongMode = true
                    showImporter = true
                } label: {
                    Label("Razdvoj pesmu", systemImage: "wand.and.stars")
                }
                Button {
                    importSongMode = false
                    showImporter = true
                } label: {
                    Label("Učitaj gotove stemove", systemImage: "folder")
                }
            } label: {
                Label("Dodaj novu", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }

    /// Učitaj keširanu pesmu u mikser bez ponovnog razdvajanja.
    private func openCached(_ song: CachedSong) {
        let assigned = StemKind.allCases.map { Stem(kind: $0) }
        for stem in assigned { stem.url = song.stems[stem.kind] }
        stems = assigned
        do {
            try engine.load(stems: stems)
        } catch {
            loadError = error.localizedDescription
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
            let assigned: [Stem] = StemKind.allCases.map { Stem(kind: $0) }
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
        separationTask = Task {
            do {
                let map = try await separator.separate(url: local)
                let assigned = StemKind.allCases.map { Stem(kind: $0) }
                for stem in assigned { stem.url = map[stem.kind] }
                stems = assigned
                try engine.load(stems: stems)
                library = StemCache.library()   // nova pesma je sad u kešu
            } catch is CancellationError {
                // Korisnik je odustao — bez greške, samo se vrati na izbor pesme.
            } catch {
                loadError = error.localizedDescription
            }
            separationTask = nil
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
