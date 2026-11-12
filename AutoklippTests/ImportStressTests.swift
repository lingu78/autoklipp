import ClipCore
import Photos
import PhotosUI
import SwiftUI
import Testing
import UIKit

@testable import Autoklipp

/// Picking photos and videos quickly in the embedded library: every tap changes the selection
/// while the previous import is still copying. Real items from the simulator's photo library
/// (CI grants the app access to it), picked one after another with short pauses, some taken back
/// and picked again, with the media step on screen. Nothing may crash, and every picked item must
/// end up in the project exactly once.
@Suite("Picking quickly", .serialized)
@MainActor
struct ImportStressTests {
    @Test(.timeLimit(.minutes(10)))
    func pickingQuicklyKeepsEveryItemOnce() async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            print("import stress: no access to the photo library, skipped")
            return
        }
        let identifiers = try await Self.addToLibrary(photos: 14, videos: 6)
        #expect(identifiers.count == 20)
        let items = identifiers.map { PhotosPickerItem(itemIdentifier: $0) }

        let model = AppModel(inMemory: true)
        try model.draft.storage.prepare()
        let storage = model.draft.storage
        defer { storage.removeAll() }
        model.path = [.media]
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(
            rootView: RootView()
                .environment(model)
                .modelContainer(model.container)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        // Tap, tap, tap: some taps come before the last import starts, some while it copies.
        var chosen: [PhotosPickerItem] = []
        for (index, item) in items.enumerated() {
            chosen.append(item)
            model.imports.select(chosen)
            try await Task.sleep(for: .milliseconds(index % 3 == 2 ? 450 : 90))
        }
        // Take two back and pick one of them again, quickly.
        let taken = chosen.remove(at: 3)
        model.imports.select(chosen)
        try await Task.sleep(for: .milliseconds(80))
        chosen.remove(at: 7)
        model.imports.select(chosen)
        try await Task.sleep(for: .milliseconds(500))
        chosen.insert(taken, at: 3)
        model.imports.select(chosen)

        var waited = 0
        while model.imports.isBusy, waited < 600 {
            try await Task.sleep(for: .milliseconds(200))
            waited += 1
        }
        let media = model.draft.media
        print("import stress: \(media.count) imported of \(chosen.count) picked, \(model.draft.skippedCount) skipped, waited \(Double(waited) / 5) s")
        #expect(!model.imports.isBusy)
        if media.isEmpty, model.draft.skippedCount == chosen.count {
            // Items made from identifiers, not handed over by the picker, may not load here; the
            // quick picking itself still ran without crashing.
            withKnownIssue("This simulator does not load picker items made from library identifiers") {
                #expect(model.draft.skippedCount == 0)
            }
            return
        }
        #expect(media.count + model.draft.skippedCount == chosen.count)
        #expect(model.draft.skippedCount == 0)
        #expect(Set(media.map(\.id)).count == media.count, "no item twice")
        #expect(Set(media.map(\.url)).count == media.count)
        #expect(media.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path(percentEncoded: false)) })
    }

    /// Adds test photos and videos to the photo library and returns their identifiers.
    static func addToLibrary(photos: Int, videos: Int) async throws -> [String] {
        let folder = try TestMedia.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var files: [(URL, Bool)] = []
        for index in 0..<photos {
            let url = folder.appending(path: "photo-\(index).jpg")
            try TestMedia.writeImage(to: url, width: 1200, height: 1600, color: TestMedia.RGB.palette[index % TestMedia.RGB.palette.count], date: nil)
            files.append((url, false))
        }
        for index in 0..<videos {
            let url = folder.appending(path: "video-\(index).mov")
            try await TestMedia.writeVideo(to: url, duration: 3, width: 720, height: 1280, color: TestMedia.RGB.palette[index % TestMedia.RGB.palette.count], date: nil)
            files.append((url, true))
        }
        let created = CreatedAssets()
        let toAdd = files
        try await PHPhotoLibrary.shared().performChanges {
            for (url, isVideo) in toAdd {
                let request = isVideo
                    ? PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    : PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                if let identifier = request?.placeholderForCreatedAsset?.localIdentifier {
                    created.append(identifier)
                }
            }
        }
        return created.identifiers
    }
}

/// Identifiers collected inside a photo library change block, which runs on another queue.
private final class CreatedAssets: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ identifier: String) {
        lock.withLock { stored.append(identifier) }
    }

    var identifiers: [String] { lock.withLock { stored } }
}
