//
//  ContentView.swift
//  Mazut
//

import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Učitaj sliku iz fajla u SwiftUI `Image` (cross-platform).
private func loadArtwork(_ url: URL) -> Image? {
#if canImport(UIKit)
    guard let img = UIImage(contentsOfFile: url.path) else { return nil }
    return Image(uiImage: img)
#elseif canImport(AppKit)
    guard let img = NSImage(contentsOfFile: url.path) else { return nil }
    return Image(nsImage: img)
#else
    return nil
#endif
}

struct ContentView: View {
    @Environment(\.openURL) private var openURL
    /// Eksterni izvor pesama (otvara se u pregledaču).
    private let downloadURL = URL(string: "https://st-tancpol.ru/music")!

    @State private var engine = StemMixerEngine()
    @State private var separator = DemucsSeparator()
    @State private var metronome = Metronome()
    @State private var tuner = Tuner()
    @State private var stems: [Stem] = StemKind.allCases.map { Stem(kind: $0) }
    @State private var showImporter = false
    /// true = „Razdvoj pesmu" (jedan fajl → separacija), false = „Učitaj gotove stemove" (više fajlova).
    @State private var importSongMode = false
    @State private var loadError: String?
    @State private var separationTask: Task<Void, Never>?
    @State private var library: [CachedSong] = []
    /// Ime pesme koja je trenutno učitana (prikazuje se u headeru umesto „Mazut").
    @State private var nowPlayingTitle: String?
    /// Ključ (id) pesme koja trenutno svira — za auto-prelazak na sledeću.
    @State private var nowPlayingID: String?
    /// Kriterijum sortiranja biblioteke (podrazumevano: datum). Pamti se između pokretanja.
    @AppStorage("librarySort") private var librarySortRaw = LibrarySort.date.rawValue

    // MARK: - Plejliste i red reprodukcije

    @State private var playlists: [Playlist] = []
    @State private var selectedTab = 0
    /// Pesma za koju je otvoren „Dodaj u plejlistu" list (swipe udesno).
    @State private var songToAdd: CachedSong?
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistName = ""
    /// Trenutni red reprodukcije i da li se ide na sledeću po završetku.
    @State private var playQueue: [CachedSong] = []
    @State private var autoAdvance = false
    /// Pauza (sekunde) između pesama trenutne plejliste.
    @State private var playbackDelay = 0
    /// Task koji čeka pauzu pa pušta sledeću pesmu (otkazuje se pri ručnoj akciji).
    @State private var delayTask: Task<Void, Never>?

    var body: some View {
        Group {
            if engine.isLoaded {
                playerView
            } else {
                tabs
            }
        }
        .onAppear {
            library = StemCache.library()
            playlists = PlaylistStore.load()
            engine.onPlaybackFinished = { playNext() }
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
        .sheet(item: $songToAdd) { song in
            addToPlaylistSheet(song)
        }
        .overlay { if separator.isRunning { separationOverlay } }
    }

    // MARK: - Tabovi (donji meni)

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            libraryTab
                .tabItem { Label("Pesme", systemImage: "plus.circle.fill") }
                .tag(0)
            playlistsTab
                .tabItem { Label("Plejliste", systemImage: "music.note.list") }
                .tag(1)
            metronomeTab
                .tabItem { Label("Metronom", systemImage: "metronome") }
                .tag(2)
            tunerTab
                .tabItem { Label("Štimer", systemImage: "tuningfork") }
                .tag(3)
        }
        .onChange(of: selectedTab) { _, newValue in
            // Štimer snima samo dok je njegov tab otvoren.
            if newValue != 3 { tuner.stop() }
        }
    }

    // MARK: - Tab: Pesme (biblioteka „Ranije razdvojeno" + dodavanje novih)

    private var libraryTab: some View {
        NavigationStack {
            Group {
                if library.isEmpty { emptyState } else { libraryView }
            }
            .navigationTitle("Mazut")
        }
    }

    private var libraryView: some View {
        VStack(spacing: 0) {
            let songs = sortedLibrary
            List {
                Section {
                    ForEach(songs) { song in
                        Button {
                            // Red = cela (sortirana) biblioteka → ručno prebacivanje radi,
                            // ali bez auto-prelaska na kraju pesme.
                            playbackDelay = 0
                            openCached(song, queue: songs, autoAdvance: false)
                        } label: {
                            SongRow(song: song)
                                .contentShape(Rectangle())
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                songToAdd = song
                            } label: {
                                Label("U plejlistu", systemImage: "text.badge.plus")
                            }
                            .tint(.green)
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { StemCache.delete(key: songs[i].id) }
                        library = StemCache.library()
                    }
                } header: {
                    HStack {
                        Text("Ranije razdvojeno")
                        Spacer()
                        Menu {
                            Picker("Sortiraj", selection: $librarySortRaw) {
                                ForEach(LibrarySort.allCases) { sort in
                                    Label(sort.label, systemImage: sort.systemImage)
                                        .tag(sort.rawValue)
                                }
                            }
                        } label: {
                            Label("Sortiraj", systemImage: "arrow.up.arrow.down")
                                .labelStyle(.iconOnly)
                        }
                    }
                } footer: {
                    let total = library.reduce(Int64(0)) { $0 + $1.size }
                    Text("\(library.count) \(pesmaPlural(library.count)) · ukupno \(total.formatted(.byteCount(style: .file)))")
                }
            }
            .listStyle(.insetGrouped)

            addNewMenu
        }
    }

    /// Meni „Dodaj novu" (razdvoj / učitaj stemove / preuzmi).
    private var addNewMenu: some View {
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
            Button {
                openURL(downloadURL)
            } label: {
                Label("Preuzmi pesme", systemImage: "globe")
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

    // MARK: - Tab: Plejliste

    private var playlistsTab: some View {
        NavigationStack {
            Group {
                if playlists.isEmpty {
                    playlistsEmptyState
                } else {
                    List {
                        ForEach(playlists) { playlist in
                            NavigationLink {
                                PlaylistDetailView(
                                    playlistID: playlist.id,
                                    playlists: $playlists,
                                    library: library,
                                    onPlay: { song, queue, delay in
                                        playbackDelay = delay
                                        openCached(song, queue: queue, autoAdvance: true, autoPlay: true)
                                    }
                                )
                            } label: {
                                playlistRow(playlist)
                            }
                        }
                        .onDelete { offsets in deletePlaylists(offsets) }
                    }
                }
            }
            .navigationTitle("Plejliste")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newPlaylistName = ""
                        showNewPlaylistAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Nova plejlista", isPresented: $showNewPlaylistAlert) {
                TextField("Naziv", text: $newPlaylistName)
                Button("Otkaži", role: .cancel) {}
                Button("Napravi") { _ = createPlaylist(newPlaylistName) }
            }
        }
    }

    private var playlistsEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Nema plejlista")
                .font(.title2.bold())
            Text("Napravi plejlistu pa dodaj pesme prevlačenjem udesno u tabu Pesme.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                newPlaylistName = ""
                showNewPlaylistAlert = true
            } label: {
                Label("Nova plejlista", systemImage: "plus")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.body)
                Text("\(playlist.songIDs.count) \(pesmaPlural(playlist.songIDs.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Tab: Metronom (placeholder)

    private var metronomeTab: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                // Tempo
                VStack(spacing: 2) {
                    Text("\(metronome.bpm)")
                        .font(.system(size: 76, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("BPM")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                // Indikator dobara
                HStack(spacing: 14) {
                    ForEach(0..<metronome.beatsPerMeasure, id: \.self) { i in
                        Circle()
                            .fill(beatColor(i))
                            .frame(width: 18, height: 18)
                            .scaleEffect(metronome.beatsPerMeasure > 1
                                         && metronome.isRunning && i == metronome.currentBeat ? 1.35 : 1)
                            .animation(.easeOut(duration: 0.08), value: metronome.currentBeat)
                    }
                }
                .frame(height: 28)

                // Podešavanje tempa
                HStack(spacing: 20) {
                    Button { metronome.bpm = max(40, metronome.bpm - 1) } label: {
                        Image(systemName: "minus.circle.fill").font(.largeTitle)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(metronome.bpm) },
                            set: { metronome.bpm = Int($0.rounded()) }
                        ),
                        in: 40...240, step: 1
                    )
                    Button { metronome.bpm = min(240, metronome.bpm + 1) } label: {
                        Image(systemName: "plus.circle.fill").font(.largeTitle)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal)

                // Takt (broj dobara)
                Picker("Takt", selection: $metronome.beatsPerMeasure) {
                    ForEach([1, 2, 3, 4, 6], id: \.self) { n in
                        Text(n == 1 ? "1/1" : "\(n)/4").tag(n)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Start / Stop
                Button {
                    metronome.toggle()
                } label: {
                    Label(metronome.isRunning ? "Stop" : "Start",
                          systemImage: metronome.isRunning ? "stop.fill" : "play.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(metronome.isRunning ? .red : .accentColor)
                .padding(.horizontal)

                Spacer()
            }
            .padding()
            .navigationTitle("Metronom")
        }
    }

    /// Boja kružića dobra: aktivan dobar svetli (prvi crveno, ostali akcenat).
    /// U 1/1 boja se ne menja po dobru — stalna dok svira.
    private func beatColor(_ i: Int) -> Color {
        if metronome.beatsPerMeasure == 1 {
            return metronome.isRunning ? .accentColor : Color.gray.opacity(0.3)
        }
        if metronome.isRunning && i == metronome.currentBeat {
            return i == 0 ? .red : .accentColor
        }
        return Color.gray.opacity(0.3)
    }

    // MARK: - Tab: Štimer (tuner za gitaru)

    /// U štimu kad postoji signal i odstupanje je manje od 5 centi.
    private var tunerInTune: Bool { tuner.hasSignal && abs(tuner.cents) < 5 }

    private var tunerTab: some View {
        NavigationStack {
            VStack(spacing: 28) {
                // Izbor štima
                Picker("Štim", selection: $tuner.tuning) {
                    ForEach(GuitarTuning.all) { Text($0.name).tag($0) }
                }
                .pickerStyle(.menu)

                Spacer()

                // Velika nota + odstupanje
                VStack(spacing: 4) {
                    Text(tuner.hasSignal ? tuner.noteNameWithOctave : "—")
                        .font(.system(size: 88, weight: .bold, design: .rounded))
                        .foregroundStyle(tunerInTune ? Color.green : .primary)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.12), value: tuner.midiNote)
                    Text(tuner.hasSignal
                         ? "\(tuner.cents >= 0 ? "+" : "")\(Int(tuner.cents.rounded())) c · \(Int(tuner.frequency.rounded())) Hz"
                         : "odsviraj žicu")
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                centsMeter

                // Ciljne žice (sakriveno u hromatskom režimu)
                if !tuner.tuning.isChromatic {
                    let nearest = tuner.hasSignal
                        ? tuner.tuning.nearestString(toMidi: tuner.midiNote) : nil
                    HStack(spacing: 10) {
                        ForEach(Array(tuner.tuning.strings.enumerated()), id: \.offset) { idx, midi in
                            Text(Tuner.noteName(forMidi: midi, withOctave: true))
                                .font(.subheadline.bold())
                                .monospacedDigit()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(stringChipColor(isNearest: idx == nearest))
                                .foregroundStyle(idx == nearest ? .white : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                if tuner.permissionDenied {
                    Text("Pristup mikrofonu je odbijen. Uključi ga u Podešavanja → Mazut → Mikrofon.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Štimer")
            .onAppear { tuner.start() }
            .onDisappear { tuner.stop() }
        }
    }

    /// Horizontalni indikator centi: centar = u štimu, igla klizi levo/desno.
    private var centsMeter: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = max(-1, min(1, tuner.cents / 50))   // −50…+50 c → −1…+1
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 6)
                    .frame(maxHeight: .infinity, alignment: .center)
                // Centralna oznaka
                Rectangle()
                    .fill(Color.secondary)
                    .frame(width: 2)
                    .position(x: w / 2, y: geo.size.height / 2)
                // Igla
                Circle()
                    .fill(tunerInTune ? Color.green : Color.accentColor)
                    .frame(width: 22, height: 22)
                    .position(x: w / 2 + CGFloat(frac) * (w / 2 - 11),
                              y: geo.size.height / 2)
                    .opacity(tuner.hasSignal ? 1 : 0.25)
                    .animation(.easeOut(duration: 0.08), value: tuner.cents)
            }
        }
        .frame(height: 44)
        .padding(.horizontal)
    }

    private func stringChipColor(isNearest: Bool) -> Color {
        guard isNearest else { return Color.gray.opacity(0.15) }
        return tunerInTune ? .green : .accentColor
    }

    // MARK: - „Dodaj u plejlistu" (swipe udesno)

    private func addToPlaylistSheet(_ song: CachedSong) -> some View {
        NavigationStack {
            List {
                Section("Nova plejlista") {
                    HStack {
                        TextField("Naziv", text: $newPlaylistName)
                        Button("Dodaj") {
                            let pl = createPlaylist(newPlaylistName)
                            addSong(song, to: pl)
                            songToAdd = nil
                        }
                        .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if !playlists.isEmpty {
                    Section("Postojeće") {
                        ForEach(playlists) { pl in
                            Button {
                                addSong(song, to: pl)
                                songToAdd = nil
                            } label: {
                                HStack {
                                    Text(pl.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if pl.songIDs.contains(song.id) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Dodaj u plejlistu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Otkaži") { songToAdd = nil }
                }
            }
            .onAppear { newPlaylistName = "" }
        }
    }

    // MARK: - Mutacije plejlista

    @discardableResult
    private func createPlaylist(_ name: String) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let pl = Playlist(id: UUID().uuidString,
                          name: trimmed.isEmpty ? "Plejlista" : trimmed,
                          songIDs: [])
        playlists.append(pl)
        PlaylistStore.save(playlists)
        return pl
    }

    private func addSong(_ song: CachedSong, to playlist: Playlist) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        guard !playlists[idx].songIDs.contains(song.id) else { return }
        playlists[idx].songIDs.append(song.id)
        PlaylistStore.save(playlists)
    }

    private func deletePlaylists(_ offsets: IndexSet) {
        playlists.remove(atOffsets: offsets)
        PlaylistStore.save(playlists)
    }

    // MARK: - Plejer (prikazuje se dok je pesma učitana)

    private var playerView: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transportBar
                Divider()
                stemList
            }
            .navigationTitle(nowPlayingTitle ?? "Mazut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { backToList() } label: {
                        Label("Nazad", systemImage: "chevron.left")
                    }
                }
            }
        }
    }

    private func backToList() {
        delayTask?.cancel()
        engine.unload()
        stems = StemKind.allCases.map { Stem(kind: $0) }
        nowPlayingTitle = nil
        nowPlayingID = nil
        playQueue = []
        autoAdvance = false
        playbackDelay = 0
        library = StemCache.library()
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

            Button {
                openURL(downloadURL)
            } label: {
                Label("Preuzmi pesme", systemImage: "globe")
                    .font(.subheadline)
            }
            Spacer()
        }
    }

    // MARK: - Sortiranje biblioteke

    /// Biblioteka poređana po izabranom kriterijumu.
    private var sortedLibrary: [CachedSong] {
        switch LibrarySort(rawValue: librarySortRaw) ?? .date {
        case .date:
            return library.sorted { $0.date > $1.date }          // najnovije prvo
        case .title:
            return library.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            return library.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .duration:
            return library.sorted { $0.duration < $1.duration }
        }
    }

    /// Srpska množina za „pesma": 1 → pesma, 2–4 → pesme, ostalo → pesama
    /// (izuzeci 11–14 → pesama).
    private func pesmaPlural(_ n: Int) -> String {
        let d = n % 10, dd = n % 100
        if d == 1 && dd != 11 { return "pesma" }
        if (2...4).contains(d) && !(12...14).contains(dd) { return "pesme" }
        return "pesama"
    }

    // MARK: - Reprodukcija

    /// Učitaj keširanu pesmu u mikser bez ponovnog razdvajanja.
    /// `queue` je red reprodukcije, `autoAdvance` da li se na kraju ide na sledeću,
    /// `autoPlay` da li odmah počinje reprodukcija.
    private func openCached(_ song: CachedSong, queue: [CachedSong],
                            autoAdvance: Bool, autoPlay: Bool = false) {
        delayTask?.cancel()
        self.playQueue = queue
        self.autoAdvance = autoAdvance
        // Prenesi podešavanja (jačina / mute / solo) sa prethodne pesme.
        let prev = Dictionary(stems.map { ($0.kind, $0) }, uniquingKeysWith: { a, _ in a })
        let assigned = StemKind.allCases.map { kind -> Stem in
            let stem = Stem(kind: kind)
            stem.url = song.stems[kind]
            if let p = prev[kind] {
                stem.volume = p.volume
                stem.isMuted = p.isMuted
                stem.isSolo = p.isSolo
            }
            return stem
        }
        stems = assigned
        do {
            try engine.load(stems: stems)
            nowPlayingTitle = song.name
            nowPlayingID = song.id
            if autoPlay { engine.play() }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Pređi na sledeću pesmu u redu i pusti je — samo ako je auto-prelazak uključen
    /// (tj. reprodukcija je krenula iz plejliste). Na kraju reda se zaustavlja.
    private func playNext() {
        guard autoAdvance,
              let idx = currentQueueIndex,
              idx + 1 < playQueue.count else { return }
        let next = playQueue[idx + 1]
        guard playbackDelay > 0 else {
            openCached(next, queue: playQueue, autoAdvance: true, autoPlay: true)
            return
        }
        // Pauza između pesama, pa pusti sledeću (osim ako korisnik prekine).
        delayTask?.cancel()
        delayTask = Task {
            try? await Task.sleep(for: .seconds(playbackDelay))
            guard !Task.isCancelled else { return }
            openCached(next, queue: playQueue, autoAdvance: true, autoPlay: true)
        }
    }

    /// Pozicija trenutne pesme u redu reprodukcije.
    private var currentQueueIndex: Int? {
        guard let id = nowPlayingID else { return nil }
        return playQueue.firstIndex { $0.id == id }
    }

    private var canGoNext: Bool {
        if let i = currentQueueIndex { return i + 1 < playQueue.count }
        return false
    }

    /// Ručno (dugme „prethodna"): prvi pritisak vraća na početak pesme; ako je
    /// proteklo ≤ 5 s reprodukcije, prelazi na prethodnu pesmu u redu.
    private func playPrevious() {
        if engine.currentTime > 5 {
            engine.seek(to: 0)
            return
        }
        guard let i = currentQueueIndex, i > 0 else {
            engine.seek(to: 0)   // nema prethodne → samo na početak
            return
        }
        openCached(playQueue[i - 1], queue: playQueue, autoAdvance: autoAdvance, autoPlay: true)
    }

    /// Ručno (dugme) — sledeća pesma u redu; zadržava trenutni način prelaska.
    private func playNextManual() {
        guard let i = currentQueueIndex, i + 1 < playQueue.count else { return }
        openCached(playQueue[i + 1], queue: playQueue, autoAdvance: autoAdvance, autoPlay: true)
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

            HStack(spacing: 40) {
                Button {
                    playPrevious()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 28))
                }

                Button {
                    engine.togglePlayPause()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                }

                Button {
                    playNextManual()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 28))
                }
                .disabled(!canGoNext)
            }

            metronomeBar
        }
        .padding()
    }

    /// Kompaktna metronom traka ispod transport dugmadi — pali/gasi + tempo.
    /// Metronom svira preko pesme i zadržava stanje između pesama u plejlisti.
    private var metronomeBar: some View {
        HStack(spacing: 14) {
            Button {
                metronome.toggle()
            } label: {
                Image(systemName: "metronome")
                    .font(.title3)
                    .foregroundStyle(metronome.isRunning ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            // Živi pokazivač dobra.
            Circle()
                .fill(metronomeDotColor)
                .frame(width: 10, height: 10)
                .animation(.easeOut(duration: 0.08), value: metronome.currentBeat)

            Spacer()

            Button { metronome.bpm = max(40, metronome.bpm - 1) } label: {
                Image(systemName: "minus.circle")
            }
            Text("\(metronome.bpm) BPM")
                .font(.subheadline.monospacedDigit())
                .frame(minWidth: 78)
            Button { metronome.bpm = min(240, metronome.bpm + 1) } label: {
                Image(systemName: "plus.circle")
            }
        }
        .buttonStyle(.plain)
        .font(.title3)
        .padding(.top, 4)
    }

    private var metronomeDotColor: Color {
        guard metronome.isRunning else { return Color.gray.opacity(0.3) }
        if metronome.beatsPerMeasure > 1 && metronome.currentBeat == 0 { return .red }
        return .accentColor
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
            playQueue = []
            autoAdvance = false
            do {
                try engine.load(stems: stems)
                nowPlayingTitle = nil   // skup zasebnih stemova → ostaje „Mazut"
                nowPlayingID = nil
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
                playQueue = []
                autoAdvance = false
                try engine.load(stems: stems)
                nowPlayingTitle = local.deletingPathExtension().lastPathComponent
                // Ključ pesme = ime foldera u kome su stemovi (hash sadržaja).
                nowPlayingID = map.values.first?.deletingLastPathComponent().lastPathComponent
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

// MARK: - Red jedne pesme (deljeno: biblioteka + plejliste)

struct SongRow: View {
    let song: CachedSong

    var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(Self.subtitle(for: song))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// Sličica pesme: ugrađeni album art ako postoji, inače placeholder s notom.
    @ViewBuilder
    private var artwork: some View {
        let side: CGFloat = 44
        if let url = song.artworkURL, let img = loadArtwork(url) {
            img
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: side, height: side)
                .overlay {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
        }
    }

    /// Podnaslov: izvođač · trajanje · datum (izostavlja prazne delove).
    static func subtitle(for song: CachedSong) -> String {
        var parts: [String] = []
        if !song.artist.isEmpty { parts.append(song.artist) }
        if song.duration > 0 { parts.append(timeString(song.duration)) }
        parts.append(song.date.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }

    static func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Detalji plejliste

private struct PlaylistDetailView: View {
    let playlistID: String
    @Binding var playlists: [Playlist]
    let library: [CachedSong]
    /// (pesma, ceo red, pauza u sekundama) → pusti pesmu sa auto-prelaskom na sledeću.
    let onPlay: (CachedSong, [CachedSong], Int) -> Void

    /// Ponuđene pauze između pesama (sekunde).
    private let delayOptions = [0, 1, 2, 5, 10]

    private var playlist: Playlist? {
        playlists.first { $0.id == playlistID }
    }

    /// Pesme plejliste, redosledom; preskaču se one obrisane iz keša.
    private var songs: [CachedSong] {
        guard let playlist else { return [] }
        let byID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return playlist.songIDs.compactMap { byID[$0] }
    }

    var body: some View {
        Group {
            if songs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Plejlista je prazna")
                        .font(.headline)
                    Text("Dodaj pesme prevlačenjem udesno u tabu Pesme.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            } else {
                List {
                    Section {
                        ForEach(songs) { song in
                            Button {
                                onPlay(song, songs, playlist?.delay ?? 0)
                            } label: {
                                SongRow(song: song)
                                    .contentShape(Rectangle())
                            }
                        }
                        .onDelete { remove($0) }
                        .onMove { move(from: $0, to: $1) }
                    } header: {
                        if let delay = playlist?.delay, delay > 0 {
                            Text("Pauza između pesama: \(delay) s")
                        }
                    }
                }
            }
        }
        .navigationTitle(playlist?.name ?? "Plejlista")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Pauza između pesama", selection: delayBinding) {
                        ForEach(delayOptions, id: \.self) { sec in
                            Text(sec == 0 ? "Bez pauze" : "\(sec) s").tag(sec)
                        }
                    }
                } label: {
                    Label("Pauza", systemImage: "timer")
                }
            }
            if !songs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
    }

    /// Binding na pauzu plejliste (čita iz modela, upisuje i snima).
    private var delayBinding: Binding<Int> {
        Binding(
            get: { playlist?.delay ?? 0 },
            set: { newValue in
                guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
                playlists[idx].delaySeconds = newValue
                PlaylistStore.save(playlists)
            }
        )
    }

    private func remove(_ offsets: IndexSet) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let ids = offsets.map { songs[$0].id }
        playlists[idx].songIDs.removeAll { ids.contains($0) }
        PlaylistStore.save(playlists)
    }

    private func move(from source: IndexSet, to destination: Int) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[idx].songIDs.move(fromOffsets: source, toOffset: destination)
        PlaylistStore.save(playlists)
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

// MARK: - Sortiranje biblioteke

/// Kriterijum sortiranja liste pesama.
private enum LibrarySort: String, CaseIterable, Identifiable {
    case date, title, artist, duration

    var id: String { rawValue }

    var label: String {
        switch self {
        case .date:     return "Datum"
        case .title:    return "Naslov"
        case .artist:   return "Izvođač"
        case .duration: return "Trajanje"
        }
    }

    var systemImage: String {
        switch self {
        case .date:     return "calendar"
        case .title:    return "textformat"
        case .artist:   return "person"
        case .duration: return "clock"
        }
    }
}

#Preview {
    ContentView()
}
