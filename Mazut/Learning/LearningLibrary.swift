//
//  LearningLibrary.swift
//  Mazut
//
//  Model and on-disk storage for the Learning tab: user-created, nestable
//  folders holding items — local videos, photos, and documents copied into
//  the app's storage, or YouTube links referenced by video ID. Stored as
//  JSON + media files under MazutLearning/ — in the app's iCloud container when
//  the user is signed in to iCloud (synced across their devices), otherwise in
//  <Application Support>/. Separate from the stem cache.
//

import Foundation
import Observation
import os
import AVFoundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Where an item's file comes from.
nonisolated enum ClipSource: Codable, Hashable {
    case video(ext: String)      // file at LearningStore.mediaURL(for:)
    case image(ext: String)
    case document(ext: String)
    case youtube(videoID: String)
}

nonisolated enum LearningItemKind {
    case video, image, document, youtube
}

/// A single item inside a folder (video, photo, document, or YouTube link).
nonisolated struct LearningClip: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var title: String
    var source: ClipSource
    var dateAdded: Date = Date()

    var kind: LearningItemKind {
        switch source {
        case .video: return .video
        case .image: return .image
        case .document: return .document
        case .youtube: return .youtube
        }
    }
}

/// A folder grouping related items and, recursively, more folders
/// (e.g. "Scale lesson" containing a "Warm-ups" subfolder).
nonisolated struct LearningFolder: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var subfolders: [LearningFolder] = []
    var clips: [LearningClip] = []
    /// IDs of folders/items deleted anywhere in the tree (tombstones). Only used
    /// on the root, so merging an iCloud conflict version doesn't bring back
    /// items another device deleted (whose media files are already gone).
    var deletedIDs: Set<String> = []

    init(id: String = UUID().uuidString, name: String,
         subfolders: [LearningFolder] = [], clips: [LearningClip] = []) {
        self.id = id
        self.name = name
        self.subfolders = subfolders
        self.clips = clips
    }

    private enum CodingKeys: String, CodingKey { case id, name, subfolders, clips, deletedIDs }

    // Hand-written so indexes saved before `deletedIDs` existed still decode
    // (a decode failure moves folders.json aside).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        subfolders = try c.decodeIfPresent([LearningFolder].self, forKey: .subfolders) ?? []
        clips = try c.decodeIfPresent([LearningClip].self, forKey: .clips) ?? []
        deletedIDs = try c.decodeIfPresent(Set<String>.self, forKey: .deletedIDs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(subfolders, forKey: .subfolders)
        try c.encode(clips, forKey: .clips)
        if !deletedIDs.isEmpty { try c.encode(deletedIDs, forKey: .deletedIDs) }
    }

    /// IDs of this folder, its items and everything below it.
    var allIDs: [String] {
        [id] + clips.map(\.id) + subfolders.flatMap(\.allIDs)
    }
}

nonisolated enum LearningStore {

    // MARK: - Location (iCloud container or local fallback)

    /// Must match the container registered under Signing & Capabilities → iCloud.
    static let iCloudContainerID = "iCloud.com.tarmi.Mazut"

    private struct State {
        var prepared = false
        var cloudRoot: URL?
        var saveCount = 0
        /// Directories already created this launch — `root` and `mediaDirectory`
        /// are read per thumbnail row, and a createDirectory call per read is a
        /// filesystem round trip for nothing.
        var createdDirectories: Set<String> = []
    }

    private static let log = Logger(subsystem: "com.tarmi.Mazut", category: "learning")
    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Serial queue for all index I/O and the (blocking) container lookup, so
    /// coordinated reads/writes never run on the main thread and stay ordered.
    private static let io = DispatchQueue(label: "com.tarmi.Mazut.learning-io", qos: .userInitiated)

    /// <Application Support>/MazutLearning/ — used when iCloud is unavailable
    /// (signed out, capability missing) and as the source for the one-time migration.
    private static var localRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MazutLearning", isDirectory: true)
    }

    /// <iCloud container>/MazutLearning/ once `prepare()` found the container, else the local root.
    private static var root: URL {
        ensureDirectory(state.withLock { $0.cloudRoot } ?? localRoot)
    }

    private static func ensureDirectory(_ dir: URL) -> URL {
        let isNew = state.withLock { $0.createdDirectories.insert(dir.path).inserted }
        if isNew { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        return dir
    }

    /// True when folders and media live in (and sync through) iCloud.
    static var isUsingICloud: Bool { state.withLock { $0.cloudRoot != nil } }

    private static var indexURL: URL { root.appendingPathComponent("folders.json") }

    /// Local files and generated thumbnails.
    static var mediaDirectory: URL {
        ensureDirectory(root.appendingPathComponent("Media", isDirectory: true))
    }

    /// The id of the implicit top-level folder — never shown as a row, just the
    /// container for whatever lives at the root of the Learning tab.
    static let rootID = "root"

    /// Resolve the iCloud container and move any local library into it. Must run
    /// (and finish) before the first `load()`; cheap no-op after the first call.
    static func prepare() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            io.async {
                prepareOnIOQueue()
                cont.resume()
            }
        }
    }

    private static func prepareOnIOQueue() {
        guard !state.withLock({ $0.prepared }) else { return }
        defer { state.withLock { $0.prepared = true } }

        let fm = FileManager.default
        // `url(forUbiquityContainerIdentifier:)` returns nil when signed out of
        // iCloud or when the app lacks the iCloud entitlement → stay local.
        guard fm.ubiquityIdentityToken != nil,
              let container = fm.url(forUbiquityContainerIdentifier: iCloudContainerID)
        else { return }

        let cloudRoot = container.appendingPathComponent("MazutLearning", isDirectory: true)
        try? fm.createDirectory(at: cloudRoot.appendingPathComponent("Media", isDirectory: true),
                                withIntermediateDirectories: true)

        // If a local library exists but can't be merged yet (cloud index not
        // downloadable, e.g. offline), keep using local storage this launch and
        // retry on the next one rather than hiding the user's local items.
        guard migrateLocalLibrary(into: cloudRoot) else { return }
        state.withLock { $0.cloudRoot = cloudRoot }
    }

    /// Moves `<Application Support>/MazutLearning` into the iCloud container,
    /// merging with whatever is already there (another device's library).
    /// Returns false if the migration has to be postponed.
    private static func migrateLocalLibrary(into cloudRoot: URL) -> Bool {
        let fm = FileManager.default
        let localIndex = localRoot.appendingPathComponent("folders.json")
        guard fm.fileExists(atPath: localIndex.path) else { return true }   // nothing to migrate

        guard let localData = try? Data(contentsOf: localIndex),
              let localTree = try? JSONDecoder().decode(LearningFolder.self, from: localData)
        else {
            // Unreadable local index: leave it in place (load() never touches it
            // once we're on iCloud) instead of risking anything.
            return true
        }

        let cloudIndex = cloudRoot.appendingPathComponent("folders.json")
        var merged: LearningFolder
        if itemExists(cloudIndex) {
            // Another device already uploaded a library: we must read it before
            // writing ours, or we'd overwrite it.
            guard waitUntilDownloaded(cloudIndex, timeout: 20, acceptStale: false),
                  case .ok(let cloudTree) = readIndexFile(at: cloudIndex)
            else { return false }
            merged = cloudTree
        } else {
            merged = LearningFolder(id: rootID, name: "Learning")
        }
        merge(localTree, into: &merged)

        // All or nothing. Media goes up as *copies*, so the local library stays
        // whole until the very end: if any file or the index fails, this launch
        // stays local with nothing missing and the next one retries. (Moving the
        // originals left the local index pointing at files no longer there, and
        // writing the cloud index after a failed file made every device wait
        // for a file that never arrives.)
        let localMedia = localRoot.appendingPathComponent("Media", isDirectory: true)
        let cloudMedia = cloudRoot.appendingPathComponent("Media", isDirectory: true)
        let staging = localRoot.appendingPathComponent("Migrating", isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let files = (try? fm.contentsOfDirectory(at: localMedia, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            let dest = cloudMedia.appendingPathComponent(file.lastPathComponent)
            // UUID-named, so an existing item is this very file from an
            // earlier, interrupted migration.
            guard !itemExists(dest) else { continue }
            let copy = staging.appendingPathComponent(file.lastPathComponent)
            do {
                try? fm.removeItem(at: copy)
                try fm.copyItem(at: file, to: copy)
                try fm.setUbiquitous(true, itemAt: copy, destinationURL: dest)
            } catch {
                log.error("Learning migration: couldn't copy \(file.lastPathComponent, privacy: .public) to iCloud: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }

        guard (try? writeIndexFile(merged, to: cloudIndex)) != nil else { return false }
        // Everything is in iCloud now; only then does the local copy go.
        for file in files { try? fm.removeItem(at: file) }
        try? fm.removeItem(at: localIndex)
        return true
    }

    // MARK: - Index (folders.json)

    enum LoadResult {
        case loaded(LearningFolder)
        /// The index exists but can't be read right now (still downloading from
        /// iCloud, or a transient read error). The caller must NOT let the user
        /// edit, or the next save() would replace the real library with a stub.
        case unavailable
    }

    /// Read the folder tree. Call after `prepare()`. Runs on the I/O queue; when
    /// the index lives in iCloud and isn't downloaded yet, waits briefly for it.
    static func load() async -> LoadResult {
        await withCheckedContinuation { (cont: CheckedContinuation<LoadResult, Never>) in
            io.async { cont.resume(returning: loadOnIOQueue()) }
        }
    }

    private static func loadOnIOQueue() -> LoadResult {
        let empty = LearningFolder(id: rootID, name: "Learning")
        let url = indexURL
        guard itemExists(url) else { return .loaded(empty) }

        // Not downloaded yet (fresh device / offline with no local copy). The
        // sync watcher triggers another load() once the file arrives, so this
        // only waits briefly: every second spent here holds up saves queued
        // behind it. An older local copy is used straight away for the same
        // reason — a newer one arriving is itself a change that reloads.
        guard waitUntilDownloaded(url, timeout: 3, acceptStale: true) else { return .unavailable }

        var tree: LearningFolder
        switch readIndexFile(at: url) {
        case .ok(let t):
            tree = t
        case .readFailed:
            return .unavailable
        case .decodeFailed:
            // The file was read but doesn't match the current shape (e.g. an old
            // format from before a schema change). Rather than letting the next
            // save() overwrite — and lose — it, move it aside so it can be
            // recovered by hand if needed.
            let backup = root.appendingPathComponent("folders-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            coordinate(writingAt: url, options: .forMoving) { try FileManager.default.moveItem(at: $0, to: backup) }
            return .loaded(empty)
        }

        if resolveConflicts(at: url, into: &tree) {
            try? writeIndexFile(tree, to: url)
        }
        requestThumbnailDownloads(in: tree)
        return .loaded(tree)
    }

    /// Incremented (on the caller's thread) by every `save()`. A `load()` that
    /// overlapped a save may return the tree from before it, so callers compare
    /// this before/after loading and drop such results.
    static var saveCount: Int { state.withLock { $0.saveCount } }

    static func save(_ root: LearningFolder) {
        state.withLock { $0.saveCount += 1 }
        guard let data = try? JSONEncoder().encode(root) else { return }
        // URL resolved on the queue, so a save issued while prepare() is still
        // running lands in the final (cloud) location, not the old local one.
        io.async {
            coordinate(writingAt: indexURL, options: .forReplacing) { try data.write(to: $0, options: .atomic) }
        }
    }

    private enum IndexRead {
        case ok(LearningFolder)
        case readFailed     // coordination or I/O error — may be transient
        case decodeFailed   // read fine, but not a valid index
    }

    private static func readIndexFile(at url: URL) -> IndexRead {
        var data: Data?
        coordinate(readingAt: url) { data = try Data(contentsOf: $0) }
        guard let data else { return .readFailed }
        guard let tree = try? JSONDecoder().decode(LearningFolder.self, from: data) else { return .decodeFailed }
        return .ok(tree)
    }

    private static func writeIndexFile(_ tree: LearningFolder, to url: URL) throws {
        let data = try JSONEncoder().encode(tree)
        var writeError: Error?
        coordinate(writingAt: url, options: .forReplacing) {
            do { try data.write(to: $0, options: .atomic) } catch { writeError = error; throw error }
        }
        if let writeError { throw writeError }
    }

    /// iCloud keeps both copies when two devices edit `folders.json` before
    /// syncing. Union-merge them (by id) so nothing added on either device is
    /// lost; deletions win via the root's `deletedIDs` tombstones.
    /// Returns true if `tree` changed.
    private static func resolveConflicts(at url: URL, into tree: inout LearningFolder) -> Bool {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
              !conflicts.isEmpty
        else { return false }
        for version in conflicts {
            if let data = try? Data(contentsOf: version.url),
               let other = try? JSONDecoder().decode(LearningFolder.self, from: data) {
                merge(other, into: &tree)
            }
            version.isResolved = true
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        return true
    }

    /// Merges two whole trees (roots): adds every folder/item from `other` that
    /// `target` doesn't have (matched by id), then drops anything either side
    /// has deleted.
    static func merge(_ other: LearningFolder, into target: inout LearningFolder) {
        target.deletedIDs.formUnion(other.deletedIDs)
        addMissing(from: other, into: &target, skipping: target.deletedIDs)
        prune(&target, removing: target.deletedIDs)
    }

    private static func addMissing(from other: LearningFolder, into target: inout LearningFolder,
                                   skipping deleted: Set<String>) {
        for clip in other.clips
        where !deleted.contains(clip.id) && !target.clips.contains(where: { $0.id == clip.id }) {
            target.clips.append(clip)
        }
        for sub in other.subfolders where !deleted.contains(sub.id) {
            if let idx = target.subfolders.firstIndex(where: { $0.id == sub.id }) {
                addMissing(from: sub, into: &target.subfolders[idx], skipping: deleted)
            } else {
                target.subfolders.append(sub)
            }
        }
    }

    private static func prune(_ folder: inout LearningFolder, removing deleted: Set<String>) {
        guard !deleted.isEmpty else { return }
        folder.clips.removeAll { deleted.contains($0.id) }
        folder.subfolders.removeAll { deleted.contains($0.id) }
        for i in folder.subfolders.indices { prune(&folder.subfolders[i], removing: deleted) }
    }

    // MARK: - Folder tree navigation

    /// Walk `path` (a list of subfolder IDs starting from `root`; empty = the
    /// root itself) and return that folder, or nil if the path no longer
    /// resolves (e.g. an ancestor was deleted elsewhere).
    static func folder(at path: [String], in root: LearningFolder) -> LearningFolder? {
        var current = root
        for id in path {
            guard let next = current.subfolders.first(where: { $0.id == id }) else { return nil }
            current = next
        }
        return current
    }

    /// Mutate the folder at `path` in place, then let the caller persist the result.
    static func mutate(at path: [String], in root: inout LearningFolder,
                       _ body: (inout LearningFolder) -> Void) {
        guard let first = path.first else { body(&root); return }
        guard let idx = root.subfolders.firstIndex(where: { $0.id == first }) else { return }
        mutate(at: Array(path.dropFirst()), in: &root.subfolders[idx], body)
    }

    // MARK: - Media files

    /// Local file for a video/image/document item, nil for YouTube items.
    static func mediaURL(for clip: LearningClip) -> URL? {
        switch clip.source {
        case .video(let ext), .image(let ext), .document(let ext):
            return mediaDirectory.appendingPathComponent("\(clip.id).\(ext)")
        case .youtube:
            return nil
        }
    }

    /// Cached poster/preview image for a locally stored item.
    static func thumbnailURL(for clip: LearningClip) -> URL {
        mediaDirectory.appendingPathComponent("\(clip.id)_thumb.jpg")
    }

    static func importVideo(from sourceURL: URL, title: String) throws -> LearningClip {
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let clip = LearningClip(title: title, source: .video(ext: ext))
        try copyIntoMedia(sourceURL, to: clip.id, ext: ext)
        generateVideoThumbnail(for: clip)
        return clip
    }

    static func importImage(data: Data, ext: String, title: String) throws -> LearningClip {
        let clip = LearningClip(title: title, source: .image(ext: ext))
        let dest = mediaDirectory.appendingPathComponent("\(clip.id).\(ext)")
        try coordinatedWrite(to: dest) { try data.write(to: $0) }
        generateImageThumbnail(for: clip)
        return clip
    }

    static func importDocument(from sourceURL: URL, title: String) throws -> LearningClip {
        let ext = sourceURL.pathExtension.isEmpty ? "dat" : sourceURL.pathExtension
        let clip = LearningClip(title: title, source: .document(ext: ext))
        try copyIntoMedia(sourceURL, to: clip.id, ext: ext)
        generateDocumentThumbnail(for: clip)
        return clip
    }

    private static func copyIntoMedia(_ source: URL, to id: String, ext: String) throws {
        let needsScope = source.startAccessingSecurityScopedResource()
        defer { if needsScope { source.stopAccessingSecurityScopedResource() } }
        let dest = mediaDirectory.appendingPathComponent("\(id).\(ext)")
        try coordinatedWrite(to: dest) { url in
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: source, to: url)
        }
    }

    /// Poster frame for a video clip (best-effort, ignored on failure).
    private static func generateVideoThumbnail(for clip: LearningClip) {
        guard let url = mediaURL(for: clip) else { return }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        guard let cgImage = try? generator.copyCGImage(
            at: CMTime(seconds: 0.5, preferredTimescale: 60), actualTime: nil)
        else { return }
        writeThumbnail(cgImage, for: clip)
    }

    /// Down-sampled thumbnail for a photo (best-effort, ignored on failure).
    private static func generateImageThumbnail(for clip: LearningClip) {
        guard let url = mediaURL(for: clip),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return }
        writeThumbnail(thumb, for: clip)
    }

    /// QuickLook-rendered thumbnail for an arbitrary document (PDF, Word, etc.), async
    /// since QLThumbnailGenerator has no synchronous API; best-effort, ignored on failure.
    private static func generateDocumentThumbnail(for clip: LearningClip) {
        guard let url = mediaURL(for: clip) else { return }
        let size = CGSize(width: 240, height: 240)
        // A fixed 3x scale (typical Retina density) avoids touching the
        // main-actor-isolated `UIScreen` from this nonisolated context.
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size,
                                                    scale: 3, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let cgImage = representation?.cgImage else { return }
            writeThumbnail(cgImage, for: clip)
        }
    }

    private static func writeThumbnail(_ cgImage: CGImage, for clip: LearningClip) {
        try? coordinatedWrite(to: thumbnailURL(for: clip)) { url in
            guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(dest, cgImage, nil)
            CGImageDestinationFinalize(dest)
        }
    }

    /// Remove an item's media + thumbnail from disk (YouTube items have neither, so this is a no-op for them).
    static func deleteMedia(for clip: LearningClip) {
        let urls = [mediaURL(for: clip), thumbnailURL(for: clip)].compactMap { $0 }
        io.async {
            for url in urls {
                coordinate(writingAt: url, options: .forDeleting) { try FileManager.default.removeItem(at: $0) }
            }
        }
    }

    /// Remove media for every item in a folder and, recursively, its subfolders
    /// (used when deleting a folder).
    static func deleteAllMedia(in folder: LearningFolder) {
        for clip in folder.clips { deleteMedia(for: clip) }
        for sub in folder.subfolders { deleteAllMedia(in: sub) }
    }

    // MARK: - iCloud download state

    enum MediaError: LocalizedError {
        case missing
        case stalled
        var errorDescription: String? {
            switch self {
            case .missing: return "The file isn't available on this device or in iCloud."
            case .stalled: return "Couldn't download the file from iCloud. Check your connection and open it again."
            }
        }
    }

    /// A download that hasn't grown in this long is not coming (offline,
    /// iCloud throttled). Long enough for a slow connection to show progress.
    private static let downloadStallTimeout: TimeInterval = 60

    /// Make sure a media file is fully present locally, downloading it from
    /// iCloud if needed. Returns immediately for local (non-iCloud) files.
    /// Cancellable: stops waiting when the calling task is cancelled.
    static func ensureDownloaded(_ url: URL) async throws {
        var missingSince: Date?
        // Progress is judged by the bytes on disk, not by elapsed time: a big
        // video on a slow line may take minutes and still be fine.
        var lastSize: Int64 = -1
        var lastProgress = Date()
        while true {
            try Task.checkCancellation()
            switch downloadState(of: url) {
            case .ready, .stale:
                // Media files are write-once (UUID-named), so an older local
                // copy is the same file — no need to wait for iCloud.
                return
            case .failed(let error):
                throw error
            case .downloading:
                missingSince = nil
                let size = downloadedBytes(of: url)
                if size != lastSize {
                    lastSize = size
                    lastProgress = Date()
                } else if Date().timeIntervalSince(lastProgress) > downloadStallTimeout {
                    throw MediaError.stalled
                }
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            case .missing:
                // On a fresh device the index can arrive before the media's
                // metadata does; give iCloud a while before giving up.
                guard isUsingICloud else { throw MediaError.missing }
                let since = missingSince ?? Date()
                missingSince = since
                if Date().timeIntervalSince(since) > 30 { throw MediaError.missing }
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    /// Bytes of `url` present locally so far (0 for a placeholder).
    private static func downloadedBytes(of url: URL) -> Int64 {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }

    private enum DownloadState {
        case ready, stale, downloading, missing
        case failed(Error)
    }

    private static func downloadState(of url: URL) -> DownloadState {
        var url = url
        url.removeAllCachedResourceValues()   // otherwise the status never changes between polls
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey,
                                         .ubiquitousItemDownloadingStatusKey,
                                         .ubiquitousItemDownloadingErrorKey]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            // Older OSes represent a not-yet-downloaded file as a hidden
            // ".<name>.icloud" placeholder next to it.
            return FileManager.default.fileExists(atPath: placeholderURL(for: url).path) ? .downloading : .missing
        }
        guard values.isUbiquitousItem == true else {
            return FileManager.default.fileExists(atPath: url.path) ? .ready : .missing
        }
        if let error = values.ubiquitousItemDownloadingError { return .failed(error) }
        switch values.ubiquitousItemDownloadingStatus {
        case .current?: return .ready
        // A local copy exists, but iCloud may have a newer one (e.g. offline).
        case .downloaded?: return .stale
        default: return .downloading
        }
    }

    /// Blocking variant of `ensureDownloaded` for the I/O queue. Returns false
    /// only when nothing readable is on disk. With `acceptStale` an older local
    /// copy is good enough at once; without it (the migration, which must not
    /// overwrite a newer library) it waits for the latest version and falls
    /// back to the local copy only on timeout.
    private static func waitUntilDownloaded(_ url: URL, timeout: TimeInterval, acceptStale: Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch downloadState(of: url) {
            case .ready: return true
            case .failed: return false
            case .stale:
                guard !acceptStale, Date() < deadline else { return true }
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                Thread.sleep(forTimeInterval: 0.25)
            case .downloading, .missing:
                guard Date() < deadline else { return false }
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }

    /// Thumbnails are tiny, so fetch them all eagerly once the index is known;
    /// the sync watcher refreshes the list as they arrive.
    private static func requestThumbnailDownloads(in folder: LearningFolder) {
        guard isUsingICloud else { return }
        for clip in folder.clips where clip.kind != .youtube {
            try? FileManager.default.startDownloadingUbiquitousItem(at: thumbnailURL(for: clip))
        }
        for sub in folder.subfolders { requestThumbnailDownloads(in: sub) }
    }

    private static func itemExists(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path) || fm.fileExists(atPath: placeholderURL(for: url).path)
    }

    private static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    // MARK: - File coordination

    // Every access to files in the iCloud container goes through
    // NSFileCoordinator so it can't collide with the sync daemon. Harmless
    // (and cheap) for local files too.

    private static func coordinate(readingAt url: URL, _ body: (URL) throws -> Void) {
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { url in
            try? body(url)
        }
    }

    private static func coordinate(writingAt url: URL, options: NSFileCoordinator.WritingOptions,
                                   _ body: (URL) throws -> Void) {
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options, error: &error) { url in
            try? body(url)
        }
    }

    /// Coordinated write that propagates both coordination and body errors.
    private static func coordinatedWrite(to url: URL, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError
        ) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError { throw error }
    }
}

// MARK: - iCloud change watcher

/// Watches the index and the thumbnails in the app's iCloud container.
/// `indexRevision` bumps when folders.json changed (another device edited the
/// library) and the Learning tab reloads on it; `revision` bumps on any watched
/// change, and thumbnails read it so they redraw as they arrive. Media files
/// are not watched: a downloading video reports progress dozens of times, and
/// the player polls its own download (`LearningStore.ensureDownloaded`).
@MainActor
@Observable
final class LearningSync {
    private(set) var revision = 0
    private(set) var indexRevision = 0

    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pendingBump: Task<Void, Never>?
    @ObservationIgnored private var pendingIndexChange = false

    /// Start watching (no-op when not on iCloud or already started). Call after `LearningStore.prepare()`.
    func start() {
        guard query == nil, LearningStore.isUsingICloud else { return }
        let query = NSMetadataQuery()
        // Files outside the container's Documents/ folder live in the data scope.
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        query.predicate = NSPredicate(format: "%K == %@ OR %K LIKE '*_thumb.jpg'",
                                      NSMetadataItemFSNameKey, Self.indexName, NSMetadataItemFSNameKey)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                            object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleBump(indexChanged: true) }
        })
        observers.append(center.addObserver(forName: .NSMetadataQueryDidUpdate,
                                            object: query, queue: .main) { [weak self] note in
            let indexChanged = Self.touchesIndex(note)
            MainActor.assumeIsolated { self?.scheduleBump(indexChanged: indexChanged) }
        })
        self.query = query
        query.start()
    }

    /// Downloads report progress in many small updates; coalesce them so the
    /// index isn't re-read dozens of times per second.
    private func scheduleBump(indexChanged: Bool) {
        pendingIndexChange = pendingIndexChange || indexChanged
        pendingBump?.cancel()
        pendingBump = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.revision += 1
            if self.pendingIndexChange {
                self.pendingIndexChange = false
                self.indexRevision += 1
            }
        }
    }

    private static let indexName = "folders.json"

    /// Whether an update notification includes folders.json.
    nonisolated private static func touchesIndex(_ note: Notification) -> Bool {
        let keys = [NSMetadataQueryUpdateAddedItemsKey, NSMetadataQueryUpdateChangedItemsKey,
                    NSMetadataQueryUpdateRemovedItemsKey]
        return keys.contains { key in
            (note.userInfo?[key] as? [NSMetadataItem])?.contains {
                $0.value(forAttribute: NSMetadataItemFSNameKey) as? String == indexName
            } ?? false
        }
    }
}

// MARK: - YouTube helpers

/// No API key / SDK — just URL parsing and the public oEmbed + thumbnail
/// endpoints. Playback itself is done by embedding the standard YouTube
/// iframe player (see YouTubePlayerView), since there is no way to obtain a
/// directly playable video URL without violating YouTube's terms.
nonisolated enum YouTube {

    /// Extract the video ID from any common YouTube URL shape, or a bare ID.
    static func videoID(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.range(of: #"^[\w-]{11}$"#, options: .regularExpression) != nil {
            return trimmed
        }
        guard let comps = URLComponents(string: trimmed) else { return nil }
        let host = comps.host?.lowercased() ?? ""

        if host.contains("youtu.be") {
            let id = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }
        if host.contains("youtube.com") {
            if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value { return v }
            let parts = comps.path.split(separator: "/").map(String.init)
            if let idx = parts.firstIndex(where: { $0 == "shorts" || $0 == "embed" || $0 == "live" }),
               idx + 1 < parts.count {
                return parts[idx + 1]
            }
        }
        return nil
    }

    /// Public thumbnail image for a video ID (no API key needed).
    static func thumbnailURL(for videoID: String) -> URL? {
        URL(string: "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg")
    }

    /// Best-effort title lookup via the public oEmbed endpoint. Returns nil on any failure.
    static func fetchTitle(for videoID: String) async -> String? {
        var comps = URLComponents(string: "https://www.youtube.com/oembed")!
        comps.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = comps.url else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["title"] as? String
    }
}
