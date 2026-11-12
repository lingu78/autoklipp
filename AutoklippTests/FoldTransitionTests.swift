import AVFoundation
import ClipCore
import SwiftUI
import Testing
import UIKit

@testable import Autoklipp

/// iPhone Duo: folding and unfolding resize the app's window between the outer and the inner
/// display. These tests host the app's root view in a window, resize it the same way, and check
/// that the layout changes while the film keeps playing and nothing open is lost.
///
/// The sizes are those of the iPhone Duo simulator's two screens. Windows are hosted on the
/// screen the tests run on, so on iPhone Duo's outer display the system's side bar sits at that
/// screen's edge, inside a larger window.
@Suite("iPhone Duo – folding and unfolding", .serialized)
@MainActor
struct FoldTransitionTests {
    // The iPhone Duo simulator's screens: 1398 × 2034 and 2007 × 2853 pixels at 3x.
    static let outer = Display(name: "outer", size: CGSize(width: 466, height: 678), regular: false)
    static let inner = Display(name: "inner", size: CGSize(width: 951, height: 669), regular: true)
    static let innerUpright = Display(name: "inner-upright", size: CGSize(width: 669, height: 951), regular: true)
    /// The inner display shared with another app in Split View.
    static let splitView = Display(name: "split-view", size: CGSize(width: 470, height: 669), regular: true)

    struct Display {
        let name: String
        let size: CGSize
        let regular: Bool
    }

    @Test(.timeLimit(.minutes(10)))
    func unfoldingKeepsTheFilmPlayingAndTheExportOpen() async throws {
        logScreens()
        let showsVideo = try await DisplayCheck.videoShowsOnScreen()
        let model = try await AdjustmentTests().preparedModel()
        let storage = model.draft.storage
        defer { storage.removeAll() }
        let session = try #require(model.preview)
        // Where the system cannot show the film, the session moves it to a player of its own.
        var player: AVPlayer { session.player }
        model.path = [.media, .length, .style, .preview]

        let window = try host(model, on: Self.outer)
        defer { close(window, model) }
        try await settle()
        #expect(model.layout == .stack)
        session.play()
        try await Task.sleep(for: .seconds(1))
        print("playback before unfolding: \(Self.describe(player)), draws frames itself: \(session.drawsFramesItself)")
        #expect(player.rate > 0)
        await snapshot(window, "duo-outer-preview")

        // Unfold: two columns, the same step, and the film plays on.
        let beforeUnfolding = player.currentTime().seconds
        print("playback at unfolding: \(beforeUnfolding) s")
        resize(window, to: Self.inner)
        try await settle()
        #expect(model.layout == .columns)
        #expect(model.path == [.media, .length, .style, .preview])
        #expect(model.activeStep == .generate)
        #expect(window.rootViewController?.presentedViewController == nil)
        print("playback after unfolding: \(Self.describe(player)), draws frames itself: \(session.drawsFramesItself)")
        #expect(model.preview === session)
        #expect(player.rate > 0, "playback carries on through the change of layout")
        if showsVideo {
            #expect(player.currentTime().seconds > beforeUnfolding)
        } else {
            withKnownIssue("This simulator shows no video on screen, not even a plain file", isIntermittent: true) {
                #expect(player.currentTime().seconds > beforeUnfolding)
            }
        }
        await snapshot(window, "duo-inner-preview")

        // The export opened on the inner display is still open, with its choices, once folded.
        model.show(.export)
        let job = try #require(model.export)
        job.format = .square
        try await settle()
        await snapshot(window, "duo-inner-export")
        resize(window, to: Self.outer)
        try await settle()
        #expect(model.layout == .stack)
        #expect(model.sheet == .export)
        #expect(model.export === job)
        #expect(job.format == .square)
        #expect(window.rootViewController?.presentedViewController != nil, "the export shows as a sheet on the phone layout")
        await snapshot(window, "duo-outer-export")

        // And back: the sheet's state shows as the export step again.
        resize(window, to: Self.inner)
        try await settle()
        #expect(model.activeStep == .export)
        #expect(model.export === job)
        #expect(window.rootViewController?.presentedViewController == nil, "and as a step, not a sheet, in two columns")
        model.closeExport()

        // Text being typed in the sheet survives the sheet going away with the layout.
        model.openTexts()
        model.texts?.title = "Midsommar"
        try await settle()
        resize(window, to: Self.outer)
        try await settle()
        #expect(model.sheet == .texts)
        #expect(model.texts?.title == "Midsommar")
        #expect(window.rootViewController?.presentedViewController != nil, "the texts sheet comes back in the other layout")
        model.closeTexts(saving: false)
        #expect(model.draft.title != "Midsommar")
    }

    @Test(.timeLimit(.minutes(10)))
    func aFilmBeingMadeCarriesOnThroughFolding() async throws {
        let model = try await AdjustmentTests().preparedModel()
        let storage = model.draft.storage
        defer { storage.removeAll() }
        let shown = try #require(model.preview)
        model.path = [.media, .length, .style, .preview]
        let window = try host(model, on: Self.outer)
        defer { close(window, model) }
        try await settle()

        // Without the analyses kept from the first film the run takes several seconds, so the
        // layout changes while it is going.
        model.draft.analyses = [:]
        model.createFilm(newVersion: true)
        let job = try #require(model.generation)
        try await Task.sleep(for: .milliseconds(300))
        resize(window, to: Self.inner)
        try await settle()
        print("generation still running after unfolding: \(model.generation === job)")
        #expect(job.task?.isCancelled == false, "the change of layout does not cancel the run")
        await snapshot(window, "duo-inner-generating")
        resize(window, to: Self.outer)
        try await settle()
        #expect(job.task?.isCancelled == false)

        var waited = 0
        while model.generation != nil, waited < 600 {
            try await Task.sleep(for: .milliseconds(200))
            waited += 1
        }
        #expect(model.generation == nil)
        #expect(job.errorMessage == nil)
        #expect(model.path == [.media, .length, .style, .preview])
        #expect(model.preview !== shown, "the new version replaced the film")
        #expect(model.preview?.player.rate ?? 0 > 0, "and plays, as the film is on screen")
    }

    @Test(.timeLimit(.minutes(10)))
    func everyDisplayGetsItsLayout() async throws {
        let model = try await AdjustmentTests().preparedModel()
        let storage = model.draft.storage
        defer { storage.removeAll() }
        model.path = [.media, .length]
        let window = try host(model, on: Self.innerUpright)
        defer { close(window, model) }
        try await settle()
        #expect(model.layout == .columns)
        await snapshot(window, "duo-inner-upright-length")

        resize(window, to: Self.splitView)
        try await settle()
        #expect(model.layout == .stack, "Split View too narrow for two columns falls back to one")
        #expect(model.path == [.media, .length])
        await snapshot(window, "duo-split-view-length")

        resize(window, to: Self.inner)
        model.show(.style)
        try await settle()
        #expect(model.layout == .columns)
        #expect(model.sheet == .style, "with a film, style and music change that film")
        await snapshot(window, "duo-inner-style")
        model.show(.generate)
        #expect(model.sheet == nil)

        model.show(.media)
        try await settle()
        #expect(!model.isFilmOnScreen)
        await snapshot(window, "duo-inner-media")
        resize(window, to: Self.outer)
        try await settle()
        await snapshot(window, "duo-outer-media")
    }

    // MARK: Helpers

    private func host(_ model: AppModel, on display: Display) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(
            rootView: RootView()
                .environment(model)
                .modelContainer(model.container)
        )
        resize(window, to: display)
        window.makeKeyAndVisible()
        return window
    }

    /// Stops the film and lets the window go, so that nothing keeps playing into later tests.
    private func close(_ window: UIWindow, _ model: AppModel) {
        model.preview?.pause()
        model.closePreview()
        window.isHidden = true
        window.rootViewController = nil
    }

    private func resize(_ window: UIWindow, to display: Display) {
        window.traitOverrides.horizontalSizeClass = display.regular ? .regular : .compact
        window.traitOverrides.verticalSizeClass = .regular
        window.frame = CGRect(origin: .zero, size: display.size)
        window.layoutIfNeeded()
    }

    /// Lets SwiftUI lay out, present and dismiss sheets.
    private func settle() async throws {
        try await Task.sleep(for: .seconds(1.5))
    }

    /// Saved as a PNG and logged as small base64 lines, as ScreenshotTests does.
    private func snapshot(_ window: UIWindow, _ name: String) async {
        guard let path = ProcessInfo.processInfo.environment["AUTOKLIPP_SCREENSHOTS"], !path.isEmpty else { return }
        let folder = URL(filePath: path, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Sheets are presented inside the window, so drawing it shows them over the content.
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: folder.appending(path: "\(name).png"))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            image.draw(in: window.bounds)
        }
        if let jpeg = small.jpegData(compressionQuality: 0.6) {
            ScreenshotTests.log(name: name, jpeg: jpeg)
        }
    }

    /// The player's state, for the log: why a film does not advance, if it does not.
    static func describe(_ player: AVPlayer) -> String {
        let item = player.currentItem
        let waiting = player.reasonForWaitingToPlay?.rawValue ?? "-"
        let event = item?.errorLog()?.events.last
        return "rate \(player.rate), time \(player.currentTime().seconds), control \(player.timeControlStatus.rawValue), "
            + "waiting \(waiting), item status \(item?.status.rawValue ?? -1), error \(String(describing: item?.error)), "
            + "log \(event?.errorStatusCode ?? 0) \(event?.errorComment ?? "-")"
    }

    private func logScreens() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            let traits = scene.traitCollection
            print("screen: \(scene.screen.bounds.size) at \(scene.screen.scale)x, window scene \(scene.coordinateSpace.bounds.size), width \(traits.horizontalSizeClass == .regular ? "regular" : "compact"), height \(traits.verticalSizeClass == .regular ? "regular" : "compact")")
        }
    }
}
