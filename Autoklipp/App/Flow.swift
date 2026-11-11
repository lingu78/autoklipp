import CoreGraphics
import Foundation
import SwiftUI

/// The steps of making a film, as the side panel on a large display lists them.
enum FlowStep: Int, CaseIterable, Identifiable, Sendable {
    case media
    case length
    case style
    case generate
    case export

    var id: Int { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .media: "Media"
        case .length: "Length"
        case .style: "Style and music"
        case .generate: "Generate"
        case .export: "Export"
        }
    }

    var symbol: String {
        switch self {
        case .media: "photo.on.rectangle.angled"
        case .length: "timer"
        case .style: "paintpalette"
        case .generate: "wand.and.stars"
        case .export: "square.and.arrow.up"
        }
    }
}

/// A sheet over the film in the one-column layout. On a large display the same state shows
/// as a step in the side panel instead (all but the texts).
enum PreviewSheet: String, Identifiable, Sendable {
    case export
    case style
    case music
    case texts

    var id: String { rawValue }
}

/// How the flow is laid out, decided from the space the app has, never from the device model:
/// one screen at a time (iPhone, iPhone Duo's outer display, narrow Split View) or the film and
/// the steps side by side (iPhone Duo's inner display).
enum FlowLayout: Sendable {
    case stack
    case columns

    /// The narrowest width that still fits a usable film column next to the steps.
    static let minimumColumnsWidth: CGFloat = 640

    static func choose(horizontalSizeClass: UserInterfaceSizeClass?, width: CGFloat) -> FlowLayout {
        horizontalSizeClass == .regular && width >= minimumColumnsWidth ? .columns : .stack
    }
}

/// Widths of the two columns: about 65 % for the film and 35 % for the steps. While the display
/// is partly folded with the fold running from top to bottom, the columns meet at the fold
/// instead, so that neither runs across it.
struct ColumnSplit: Equatable {
    static let sidebarShare: CGFloat = 0.35
    static let sidebarWidths: ClosedRange<CGFloat> = 280...440

    var primary: CGFloat
    /// Space left free over the fold.
    var gap: CGFloat
    var sidebar: CGFloat

    init(width: CGFloat, fold: ClosedRange<CGFloat>? = nil) {
        let width = max(0, width)
        if let fold, fold.lowerBound >= Self.sidebarWidths.lowerBound, width - fold.upperBound >= Self.sidebarWidths.lowerBound {
            primary = fold.lowerBound
            gap = fold.upperBound - fold.lowerBound
            sidebar = width - fold.upperBound
        } else {
            let wanted = min(max(width * Self.sidebarShare, Self.sidebarWidths.lowerBound), Self.sidebarWidths.upperBound)
            sidebar = min(wanted, width / 2)
            gap = 0
            primary = width - sidebar
        }
    }
}

extension AppModel {
    /// The step the side panel shows expanded, from where the flow is; nil on the start screen.
    var activeStep: FlowStep? {
        Self.step(for: path, sheet: sheet)
    }

    static func step(for path: [Route], sheet: PreviewSheet?) -> FlowStep? {
        switch path.last {
        case nil: return nil
        case .media: return .media
        case .length: return .length
        case .style: return .style
        case .generate: return .generate
        case .preview:
            switch sheet {
            case .export: return .export
            case .style, .music: return .style
            case .texts, nil: return .generate
            }
        }
    }

    /// The film made last can still be shown: every clip's media is still in the project.
    var hasFilm: Bool {
        guard let edl = draft.edl, !edl.clips.isEmpty else { return false }
        let ids = Set(draft.media.map(\.id))
        return edl.clips.allSatisfy { ids.contains($0.mediaID) }
    }

    /// A film is being made or exported; the other steps wait until it is done or cancelled.
    var isWorking: Bool {
        generation != nil || export?.isExporting == true
    }

    func canShow(_ step: FlowStep) -> Bool {
        if step == activeStep { return true }
        // An edit saves the project when it finishes; an import changes the media under it.
        if isWorking || isEditing || imports.isBusy { return false }
        switch step {
        case .media: return true
        case .length, .style: return !draft.media.isEmpty
        case .generate, .export: return hasFilm
        }
    }

    /// Opens a step from the side panel. A change of style or music that was not confirmed is
    /// undone and an export is closed, as Cancel and Close would.
    func show(_ step: FlowStep) {
        guard step != activeStep, canShow(step) else { return }
        dismissSheet()
        switch step {
        case .media:
            path = [.media]
        case .length:
            path = [.media, .length]
        case .style:
            // With a film, the choices change that film, as Change style does on a phone.
            if hasFilm {
                path = filmPath
                beginChange(.style)
            } else {
                path = [.media, .length, .style]
            }
        case .generate:
            path = filmPath
        case .export:
            path = filmPath
            openExport()
        }
    }

    /// The path to the film: the current one up to the preview, or the whole flow.
    private var filmPath: [Route] {
        if let index = path.firstIndex(of: .preview) { return Array(path[...index]) }
        return [.media, .length, .style, .preview]
    }

    /// The film is on screen: in the preview on a phone, or in the film column on a large
    /// display. When it leaves the screen it is paused; changing layout alone never stops it.
    var isFilmOnScreen: Bool {
        guard preview != nil else { return false }
        // The film column shows the photos instead once media the film needs were deselected.
        if layout == .columns, !hasFilm { return false }
        return Self.filmIsOnScreen(layout: layout, path: path, sheet: sheet, generating: generation != nil)
    }

    static func filmIsOnScreen(layout: FlowLayout, path: [Route], sheet: PreviewSheet?, generating: Bool) -> Bool {
        switch layout {
        case .stack:
            return path.last == .preview && sheet == nil
        case .columns:
            guard let step = step(for: path, sheet: sheet) else { return false }
            return step != .media && sheet != .texts && !generating
        }
    }
}
