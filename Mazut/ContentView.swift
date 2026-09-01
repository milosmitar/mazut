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

/// Load an image from a file into a SwiftUI `Image` (cross-platform).
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

/// Shared wallpaper behind all four tabs' root screens (Songs, Playlists,
/// Metronome, Learning). `List`s paint their own opaque background by
/// default, so each screen that uses one calls `.scrollContentBackground(.hidden)`
/// so this shows through around/behind their (still-opaque) row cards.
/// Placed inside each tab's own `NavigationStack` (not on the outer `TabView`)
/// since `NavigationStack` content otherwise sits on an opaque system background
/// that a `TabView`-level `.background()` can't show through.
struct TabBackgroundView: View {
    var body: some View {
        GeometryReader { geo in
            Image("TabBackground")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .blur(radius: 6)
                .overlay {
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.55),
                            Color.black.opacity(0.7),
                            Color.black.opacity(0.55),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
        }
        .ignoresSafeArea()
    }
}

struct ContentView: View {
    @Environment(\.openURL) private var openURL
    /// External source for songs (opens in the browser).
    private let downloadURL = URL(string: "https://st-tancpol.ru/music")!

    // Shared instance: SwiftUI can run a view's initializer multiple times,
    // and every `StemMixerEngine()` would re-bind the global bridges (remote
    // commands, Live Activity) to a new empty instance — see StemMixerEngine.shared.
    @State private var engine = StemMixerEngine.shared
    @State private var separator = DemucsSeparator()
    @State private var metronome = Metronome()
    @State private var timingCoach = TimingCoach()
    @State private var tuner = Tuner()
    @State private var stems: [Stem] = StemKind.allCases.map { Stem(kind: $0) }
    @State private var showImporter = false
    @State private var loadError: String?
    @State private var separationTask: Task<Void, Never>?
    @State private var library: [CachedSong] = []
    /// Name of the currently loaded song (shown in the header instead of "Mazut").
    @State private var nowPlayingTitle: String?
    /// Key (id) of the currently playing song — for auto-advance to the next one.
    @State private var nowPlayingID: String?
    /// Library sort criterion (default: date). Persisted across launches.
    @AppStorage("librarySort") private var librarySortRaw = LibrarySort.date.rawValue

    // MARK: - Playlists and playback queue

    @State private var playlists: [Playlist] = []
    @State private var selectedTab = 0
    /// Song for which the "Add to Playlist" sheet is open (swipe right).
    @State private var songToAdd: CachedSong?
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistName = ""
    /// Current playback queue and whether to advance to the next song when it finishes.
    @State private var playQueue: [CachedSong] = []
    @State private var autoAdvance = false
    /// Pause (seconds) between songs in the current playlist.
    @State private var playbackDelay = 0
    /// Task that waits out the pause, then plays the next song (cancelled on manual action).
    @State private var delayTask: Task<Void, Never>?
    /// Repeat the current song (independent of the queue/playlist).
    @State private var repeatEnabled = false
    /// Random pick of the next song from the queue, instead of the next one in order.
    @State private var shuffleEnabled = false

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
            engine.onRemoteNext = { playNextManual() }
            engine.onRemotePrevious = { playPrevious() }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                separateSong(url)
            } else if case .failure(let error) = result {
                loadError = error.localizedDescription
            }
        }
        .alert("Error", isPresented: .constant(loadError != nil)) {
            Button("OK") { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
        .sheet(item: $songToAdd) { song in
            addToPlaylistSheet(song)
        }
        .overlay { if separator.isRunning { separationOverlay } }
    }

    // MARK: - Tabs (bottom menu)

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            libraryTab
                .tabItem { Label("Songs", systemImage: "plus.circle.fill") }
                .tag(0)
            playlistsTab
                .tabItem { Label("Playlists", systemImage: "music.note.list") }
                .tag(1)
            metronomeTab
                .tabItem { Label("Metronome", systemImage: "metronome") }
                .tag(2)
            LearningTab()
                .tabItem { Label("Learning", systemImage: "graduationcap") }
                .tag(3)
            // tunerTab
            //     .tabItem { Label("Tuner", systemImage: "tuningfork") }
            //     .tag(4)
        }
        // The wallpaper behind these tabs is dark, so force dark-mode text/controls
        // regardless of system appearance — default light-mode (near-black) text is
        // unreadable against it otherwise.
        .preferredColorScheme(.dark)
        .onChange(of: selectedTab) { _, newValue in
            // The tuner and the timing coach only record while their tab is open.
            if newValue != 4 { tuner.stop() }
            if newValue != 2 { timingCoach.stop() }
        }
    }

    // MARK: - Tab: Songs (library "Previously separated" + adding new ones)

    private var libraryTab: some View {
        NavigationStack {
            ZStack {
                TabBackgroundView()
                Group {
                    if library.isEmpty { emptyState } else { libraryView }
                }
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
                            // Queue = the whole (sorted) library → manual switching works,
                            // but without auto-advance at the end of the song.
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
                                Label("To playlist", systemImage: "text.badge.plus")
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
                        Text("Previously separated")
                        Spacer()
                        Menu {
                            Picker("Sort", selection: $librarySortRaw) {
                                ForEach(LibrarySort.allCases) { sort in
                                    Label(sort.label, systemImage: sort.systemImage)
                                        .tag(sort.rawValue)
                                }
                            }
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                                .labelStyle(.iconOnly)
                        }
                    }
                } footer: {
                    let total = library.reduce(Int64(0)) { $0 + $1.size }
                    Text("\(library.count) \(songPlural(library.count)) · total \(total.formatted(.byteCount(style: .file)))")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)

            addNewMenu
        }
    }

    /// "Add new" menu (separate / download).
    private var addNewMenu: some View {
        Menu {
            Button {
                showImporter = true
            } label: {
                Label("Separate a song", systemImage: "wand.and.stars")
            }
            Button {
                openURL(downloadURL)
            } label: {
                Label("Download songs", systemImage: "globe")
            }
        } label: {
            Label("Add new", systemImage: "plus")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .padding()
    }

    // MARK: - Tab: Playlists

    private var playlistsTab: some View {
        NavigationStack {
            ZStack {
                TabBackgroundView()
                playlistsContent
            }
            .navigationTitle("Playlists")
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
            .alert("New Playlist", isPresented: $showNewPlaylistAlert) {
                TextField("Name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { _ = createPlaylist(newPlaylistName) }
            }
        }
    }

    private var playlistsContent: some View {
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
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var playlistsEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No playlists")
                .font(.title2.bold())
            Text("Create a playlist, then add songs by swiping right in the Songs tab.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                newPlaylistName = ""
                showNewPlaylistAlert = true
            } label: {
                Label("New Playlist", systemImage: "plus")
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
                Text("\(playlist.songIDs.count) \(songPlural(playlist.songIDs.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Tab: Metronome (placeholder)

    private var metronomeTab: some View {
        NavigationStack {
            ZStack {
                TabBackgroundView()
                metronomeContent
            }
            .navigationTitle("Metronome")
        }
    }

    private var metronomeContent: some View {
        // Scrolls: with the drum grooves and the timing check the column no
        // longer fits on a small phone.
        ScrollView {
            VStack(spacing: 22) {
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

                // Beat indicator
                HStack(spacing: 14) {
                    ForEach(0..<metronome.activeBeatsPerMeasure, id: \.self) { i in
                        Circle()
                            .fill(beatColor(i))
                            .frame(width: 18, height: 18)
                            .scaleEffect(metronome.activeBeatsPerMeasure > 1
                                         && metronome.isRunning && i == metronome.currentBeat ? 1.35 : 1)
                            .animation(.easeOut(duration: 0.08), value: metronome.currentBeat)
                    }
                }
                .frame(height: 28)

                // Tempo adjustment
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

                // Time signature (number of beats) — a fixed groove brings its own.
                Picker("Time signature", selection: $metronome.beatsPerMeasure) {
                    ForEach([1, 2, 3, 4, 6], id: \.self) { n in
                        Text(n == 1 ? "1/1" : "\(n)/4").tag(n)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(grooveOverridesTimeSignature)
                .opacity(grooveOverridesTimeSignature ? 0.4 : 1)
                .padding(.horizontal)

                // Sound: synthetic click or drum kit (kick on the accent, hi-hat elsewhere)
                Picker("Sound", selection: $metronome.sound) {
                    ForEach(MetronomeSound.allCases) { s in
                        Label(s.label, systemImage: s.symbol).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Groove — only meaningful for the drum kit.
                if metronome.sound == .drums {
                    groovePicker
                        .padding(.horizontal)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Start / Stop
                Button {
                    metronome.toggle()
                    if !metronome.isRunning { timingCoach.stop() }
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

                timingSection
                    .padding(.horizontal)
            }
            .padding()
        }
        .scrollBounceBehavior(.basedOnSize)
        .animation(.easeInOut(duration: 0.2), value: metronome.sound)
        .animation(.easeInOut(duration: 0.2), value: timingCoach.isListening)
    }

    // MARK: - Timing check (microphone)

    /// Grades what you play against the click grid. Headphones only — over the
    /// speaker the microphone hears the metronome and would grade its own click.
    private var timingSection: some View {
        VStack(spacing: 10) {
            Button {
                timingCoach.toggle(metronome: metronome)
            } label: {
                Label(timingCoach.isListening ? "Stop listening" : "Check my timing",
                      systemImage: timingCoach.isListening ? "waveform" : "mic")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(timingCoach.isListening ? .green : .accentColor)
            .disabled(!metronome.isRunning)

            if timingCoach.permissionDenied {
                Text("Microphone access is off — turn it on in Settings › Mazut.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            } else if timingCoach.isListening {
                timingReadout
            } else {
                Text("Put headphones on: through the speaker the microphone hears the metronome itself, not just you.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var timingReadout: some View {
        VStack(spacing: 8) {
            if timingCoach.hearsMetronomeOverSpeaker {
                Label("Playing through the speaker — the reading counts the clicks too.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if let hit = timingCoach.lastHit {
                Text(deviationText(hit.deviationMs))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(hit.isOnTime ? Color.green : Color.orange)
                    .contentTransition(.numericText())
            } else {
                Text("Play along…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // The last few notes, oldest on the left.
            HStack(spacing: 5) {
                ForEach(timingCoach.hits) { hit in
                    Circle()
                        .fill(hit.isOnTime ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(height: 8)
            .animation(.easeOut(duration: 0.15), value: timingCoach.hits.count)

            if let accuracy = timingCoach.accuracy, let offset = timingCoach.averageOffsetMs {
                Text("\(Int((accuracy * 100).rounded()))% on the beat · \(tendencyText(offset))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "+18 ms · late" — sign included, so early/late is readable at a glance.
    private func deviationText(_ ms: Double) -> String {
        let value = Int(ms.rounded())
        let signed = value > 0 ? "+\(value)" : "\(value)"
        if abs(ms) <= TimingCoach.toleranceMs { return "\(signed) ms · on time" }
        return "\(signed) ms · \(value < 0 ? "early" : "late")"
    }

    /// The systematic part of the error, averaged over the recent notes.
    private func tendencyText(_ ms: Double) -> String {
        guard abs(ms) > 8 else { return "steady" }
        return ms < 0 ? "rushing by \(Int(-ms.rounded())) ms" : "dragging by \(Int(ms.rounded())) ms"
    }

    /// A groove other than `.basic` fixes its own bar length, so the time
    /// signature picker has nothing to say while one is selected.
    private var grooveOverridesTimeSignature: Bool {
        metronome.sound == .drums && metronome.groove.beats != nil
    }

    /// Horizontal chips of drum grooves. `Basic` follows the time signature
    /// picker; the others show the bar length they bring with them.
    private var groovePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DrumGroove.allCases) { g in
                    let selected = metronome.groove == g
                    let beats = g.beats ?? metronome.beatsPerMeasure
                    Button {
                        metronome.groove = g
                    } label: {
                        VStack(spacing: 1) {
                            Text(g.label).font(.subheadline.weight(.medium))
                            Text(beats == 1 ? "1/1" : "\(beats)/4")
                                .font(.caption2)
                                .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(selected ? Color.accentColor : Color.gray.opacity(0.18)))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    /// Beat dot color: the active beat lights up (first one red, others accent).
    /// In 1/1 the color doesn't change per beat — it stays constant while running.
    private func beatColor(_ i: Int) -> Color {
        if metronome.activeBeatsPerMeasure == 1 {
            return metronome.isRunning ? .accentColor : Color.gray.opacity(0.3)
        }
        if metronome.isRunning && i == metronome.currentBeat {
            return i == 0 ? .red : .accentColor
        }
        return Color.gray.opacity(0.3)
    }

    // MARK: - Tab: Tuner (guitar tuner)

    /// In tune when there is a signal and the deviation is less than 5 cents.
    private var tunerInTune: Bool { tuner.hasSignal && abs(tuner.cents) < 5 }

    private var tunerTab: some View {
        NavigationStack {
            VStack(spacing: 28) {
                // Tuning selection
                Picker("Tuning", selection: $tuner.tuning) {
                    ForEach(GuitarTuning.all) { Text($0.name).tag($0) }
                }
                .pickerStyle(.menu)

                Spacer()

                // Large note + deviation
                VStack(spacing: 4) {
                    Text(tuner.hasSignal ? tuner.noteNameWithOctave : "—")
                        .font(.system(size: 88, weight: .bold, design: .rounded))
                        .foregroundStyle(tunerInTune ? Color.green : .primary)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.12), value: tuner.midiNote)
                    Text(tuner.hasSignal
                         ? "\(tuner.cents >= 0 ? "+" : "")\(Int(tuner.cents.rounded())) c · \(Int(tuner.frequency.rounded())) Hz"
                         : "play a string")
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                centsMeter

                // Target strings (hidden in chromatic mode)
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
                    Text("Microphone access was denied. Enable it in Settings → Mazut → Microphone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Tuner")
            .onAppear { tuner.start() }
            .onDisappear { tuner.stop() }
        }
    }

    /// Horizontal cents meter: center = in tune, needle slides left/right.
    private var centsMeter: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = max(-1, min(1, tuner.cents / 50))   // −50…+50 c → −1…+1
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 6)
                    .frame(maxHeight: .infinity, alignment: .center)
                // Center mark
                Rectangle()
                    .fill(Color.secondary)
                    .frame(width: 2)
                    .position(x: w / 2, y: geo.size.height / 2)
                // Needle
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

    // MARK: - "Add to Playlist" (swipe right)

    private func addToPlaylistSheet(_ song: CachedSong) -> some View {
        NavigationStack {
            List {
                Section("New Playlist") {
                    HStack {
                        TextField("Name", text: $newPlaylistName)
                        Button("Add") {
                            let pl = createPlaylist(newPlaylistName)
                            addSong(song, to: pl)
                            songToAdd = nil
                        }
                        .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if !playlists.isEmpty {
                    Section("Existing") {
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
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { songToAdd = nil }
                }
            }
            .onAppear { newPlaylistName = "" }
        }
    }

    // MARK: - Playlist mutations

    @discardableResult
    private func createPlaylist(_ name: String) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let pl = Playlist(id: UUID().uuidString,
                          name: trimmed.isEmpty ? "Playlist" : trimmed,
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

    // MARK: - Player (shown while a song is loaded)

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
                        Label("Back", systemImage: "chevron.left")
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
                Text("Separating stems… \(Int(separator.progress * 100))%")
                    .font(.headline)
                    .foregroundStyle(.white)

                Button(role: .cancel) {
                    separationTask?.cancel()
                } label: {
                    Text("Cancel")
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

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Separate a song")
                .font(.title2.bold())
            Text("Choose an audio file. It's automatically separated into 6 stems: vocals, drums, bass, guitar, piano, other.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                showImporter = true
            } label: {
                Label("Separate a song", systemImage: "wand.and.stars")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)

            Button {
                openURL(downloadURL)
            } label: {
                Label("Download songs", systemImage: "globe")
                    .font(.subheadline)
            }
            Spacer()
        }
    }

    // MARK: - Library sorting

    /// Library ordered by the selected criterion.
    private var sortedLibrary: [CachedSong] {
        switch LibrarySort(rawValue: librarySortRaw) ?? .date {
        case .date:
            return library.sorted { $0.date > $1.date }          // newest first
        case .title:
            return library.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            return library.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .duration:
            return library.sorted { $0.duration < $1.duration }
        }
    }

    /// English plural for "song": 1 → song, otherwise → songs.
    private func songPlural(_ n: Int) -> String {
        n == 1 ? "song" : "songs"
    }

    // MARK: - Playback

    /// Load a cached song into the mixer without re-running separation.
    /// `queue` is the playback queue, `autoAdvance` whether to advance to the next
    /// song at the end, `autoPlay` whether playback starts immediately.
    private func openCached(_ song: CachedSong, queue: [CachedSong],
                            autoAdvance: Bool, autoPlay: Bool = false) {
        delayTask?.cancel()
        self.playQueue = queue
        self.autoAdvance = autoAdvance
        // Carry over settings (volume / mute / solo) from the previous song.
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
            engine.setNowPlaying(title: song.title, artist: song.artist,
                                 artworkURL: song.artworkURL)
            if autoPlay { engine.play() }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Advance to the next song (song ended naturally). If repeat is enabled,
    /// just restarts the same song from the beginning; otherwise picks the next one —
    /// random (shuffle) or in order, but only if auto-advance is enabled
    /// (i.e. playback started from a playlist) — shuffle bypasses that requirement.
    private func playNext() {
        if repeatEnabled {
            engine.seek(to: 0)
            engine.play()
            return
        }
        guard let next = nextSongForAdvance() else { return }
        guard playbackDelay > 0 else {
            openCached(next, queue: playQueue, autoAdvance: autoAdvance, autoPlay: true)
            return
        }
        // Pause between songs, then play the next one (unless the user interrupts).
        delayTask?.cancel()
        delayTask = Task {
            try? await Task.sleep(for: .seconds(playbackDelay))
            guard !Task.isCancelled else { return }
            openCached(next, queue: playQueue, autoAdvance: autoAdvance, autoPlay: true)
        }
    }

    /// Next song for auto-advance at the end of a song: random (shuffle, always
    /// available) or next in order (only when auto-advance is enabled).
    private func nextSongForAdvance() -> CachedSong? {
        guard let idx = currentQueueIndex else { return nil }
        if shuffleEnabled { return randomOtherSong(excluding: idx) }
        guard autoAdvance, idx + 1 < playQueue.count else { return nil }
        return playQueue[idx + 1]
    }

    /// Random song from the queue, different from the one at index `idx` (if there's more than one).
    private func randomOtherSong(excluding idx: Int) -> CachedSong? {
        let candidates = playQueue.indices.filter { $0 != idx }
        guard let j = candidates.randomElement() else { return nil }
        return playQueue[j]
    }

    /// Position of the current song in the playback queue.
    private var currentQueueIndex: Int? {
        guard let id = nowPlayingID else { return nil }
        return playQueue.firstIndex { $0.id == id }
    }

    private var canGoNext: Bool {
        guard let i = currentQueueIndex else { return false }
        if shuffleEnabled { return playQueue.count > 1 }
        return i + 1 < playQueue.count
    }

    /// Manual ("previous" button): first press rewinds to the start of the song; if ≤ 5s
    /// of playback have elapsed, moves to the previous song in the queue.
    private func playPrevious() {
        if engine.currentTime > 5 {
            engine.seek(to: 0)
            return
        }
        guard let i = currentQueueIndex, i > 0 else {
            engine.seek(to: 0)   // no previous song → just rewind to start
            return
        }
        openCached(playQueue[i - 1], queue: playQueue, autoAdvance: autoAdvance, autoPlay: true)
    }

    /// Manual (button) — next song in the queue (random if shuffle is enabled,
    /// otherwise in order); preserves the current advance mode.
    private func playNextManual() {
        guard let i = currentQueueIndex else { return }
        if shuffleEnabled {
            guard let next = randomOtherSong(excluding: i) else { return }
            openCached(next, queue: playQueue, autoAdvance: autoAdvance, autoPlay: true)
            return
        }
        guard i + 1 < playQueue.count else { return }
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

            HStack(spacing: 24) {
                Button {
                    shuffleEnabled.toggle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 18))
                        .foregroundStyle(shuffleEnabled ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)

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

                Button {
                    repeatEnabled.toggle()
                } label: {
                    Image(systemName: "repeat")
                        .font(.system(size: 18))
                        .foregroundStyle(repeatEnabled ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }

            metronomeBar
        }
        .padding()
    }

    /// Compact metronome bar below the transport buttons — on/off + tempo.
    /// The metronome plays over the song and keeps its state between songs in a playlist.
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

            // Live beat indicator.
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
        if metronome.activeBeatsPerMeasure > 1 && metronome.currentBeat == 0 { return .red }
        return .accentColor
    }

    // MARK: - Stems

    private var stemList: some View {
        List(stems) { stem in
            StemRow(stem: stem) {
                engine.applyMixToAllTracks()
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Import

    private func separateSong(_ url: URL) {
        guard let local = copyToTemp(url) else { loadError = "Can't load the file."; return }
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
                // Song key = the name of the folder containing the stems (content hash).
                nowPlayingID = map.values.first?.deletingLastPathComponent().lastPathComponent
                library = StemCache.library()   // the new song is now in the cache
                if let cached = library.first(where: { $0.id == nowPlayingID }) {
                    engine.setNowPlaying(title: cached.title, artist: cached.artist,
                                         artworkURL: cached.artworkURL)
                } else {
                    engine.setNowPlaying(title: nowPlayingTitle ?? "Mazut")
                }
            } catch is CancellationError {
                // The user cancelled — no error, just return to song selection.
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

// MARK: - Row for a single song (shared: library + playlists)

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

    /// Song thumbnail: embedded album art if present, otherwise a placeholder with a note icon.
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

    /// Subtitle: artist · duration · date (omits empty parts).
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

// MARK: - Playlist details

private struct PlaylistDetailView: View {
    let playlistID: String
    @Binding var playlists: [Playlist]
    let library: [CachedSong]
    /// (song, full queue, pause in seconds) → play the song with auto-advance to the next.
    let onPlay: (CachedSong, [CachedSong], Int) -> Void

    /// Offered pauses between songs (seconds).
    private let delayOptions = [0, 1, 2, 5, 10]

    private var playlist: Playlist? {
        playlists.first { $0.id == playlistID }
    }

    /// Playlist songs, in order; ones removed from the cache are skipped.
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
                    Text("Playlist is empty")
                        .font(.headline)
                    Text("Add songs by swiping right in the Songs tab.")
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
                            Text("Pause between songs: \(delay) s")
                        }
                    }
                }
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Pause between songs", selection: delayBinding) {
                        ForEach(delayOptions, id: \.self) { sec in
                            Text(sec == 0 ? "No pause" : "\(sec) s").tag(sec)
                        }
                    }
                } label: {
                    Label("Pause", systemImage: "timer")
                }
            }
            if !songs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
    }

    /// Binding to the playlist pause (reads from the model, writes and saves).
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

// MARK: - Row for a single stem

private struct StemRow: View {
    @Bindable var stem: Stem
    /// Call when any control changes so the engine refreshes the mix.
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: stem.kind.systemImage)
                    .foregroundStyle(stem.kind.color)
                Text(stem.displayName)
                    .font(.headline)
                if stem.url == nil {
                    Text("— empty")
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

// MARK: - Library sorting

/// Song list sort criterion.
private enum LibrarySort: String, CaseIterable, Identifiable {
    case date, title, artist, duration

    var id: String { rawValue }

    var label: String {
        switch self {
        case .date:     return "Date"
        case .title:    return "Title"
        case .artist:   return "Artist"
        case .duration: return "Duration"
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
