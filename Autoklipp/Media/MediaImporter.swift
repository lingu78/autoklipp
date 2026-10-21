import ClipCore
import CoreTransferable
import Foundation
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A file received from the picker, copied out of the system's temporary location.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try PickedFile(copying: received.file)
        }
        FileRepresentation(importedContentType: .image) { received in
            try PickedFile(copying: received.file)
        }
    }

    init(copying source: URL) throws {
        let folder = URL.temporaryDirectory.appending(path: "Picked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let extensionPart = source.pathExtension.isEmpty ? "" : ".\(source.pathExtension.lowercased())"
        let destination = folder.appending(path: UUID().uuidString + extensionPart)
        try FileManager.default.copyItem(at: source, to: destination)
        url = destination
    }
}

/// Progress of an import, shown while files are copied (and downloaded from iCloud).
@MainActor
@Observable
final class ImportProgress {
    var total = 0
    var finished = 0
    var isRunning = false
    /// Download progress 0...1 of the items still loading, by index.
    private var loading: [Int: Double] = [:]
    private var done: Set<Int> = []

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, (Double(finished) + loading.values.reduce(0, +)) / Double(total))
    }

    func start(total: Int) {
        self.total = total
        finished = 0
        loading = [:]
        done = []
        isRunning = true
    }

    func report(_ fraction: Double, for index: Int) {
        // Updates can arrive after their item has finished; it is already counted then.
        guard !done.contains(index) else { return }
        loading[index] = min(1, max(0, fraction))
    }

    func finish(_ index: Int) {
        guard done.insert(index).inserted else { return }
        loading[index] = nil
        finished += 1
    }
}

/// Copies picked items into the project and reads their metadata. Broken items are skipped.
enum MediaImporter {
    struct Result: Sendable {
        /// One entry per picked item, in the same order; nil where the item could not be used.
        var items: [ImportedMedia?]

        var media: [ImportedMedia] { items.compactMap { $0 } }
        var skipped: Int { items.filter { $0 == nil }.count }
    }

    /// Imports items in picker order, two at a time.
    @MainActor
    static func importItems(_ items: [PhotosPickerItem], storage: ProjectStorage, progress: ImportProgress) async -> Result {
        progress.start(total: items.count)
        defer { progress.isRunning = false }
        do {
            try storage.prepare()
        } catch {
            return Result(items: Array(repeating: nil, count: items.count))
        }

        var results = [ImportedMedia?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, ImportedMedia?).self) { group in
            var next = 0
            func enqueue() {
                guard next < items.count else { return }
                let index = next
                let item = items[index]
                next += 1
                group.addTask {
                    let imported = try? await importOne(item, storage: storage) { fraction in
                        Task { @MainActor in progress.report(fraction, for: index) }
                    }
                    return (index, imported)
                }
            }
            enqueue()
            enqueue()
            while let finishedItem = await group.next() {
                let (index, imported) = finishedItem
                results[index] = imported
                progress.finish(index)
                if Task.isCancelled { group.cancelAll() } else { enqueue() }
            }
        }
        return Result(items: results)
    }

    static func importOne(
        _ item: PhotosPickerItem, storage: ProjectStorage, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ImportedMedia {
        let types = item.supportedContentTypes
        let isVideo = types.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
        let isLive = !isVideo && types.contains { $0.conforms(to: .livePhoto) }
        guard let picked = try await load(item, onProgress: onProgress) else { throw MediaMetadataReader.ReadError.unreadableImage }

        let id = UUID().uuidString
        let extensionPart = picked.url.pathExtension.isEmpty ? (isVideo ? "mov" : "jpg") : picked.url.pathExtension
        let destination = storage.mediaDirectory.appending(path: "\(id).\(extensionPart)")
        do {
            try FileManager.default.moveItem(at: picked.url, to: destination)
        } catch {
            // The project folder can be gone (the draft was abandoned); the picked copy must not linger.
            try? FileManager.default.removeItem(at: picked.url)
            throw error
        }

        do {
            if isVideo {
                let info = try await MediaMetadataReader.readVideo(at: destination)
                guard info.duration > 0 else { throw MediaMetadataReader.ReadError.notPlayable }
                let media = MediaItem(
                    id: id, kind: .video, creationDate: info.date, duration: info.duration,
                    pixelWidth: info.width, pixelHeight: info.height, hasAudio: info.hasAudio, location: info.location
                )
                return ImportedMedia(item: media, url: destination)
            } else {
                let info = try MediaMetadataReader.readImage(at: destination)
                let media = MediaItem(
                    id: id, kind: isLive ? .livePhoto : .photo, creationDate: info.date,
                    pixelWidth: info.width, pixelHeight: info.height, location: info.location
                )
                return ImportedMedia(item: media, url: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Loads with the callback API, which reports progress (iCloud downloads can take a while).
    static func load(_ item: PhotosPickerItem, onProgress: @escaping @Sendable (Double) -> Void) async throws -> PickedFile? {
        let box = ObservationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let progress = item.loadTransferable(type: PickedFile.self) { result in
                    box.invalidate()
                    continuation.resume(with: result)
                }
                box.start(progress, onProgress: onProgress)
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Keeps a progress observation alive until the load finishes.
private final class ObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private var progress: Progress?

    func start(_ progress: Progress, onProgress: @escaping @Sendable (Double) -> Void) {
        lock.withLock {
            self.progress = progress
            observation = progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                onProgress(progress.fractionCompleted)
            }
        }
    }

    func invalidate() {
        lock.withLock {
            observation?.invalidate()
            observation = nil
        }
    }

    func cancel() {
        lock.withLock { progress }?.cancel()
    }
}
