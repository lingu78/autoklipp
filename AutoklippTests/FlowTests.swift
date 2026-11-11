import ClipCore
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Autoklipp

/// iPhone Duo: the layout follows the space the app has, and the side panel's steps map onto the
/// same flow state as the one-column screens.
@Suite("iPhone Duo – layout and steps")
@MainActor
struct FlowTests {
    @Test func layoutFollowsSizeClassAndWidth() {
        // An iPhone, and iPhone Duo's outer display: compact width.
        #expect(FlowLayout.choose(horizontalSizeClass: .compact, width: 402) == .stack)
        #expect(FlowLayout.choose(horizontalSizeClass: .compact, width: 476) == .stack)
        // The inner display, opened like a book and turned upright.
        #expect(FlowLayout.choose(horizontalSizeClass: .regular, width: 948) == .columns)
        #expect(FlowLayout.choose(horizontalSizeClass: .regular, width: 670) == .columns)
        // Split View: too narrow for two columns, even where the width class is still regular.
        #expect(FlowLayout.choose(horizontalSizeClass: .regular, width: 500) == .stack)
        #expect(FlowLayout.choose(horizontalSizeClass: .compact, width: 948) == .stack)
        #expect(FlowLayout.choose(horizontalSizeClass: nil, width: 948) == .stack)
    }

    @Test func onlyLargeDisplaysTurnSideways() {
        #expect(AppDelegate.orientations(horizontal: .compact, vertical: .regular) == .portrait)
        // A large iPhone held sideways is regular in width only, and stays upright as before.
        #expect(AppDelegate.orientations(horizontal: .regular, vertical: .compact) == .portrait)
        #expect(AppDelegate.orientations(horizontal: .regular, vertical: .regular) == .allButUpsideDown)
    }

    @Test func columnsSplitAboutTwoThirdsAndMeetAtTheFold() {
        let open = ColumnSplit(width: 948)
        #expect(abs(open.sidebar - 948 * 0.35) < 0.01)
        #expect(abs(open.primary + open.sidebar - 948) < 0.01)
        #expect(open.gap == 0)
        // The steps keep a usable width when the window is narrow, and do not grow without end.
        #expect(ColumnSplit(width: 640).sidebar == 280)
        #expect(ColumnSplit(width: 1_400).sidebar == 440)
        // Partly folded like a book: each column on its own side of the fold.
        let folded = ColumnSplit(width: 948, fold: 470...478)
        #expect(folded.primary == 470)
        #expect(folded.gap == 8)
        #expect(folded.sidebar == 470)
        // A fold that would leave either column too narrow is not followed.
        #expect(ColumnSplit(width: 948, fold: 100...108) == ColumnSplit(width: 948))
    }

    @Test func theActiveStepFollowsThePathAndSheet() {
        #expect(AppModel.step(for: [], sheet: nil) == nil)
        #expect(AppModel.step(for: [.media], sheet: nil) == .media)
        #expect(AppModel.step(for: [.media, .length], sheet: nil) == .length)
        #expect(AppModel.step(for: [.media, .length, .style], sheet: nil) == .style)
        #expect(AppModel.step(for: [.media, .length, .style, .generate], sheet: nil) == .generate)
        #expect(AppModel.step(for: [.preview], sheet: nil) == .generate)
        #expect(AppModel.step(for: [.preview], sheet: .texts) == .generate)
        #expect(AppModel.step(for: [.preview], sheet: .style) == .style)
        #expect(AppModel.step(for: [.preview], sheet: .music) == .style)
        #expect(AppModel.step(for: [.preview], sheet: .export) == .export)
        #expect(AppModel.step(for: [.preview, .generate], sheet: nil) == .generate)
    }

    @Test func theFilmIsOnScreenOnlyWhereALayoutShowsIt() {
        let preview: [Route] = [.media, .length, .style, .preview]
        #expect(AppModel.filmIsOnScreen(layout: .stack, path: preview, sheet: nil, generating: false))
        #expect(!AppModel.filmIsOnScreen(layout: .stack, path: preview, sheet: .export, generating: false))
        #expect(!AppModel.filmIsOnScreen(layout: .stack, path: [.media, .length], sheet: nil, generating: false))
        // The film column shows it next to every step but the library.
        #expect(AppModel.filmIsOnScreen(layout: .columns, path: preview, sheet: nil, generating: false))
        #expect(AppModel.filmIsOnScreen(layout: .columns, path: preview, sheet: .export, generating: false))
        #expect(AppModel.filmIsOnScreen(layout: .columns, path: [.media, .length], sheet: nil, generating: false))
        #expect(!AppModel.filmIsOnScreen(layout: .columns, path: [.media], sheet: nil, generating: false))
        #expect(!AppModel.filmIsOnScreen(layout: .columns, path: preview, sheet: .texts, generating: false))
        #expect(!AppModel.filmIsOnScreen(layout: .columns, path: preview + [.generate], sheet: nil, generating: true))
        #expect(!AppModel.filmIsOnScreen(layout: .columns, path: [], sheet: nil, generating: false))
    }

    @Test func theSidePanelMovesThroughTheFlow() throws {
        let model = Self.model(mediaCount: 4)
        model.path = [.media]
        #expect(model.activeStep == .media)
        #expect(!model.canShow(.generate))
        #expect(!model.canShow(.export))

        model.show(.length)
        #expect(model.path == [.media, .length])
        model.show(.style)
        #expect(model.path == [.media, .length, .style])
        #expect(model.sheet == nil)

        // Once there is a film, its steps open, and the phone layout sees the same state.
        model.draft.edl = Self.film(of: model.draft.media)
        model.show(.generate)
        #expect(model.path == [.media, .length, .style, .preview])
        #expect(model.activeStep == .generate)

        model.show(.export)
        #expect(model.sheet == .export)
        let job = try #require(model.export)
        #expect(model.activeStep == .export)

        // Style and music change the film; going elsewhere undoes what was not confirmed.
        model.show(.style)
        #expect(model.export == nil)
        #expect(!job.isExporting)
        #expect(model.sheet == .style)
        #expect(model.choicesBeforeChange != nil)
        let style = model.draft.style
        model.draft.choose(style: style == .cinematic ? .calm : .cinematic)
        model.show(.generate)
        #expect(model.sheet == nil)
        #expect(model.draft.style == style)
        #expect(model.choicesBeforeChange == nil)

        model.show(.media)
        #expect(model.path == [.media])
    }

    @Test func aFilmWhoseMediaWereDeselectedCannotBeShown() {
        let model = Self.model(mediaCount: 4)
        model.path = [.media]
        model.draft.edl = Self.film(of: model.draft.media)
        #expect(model.hasFilm)
        model.draft.media.removeLast()
        #expect(!model.hasFilm)
        #expect(!model.canShow(.generate))
        // Adding media keeps the film.
        model.draft.edl = Self.film(of: model.draft.media)
        model.draft.media.append(ImportedMedia(item: MediaItem(id: "extra", kind: .photo), url: URL(filePath: "/dev/null")))
        #expect(model.hasFilm)
    }

    @Test func textsNeedAFilmToGoOn() {
        let model = Self.model(mediaCount: 2)
        model.path = [.preview]
        model.draft.edl = Self.film(of: model.draft.media)
        // Without a built film there is nothing to put the texts on yet.
        model.openTexts()
        #expect(model.sheet == nil)
    }

    // MARK: Helpers

    static func model(mediaCount: Int) -> AppModel {
        let model = AppModel(inMemory: true)
        model.draft.media = (0..<mediaCount).map {
            ImportedMedia(item: MediaItem(id: "media-\($0)", kind: .photo), url: URL(filePath: "/dev/null"))
        }
        return model
    }

    static func film(of media: [ImportedMedia]) -> EditDecisionList {
        let clips = media.enumerated().map { index, media in
            EDLClip(
                id: "clip-\(index)", mediaID: media.id, kind: .photo, sourceStart: 0, sourceDuration: 2,
                timelineStart: Double(index) * 2, duration: 2, beats: 4
            )
        }
        return EditDecisionList(targetDuration: Double(clips.count) * 2, duration: Double(clips.count) * 2, style: .travel, seed: 1, clips: clips)
    }
}
