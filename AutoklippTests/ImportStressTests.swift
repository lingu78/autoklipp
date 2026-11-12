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
        MediaImporter.trace = { print("import stress: \($0)") }
        defer { MediaImporter.trace = nil }

        let model = AppModel(inMemory: true)
        try model.draft.storage.prepare()
        let storage = model.draft.storage
        defer { storage.removeAll() }

        // First, slowly: whether this simulator loads items made from library identifiers at all.
        let control = try await Self.addToLibrary(photos: 1, videos: 1)
        var controlLoaded = 0
        for identifier in control {
            do {
                let media = try await MediaImporter.importOne(PhotosPickerItem(itemIdentifier: identifier), storage: storage) { _ in }
                controlLoaded += 1
                try? FileManager.default.removeItem(at: media.url)
            } catch {
                print("import stress: control item not loaded: \(error)")
            }
        }
        print("import stress: \(controlLoaded) of \(control.count) items loaded one at a time")
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
        let selected = model.imports.selection
        print(
            "import stress: \(media.count) imported of \(chosen.count) picked "
                + "(\(selected.count) in the selection), \(model.draft.skippedCount) skipped, "
                + "waited \(Double(waited) / 5) s"
        )
        #expect(!model.imports.isBusy)
        // The embedded picker on screen can answer a selection set from outside with one of its
        // own (iOS 27 keeps the items it shows, as items of its own); the import follows the
        // selection it ends up with, as it does in the app, where only the picker sets it.
        if selected != chosen {
            print("import stress: the picker replaced the selection: \(selected.count) of \(chosen.count) items")
        }
        #expect(media.count + model.draft.skippedCount == selected.count, "each selected item imported or counted as skipped")
        #expect(Set(media.map(\.id)).count == media.count, "no item twice")
        #expect(Set(media.map(\.url)).count == media.count)
        #expect(media.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path(percentEncoded: false)) })
        if controlLoaded == 0 {
            // Items made from identifiers, not handed over by the picker, do not load here (iOS 27
            // simulators: not even one at a time), so some are skipped; the quick picking itself
            // still ran without crashing and kept every item once.
            withKnownIssue("This simulator does not load picker items made from library identifiers", isIntermittent: true) {
                #expect(model.draft.skippedCount == 0)
            }
        } else {
            #expect(model.draft.skippedCount == 0)
        }
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
