//
//  LearningView.swift
//  Mazut
//
//  "Learning" tab: user-organized, nestable folders of lesson items — local
//  videos, photos, documents, or YouTube links — with inline preview/playback.
//

import SwiftUI
import AVKit
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import QuickLookThumbnailing
#if canImport(UIKit)
import UIKit
import QuickLook
#elseif canImport(AppKit)
import AppKit
#endif

private func loadLocalImage(_ url: URL) -> Image? {
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

private func kindLabel(_ kind: LearningItemKind) -> String {
    switch kind {
    case .video: return "Video"
    case .image: return "Photo"
    case .document: return "Document"
    case .youtube: return "YouTube"
    }
}

private func kindSystemImage(_ kind: LearningItemKind) -> String {
    switch kind {
    case .video: return "video"
    case .image: return "photo"
    case .document: return "doc"
    case .youtube: return "play.rectangle"
    }
}

/// Wraps a video picked via PhotosPicker so it can be copied out of the
/// picker's sandboxed temporary location before the picker discards it.
private struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return Self(url: dest)
        }
    }
}

// MARK: - Tab: root of the folder tree

/// The Learning tab is just `LearningFolderView` rooted at the implicit
/// top-level folder (`path: []`) — the root behaves exactly like any other
/// folder (subfolders + items), so "add item" / "new folder" work the same
/// everywhere, including here.
struct LearningTab: View {
    @State private var root: LearningFolder = LearningFolder(id: LearningStore.rootID, name: "Learning")

    var body: some View {
        NavigationStack {
            ZStack {
                TabBackgroundView()
                LearningFolderView(path: [], root: $root)
            }
        }
        .onAppear { root = LearningStore.load() }
    }
}

// MARK: - Folder detail (subfolders + items) — recurses into itself

private struct LearningFolderView: View {
    /// Subfolder IDs from the root down to, and including, this folder. Empty = the root itself.
    let path: [String]
    @Binding var root: LearningFolder

    @State private var showNewSubfolderAlert = false
    @State private var newSubfolderName = ""

    @State private var pickedVideo: PhotosPickerItem?
    @State private var pickedImage: PhotosPickerItem?
    @State private var showVideoPicker = false
    @State private var showPhotoPicker = false
    @State private var showDocumentImporter = false
    @State private var showYouTubeAlert = false
    @State private var youtubeURLText = ""
    @State private var isImporting = false
    @State private var importError: String?
    @State private var playingClip: LearningClip?

    private var folder: LearningFolder? { LearningStore.folder(at: path, in: root) }
    private var subfolders: [LearningFolder] { folder?.subfolders ?? [] }
    private var clips: [LearningClip] { folder?.clips ?? [] }

    var body: some View {
        Group {
            if subfolders.isEmpty && clips.isEmpty {
                emptyState
            } else {
                List {
                    if !subfolders.isEmpty {
                        Section("Folders") {
                            ForEach(subfolders) { sub in
                                NavigationLink {
                                    LearningFolderView(path: path + [sub.id], root: $root)
                                } label: {
                                    subfolderRow(sub)
                                }
                            }
                            .onDelete(perform: deleteSubfolders)
                        }
                    }
                    if !clips.isEmpty {
                        Section("Items") {
                            ForEach(clips) { clip in
                                Button {
                                    playingClip = clip
                                } label: {
                                    clipRow(clip)
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete(perform: deleteClips)
                            .onMove(perform: moveClips)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(folder?.name ?? "Folder")
        .navigationBarTitleDisplayMode(path.isEmpty ? .large : .inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { addMenu }
            if !clips.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .alert("New Folder", isPresented: $showNewSubfolderAlert) {
            TextField("Name", text: $newSubfolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createSubfolder() }
        }
        // Triggered from `addMenu` via plain Buttons rather than embedding
        // PhotosPicker directly as a menu row: PhotosPicker nested two levels
        // deep inside a Menu-in-Menu silently fails to present on tap, so the
        // picker is presented via this boolean instead, fully decoupled from
        // the menu's own view hierarchy.
        .photosPicker(isPresented: $showVideoPicker, selection: $pickedVideo, matching: .videos)
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickedImage, matching: .images)
        .onChange(of: pickedVideo) { _, newValue in
            guard let newValue else { return }
            importVideo(newValue)
        }
        .onChange(of: pickedImage) { _, newValue in
            guard let newValue else { return }
            importImage(newValue)
        }
        .fileImporter(isPresented: $showDocumentImporter, allowedContentTypes: [.item],
                     allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { importDocument(url) }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert("Add from YouTube", isPresented: $showYouTubeAlert) {
            TextField("YouTube link", text: $youtubeURLText)
            Button("Cancel", role: .cancel) {}
            Button("Add") { addYouTube() }
        } message: {
            Text("Paste a link to a YouTube video.")
        }
        .alert("Error", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .sheet(item: $playingClip) { clip in
            ClipPreviewSheet(clip: clip) { newTitle in
                renameClip(clip, to: newTitle)
            }
        }
        .overlay {
            if isImporting {
                ProgressView("Importing…")
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button {
                newSubfolderName = ""
                showNewSubfolderAlert = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            Divider()
            Button { showVideoPicker = true } label: {
                Label("Video", systemImage: "video")
            }
            Button { showPhotoPicker = true } label: {
                Label("Photo", systemImage: "photo")
            }
            Button {
                showDocumentImporter = true
            } label: {
                Label("Document", systemImage: "doc")
            }
            Button {
                youtubeURLText = ""
                showYouTubeAlert = true
            } label: {
                Label("YouTube", systemImage: "play.rectangle")
            }
        } label: {
            Image(systemName: "plus")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: path.isEmpty ? "graduationcap" : "tray")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(path.isEmpty ? "Nothing here yet" : "Empty folder")
                .font(.headline)
            Text("Add a subfolder, or a video, photo, document, or YouTube link.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            addMenu
            Spacer()
        }
    }

    private func subfolderRow(_ sub: LearningFolder) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(sub.name).font(.body)
                Text(summary(sub))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ f: LearningFolder) -> String {
        var parts: [String] = []
        if !f.subfolders.isEmpty {
            parts.append("\(f.subfolders.count) \(f.subfolders.count == 1 ? "folder" : "folders")")
        }
        if !f.clips.isEmpty {
            parts.append("\(f.clips.count) \(f.clips.count == 1 ? "item" : "items")")
        }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }

    private func clipRow(_ clip: LearningClip) -> some View {
        HStack(spacing: 12) {
            clipThumbnail(clip)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Label(kindLabel(clip.kind), systemImage: kindSystemImage(clip.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func clipThumbnail(_ clip: LearningClip) -> some View {
        let side: CGFloat = 44
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            switch clip.source {
            case .youtube(let id):
                if let url = YouTube.thumbnailURL(for: id) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "play.rectangle").foregroundStyle(.secondary)
                        }
                    }
                }
            default:
                if let img = loadLocalImage(LearningStore.thumbnailURL(for: clip)) {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: kindSystemImage(clip.kind)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Folder actions

    private func createSubfolder() {
        let trimmed = newSubfolderName.trimmingCharacters(in: .whitespaces)
        let sub = LearningFolder(name: trimmed.isEmpty ? "Folder" : trimmed)
        LearningStore.mutate(at: path, in: &root) { $0.subfolders.append(sub) }
        LearningStore.save(root)
    }

    private func deleteSubfolders(_ offsets: IndexSet) {
        for i in offsets { LearningStore.deleteAllMedia(in: subfolders[i]) }
        LearningStore.mutate(at: path, in: &root) { $0.subfolders.remove(atOffsets: offsets) }
        LearningStore.save(root)
    }

    // MARK: - Adding items

    private func importVideo(_ item: PhotosPickerItem) {
        isImporting = true
        Task {
            defer { isImporting = false; pickedVideo = nil }
            do {
                guard let picked = try await item.loadTransferable(type: PickedVideo.self) else {
                    importError = "Couldn't load the video."
                    return
                }
                let clip = try LearningStore.importVideo(from: picked.url, title: "Video \(clips.count + 1)")
                try? FileManager.default.removeItem(at: picked.url)
                append(clip)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func importImage(_ item: PhotosPickerItem) {
        isImporting = true
        Task {
            defer { isImporting = false; pickedImage = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    importError = "Couldn't load the photo."
                    return
                }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let clip = try LearningStore.importImage(data: data, ext: ext, title: "Photo \(clips.count + 1)")
                append(clip)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func importDocument(_ url: URL) {
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                let clip = try LearningStore.importDocument(
                    from: url, title: url.deletingPathExtension().lastPathComponent)
                append(clip)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func addYouTube() {
        guard let id = YouTube.videoID(from: youtubeURLText) else {
            importError = "That doesn't look like a YouTube link."
            return
        }
        let clip = LearningClip(title: "YouTube Clip", source: .youtube(videoID: id))
        append(clip)

        // Best-effort: fill in the real title once it's fetched.
        Task {
            guard let title = await YouTube.fetchTitle(for: id) else { return }
            LearningStore.mutate(at: path, in: &root) { f in
                guard let idx = f.clips.firstIndex(where: { $0.id == clip.id }) else { return }
                f.clips[idx].title = title
            }
            LearningStore.save(root)
        }
    }

    private func append(_ clip: LearningClip) {
        LearningStore.mutate(at: path, in: &root) { $0.clips.append(clip) }
        LearningStore.save(root)
    }

    private func renameClip(_ clip: LearningClip, to newTitle: String) {
        LearningStore.mutate(at: path, in: &root) { f in
            guard let idx = f.clips.firstIndex(where: { $0.id == clip.id }) else { return }
            f.clips[idx].title = newTitle
        }
        LearningStore.save(root)
    }

    private func deleteClips(_ offsets: IndexSet) {
        let removed = offsets.map { clips[$0] }
        LearningStore.mutate(at: path, in: &root) { f in
            f.clips.removeAll { c in removed.contains { $0.id == c.id } }
        }
        for clip in removed { LearningStore.deleteMedia(for: clip) }
        LearningStore.save(root)
    }

    private func moveClips(from source: IndexSet, to destination: Int) {
        LearningStore.mutate(at: path, in: &root) { $0.clips.move(fromOffsets: source, toOffset: destination) }
        LearningStore.save(root)
    }
}

// MARK: - Preview / playback sheet

private struct ClipPreviewSheet: View {
    let clip: LearningClip
    let onRename: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var player: AVPlayer?
    @State private var title: String
    @State private var showRenameAlert = false
    @State private var editedTitle = ""

    init(clip: LearningClip, onRename: @escaping (String) -> Void) {
        self.clip = clip
        self.onRename = onRename
        _title = State(initialValue: clip.title)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch clip.source {
                case .youtube(let id):
                    VStack(spacing: 0) {
                        YouTubePlayerView(videoID: id)
                        // Some videos can't be embedded (disabled by the uploader,
                        // region locks…) regardless of player setup, so this is
                        // always offered as a guaranteed-to-work fallback.
                        Button {
                            if let url = URL(string: "https://www.youtube.com/watch?v=\(id)") {
                                openURL(url)
                            }
                        } label: {
                            Label("Open in YouTube", systemImage: "arrow.up.right.square")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                        .padding(12)
                    }
                case .video:
                    if let player {
                        VideoPlayer(player: player)
                            .onAppear { player.play() }
                    } else {
                        ProgressView()
                    }
                case .image:
                    if let url = LearningStore.mediaURL(for: clip), let img = loadLocalImage(url) {
                        ScrollView([.horizontal, .vertical]) {
                            img.resizable().scaledToFit()
                        }
                        .background(Color.black)
                    } else {
                        ContentUnavailableView("Couldn't load the photo", systemImage: "photo")
                    }
                case .document:
                    if let url = LearningStore.mediaURL(for: clip) {
                        DocumentPreview(url: url)
                    } else {
                        ContentUnavailableView("Couldn't load the document", systemImage: "doc")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editedTitle = title
                        showRenameAlert = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                }
            }
            .alert("Edit Title", isPresented: $showRenameAlert) {
                TextField("Title", text: $editedTitle)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let trimmed = editedTitle.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    title = trimmed
                    onRename(trimmed)
                }
            }
        }
        .onAppear {
            if case .video = clip.source, let url = LearningStore.mediaURL(for: clip) {
                player = AVPlayer(url: url)
            }
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - Document preview

#if canImport(UIKit)
private struct DocumentPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}
#elseif canImport(AppKit)
private struct DocumentPreview: View {
    let url: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.headline)
            Button("Open") { openURL(url) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
